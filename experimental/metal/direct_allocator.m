// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "experimental/metal/direct_allocator.h"

#import <Metal/Metal.h>

#include "experimental/metal/metal_buffer.h"
#include "iree/base/api.h"
#include "iree/base/target_platform.h"
#include "iree/base/tracing.h"
#include "iree/hal/api.h"

#if IREE_TRACING_FEATURES & IREE_TRACING_FEATURE_ALLOCATION_TRACKING
static const char* IREE_HAL_METAL_ALLOCATOR_ID = "METAL";
#endif  // IREE_TRACING_FEATURE_ALLOCATION_TRACKING

typedef struct iree_hal_metal_allocator_t {
  // Abstract resource used for injecting reference counting and vtable; must be at offset 0.
  iree_hal_resource_t resource;

  iree_hal_device_t* base_device;
  id<MTLDevice> device;

  iree_hal_metal_resource_hazard_tracking_mode_t resource_tracking_mode;

  iree_allocator_t host_allocator;

  IREE_STATISTICS(iree_hal_allocator_statistics_t statistics;)
} iree_hal_metal_allocator_t;

static const iree_hal_allocator_vtable_t iree_hal_metal_allocator_vtable;

static iree_hal_metal_allocator_t* iree_hal_metal_allocator_cast(iree_hal_allocator_t* base_value) {
  IREE_HAL_ASSERT_TYPE(base_value, &iree_hal_metal_allocator_vtable);
  return (iree_hal_metal_allocator_t*)base_value;
}

iree_status_t iree_hal_metal_allocator_create(
    iree_hal_device_t* base_device, id<MTLDevice> device,
    iree_hal_metal_resource_hazard_tracking_mode_t resource_tracking_mode,
    iree_allocator_t host_allocator, iree_hal_allocator_t** out_allocator) {
  IREE_ASSERT_ARGUMENT(base_device);
  IREE_ASSERT_ARGUMENT(out_allocator);
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_metal_allocator_t* allocator = NULL;
  iree_status_t status =
      iree_allocator_malloc(host_allocator, sizeof(*allocator), (void**)&allocator);

  if (iree_status_is_ok(status)) {
    iree_hal_resource_initialize(&iree_hal_metal_allocator_vtable, &allocator->resource);
    allocator->base_device = base_device;
    iree_hal_device_retain(base_device);
    allocator->device = [device retain];  // +1
    allocator->resource_tracking_mode = resource_tracking_mode;
    allocator->host_allocator = host_allocator;

    *out_allocator = (iree_hal_allocator_t*)allocator;
  }

  IREE_TRACE_ZONE_END(z0);
  return status;
}

static void iree_hal_metal_allocator_destroy(iree_hal_allocator_t* IREE_RESTRICT base_allocator) {
  iree_hal_metal_allocator_t* allocator = iree_hal_metal_allocator_cast(base_allocator);
  iree_allocator_t host_allocator = allocator->host_allocator;
  IREE_TRACE_ZONE_BEGIN(z0);

  [allocator->device release];  // -1
  iree_hal_device_release(allocator->base_device);
  iree_allocator_free(host_allocator, allocator);

  IREE_TRACE_ZONE_END(z0);
}

static iree_allocator_t iree_hal_metal_allocator_host_allocator(
    const iree_hal_allocator_t* IREE_RESTRICT base_allocator) {
  iree_hal_metal_allocator_t* allocator = (iree_hal_metal_allocator_t*)base_allocator;
  return allocator->host_allocator;
}

static iree_status_t iree_hal_metal_allocator_trim(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator) {
  return iree_ok_status();
}

static void iree_hal_metal_allocator_query_statistics(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator,
    iree_hal_allocator_statistics_t* IREE_RESTRICT out_statistics) {
  IREE_STATISTICS({
    iree_hal_metal_allocator_t* allocator = iree_hal_metal_allocator_cast(base_allocator);
    memcpy(out_statistics, &allocator->statistics, sizeof(*out_statistics));
  });
}

static iree_hal_buffer_compatibility_t iree_hal_metal_allocator_query_buffer_compatibility(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator,
    iree_hal_buffer_params_t* IREE_RESTRICT params,
    iree_device_size_t* IREE_RESTRICT allocation_size) {
  // All buffers can be allocated on the heap.
  iree_hal_buffer_compatibility_t compatibility = IREE_HAL_BUFFER_COMPATIBILITY_ALLOCATABLE;

  if (iree_any_bit_set(params->usage, IREE_HAL_BUFFER_USAGE_TRANSFER)) {
    compatibility |= IREE_HAL_BUFFER_COMPATIBILITY_QUEUE_TRANSFER;
  }

  // Buffers can only be used on the queue if they are device visible.
  if (iree_all_bits_set(params->type, IREE_HAL_MEMORY_TYPE_DEVICE_VISIBLE)) {
    if (iree_any_bit_set(params->usage, IREE_HAL_BUFFER_USAGE_DISPATCH_STORAGE)) {
      compatibility |= IREE_HAL_BUFFER_COMPATIBILITY_QUEUE_DISPATCH;
    }
  }

  // We are now optimal.
  params->type &= ~IREE_HAL_MEMORY_TYPE_OPTIMAL;

  // Guard against the corner case where the requested buffer size is 0. The
  // application is unlikely to do anything when requesting a 0-byte buffer; but
  // it can happen in real world use cases. So we should at least not crash.
  if (*allocation_size == 0) *allocation_size = 4;

  // Align allocation sizes to 4 bytes so shaders operating on 32 bit types can
  // act safely even on buffer ranges that are not naturally aligned.
  *allocation_size = iree_host_align(*allocation_size, 4);

  return compatibility;
}

// Returns the corresponding Metal resource options controlling storage modes, CPU caching modes,
// and hazard tracking modes for the given IREE HAL memory |type|.
static MTLResourceOptions iree_hal_metal_select_resource_options(
    iree_hal_memory_type_t type, bool is_unified_memory,
    iree_hal_metal_resource_hazard_tracking_mode_t resource_tracking_mode) {
  MTLResourceOptions options;

  // Select a storage mode. There are four MTLStorageMode:
  // * Shared: The resource is stored in system memory and is accessible to both the CPU and
  //   the GPU.
  // * Managed: The CPU and GPU may maintain separate copies of the resource, and any changes
  //   must be explicitly synchronized.
  // * Private: The resource can be accessed only by the GPU.
  // * Memoryless: The resource’s contents can be accessed only by the GPU and only exist
  //   temporarily during a render pass.
  // macOS has all of the above; MTLStorageModeManaged is not available on iOS.
  //
  // The IREE HAL is modeled after explicit APIs like Vulkan. For buffers visible to both the host
  // and the device, we would like to opt in with the explicit version (MTLStorageManaged) when
  // possible because it should be more performant.
  if (iree_all_bits_set(type, IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL)) {
    if (iree_all_bits_set(type, IREE_HAL_MEMORY_TYPE_HOST_VISIBLE)) {
      // Device local + host visible.
#if defined(IREE_PLATFORM_MACOS)
      options = is_unified_memory ? MTLResourceStorageModeShared : MTLResourceStorageModeManaged;
#else
      options = MTLResourceStorageModeShared;
#endif
    } else {
      // Device local + host invisible.
      options = MTLResourceStorageModePrivate;
    }
  } else {
    if (iree_all_bits_set(type, IREE_HAL_MEMORY_TYPE_DEVICE_VISIBLE)) {
      // Host local + device visible.
      options = MTLResourceStorageModeShared;
    } else {
      // Host local + device invisible.
      options = MTLResourceStorageModeShared;
    }
  }

  // Select a CPU cache mode.
  if (iree_all_bits_set(type, IREE_HAL_MEMORY_TYPE_HOST_CACHED)) {
    // The default CPU cache mode for the resource, which guarantees that read and write operations
    // are executed in the expected order.
    options |= MTLResourceCPUCacheModeDefaultCache;
  } else {
    // A write-combined CPU cache mode that is optimized for resources that the CPU writes into, but
    // never reads.
    options |= MTLResourceCPUCacheModeWriteCombined;
  }

  options |= resource_tracking_mode == IREE_HAL_METAL_RESOURCE_HAZARD_TRACKING_MODE_TRACKED
                 ? MTLResourceHazardTrackingModeTracked
                 : MTLResourceHazardTrackingModeUntracked;
  return options;
}

static iree_status_t iree_hal_metal_allocator_allocate_buffer(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator,
    const iree_hal_buffer_params_t* IREE_RESTRICT params, iree_device_size_t allocation_size,
    iree_const_byte_span_t initial_data, iree_hal_buffer_t** IREE_RESTRICT out_buffer) {
  iree_hal_metal_allocator_t* allocator = iree_hal_metal_allocator_cast(base_allocator);
  IREE_TRACE_ZONE_BEGIN(z0);
  IREE_TRACE_ZONE_APPEND_VALUE(z0, allocation_size);

  // Coerce options into those required by the current device.
  iree_hal_buffer_params_t compat_params = *params;
  if (!iree_all_bits_set(iree_hal_metal_allocator_query_buffer_compatibility(
                             base_allocator, &compat_params, &allocation_size),
                         IREE_HAL_BUFFER_COMPATIBILITY_ALLOCATABLE)) {
    return iree_make_status(IREE_STATUS_INVALID_ARGUMENT,
                            "allocator cannot allocate a buffer with the given parameters");
  }

  iree_status_t status = iree_ok_status();
  bool is_unified_memory = [allocator->device hasUnifiedMemory];

  MTLResourceOptions options = iree_hal_metal_select_resource_options(
      compat_params.type, is_unified_memory, allocator->resource_tracking_mode);
  id<MTLBuffer> metal_buffer = nil;
  if (iree_const_byte_span_is_empty(initial_data)) {
    metal_buffer = [allocator->device newBufferWithLength:allocation_size options:options];  // +1
  } else {
    IREE_ASSERT_EQ(allocation_size, initial_data.data_length);
    metal_buffer = [allocator->device newBufferWithBytes:(void*)initial_data.data
                                                  length:initial_data.data_length
                                                 options:options];  // +1
  }

  IREE_TRACE_ZONE_END(z0);
  if (!metal_buffer) {
    status = iree_make_status(IREE_STATUS_RESOURCE_EXHAUSTED, "unable to allocate buffer");
  }

  iree_hal_buffer_t* buffer = NULL;
  if (iree_status_is_ok(status)) {
    status = iree_hal_metal_buffer_wrap(
        metal_buffer, base_allocator, compat_params.type, compat_params.access, compat_params.usage,
        allocation_size, /*byte_offset=*/0,
        /*byte_length=*/allocation_size, iree_hal_buffer_release_callback_null(), &buffer);  // +1
  }

  if (iree_status_is_ok(status)) {
    IREE_TRACE_ALLOC_NAMED(IREE_HAL_METAL_ALLOCATOR_ID,
                           (void*)iree_hal_metal_buffer_device_pointer(buffer), allocation_size);
    IREE_STATISTICS(iree_hal_allocator_statistics_record_alloc(
        &allocator->statistics, compat_params.type, allocation_size));
    *out_buffer = buffer;
  } else {
    if (buffer) iree_hal_buffer_release(buffer);
  }

  [metal_buffer release];  // -1
  return status;
}

static void iree_hal_metal_allocator_deallocate_buffer(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator,
    iree_hal_buffer_t* IREE_RESTRICT base_buffer) {
  iree_hal_metal_allocator_t* allocator = iree_hal_metal_allocator_cast(base_allocator);

  IREE_TRACE_FREE_NAMED(IREE_HAL_METAL_ALLOCATOR_ID, (void*)metal_buffer);
  IREE_STATISTICS(iree_hal_allocator_statistics_record_free(
      &allocator->statistics, iree_hal_buffer_memory_type(base_buffer),
      iree_hal_buffer_allocation_size(base_buffer)));

  iree_hal_buffer_destroy(base_buffer);  // -1
}

static iree_status_t iree_hal_metal_allocator_import_buffer(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator,
    const iree_hal_buffer_params_t* IREE_RESTRICT params,
    iree_hal_external_buffer_t* IREE_RESTRICT external_buffer,
    iree_hal_buffer_release_callback_t release_callback,
    iree_hal_buffer_t** IREE_RESTRICT out_buffer) {
  return iree_make_status(IREE_STATUS_UNAVAILABLE, "unsupported importing from external buffer");
}

static iree_status_t iree_hal_metal_allocator_export_buffer(
    iree_hal_allocator_t* IREE_RESTRICT base_allocator, iree_hal_buffer_t* IREE_RESTRICT buffer,
    iree_hal_external_buffer_type_t requested_type,
    iree_hal_external_buffer_flags_t requested_flags,
    iree_hal_external_buffer_t* IREE_RESTRICT out_external_buffer) {
  return iree_make_status(IREE_STATUS_UNAVAILABLE, "unsupported exporting to external buffer");
}

static const iree_hal_allocator_vtable_t iree_hal_metal_allocator_vtable = {
    .destroy = iree_hal_metal_allocator_destroy,
    .host_allocator = iree_hal_metal_allocator_host_allocator,
    .trim = iree_hal_metal_allocator_trim,
    .query_statistics = iree_hal_metal_allocator_query_statistics,
    .query_buffer_compatibility = iree_hal_metal_allocator_query_buffer_compatibility,
    .allocate_buffer = iree_hal_metal_allocator_allocate_buffer,
    .deallocate_buffer = iree_hal_metal_allocator_deallocate_buffer,
    .import_buffer = iree_hal_metal_allocator_import_buffer,
    .export_buffer = iree_hal_metal_allocator_export_buffer,
};

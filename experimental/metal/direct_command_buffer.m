// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "experimental/metal/direct_command_buffer.h"

#import <Metal/Metal.h>

#include "experimental/metal/metal_buffer.h"
#include "experimental/metal/metal_device.h"
#include "experimental/metal/metal_kernel_library.h"
#include "experimental/metal/pipeline_layout.h"
#include "iree/base/api.h"
#include "iree/base/tracing.h"
#include "iree/hal/api.h"
#include "iree/hal/utils/resource_set.h"

typedef struct iree_hal_metal_descriptor_t {
  uint32_t set;
  uint32_t binding;
  iree_hal_buffer_t* buffer;
  iree_host_size_t offset;

} iree_hal_metal_descriptor_t;

typedef struct iree_hal_metal_command_buffer_t {
  iree_hal_command_buffer_t base;

  // The Metal command queue owning this command buffer.
  id<MTLCommandQueue> queue;

  id<MTLCommandBuffer> command_buffer;

  MTLDispatchType dispatch_type;

  // The current active compute/blit encoders for encoding compute for memory operations.
  // Metal commands are encoded into the command buffer with such encoders, and each encoder can
  // only encode the specific type of operations it supports.
  id<MTLComputeCommandEncoder> compute_encoder;
  id<MTLBlitCommandEncoder> blit_encoder;

  // Metal APIs mandate we create argument bufffers (for descriptor sets) from compiled kernel
  // function. That means we need to bind the compute kernel first before setting descriptors and
  // binding buffers. So we need to cache the descriptor information by ourselves and apply them in
  // a delayed manner.

  // A sorted flat list of descriptors from all pushed descriptor sets.
  iree_hal_metal_descriptor_t current_descriptors[IREE_HAL_METAL_MAX_BINDING_COUNT];
  // The total used slot count / next unused slot index in |current_descriptors|.
  int current_total_binding_count;
  // The max descriptor set number we have seen thus far.
  int current_max_set_number;
  // The current pipeline layout used for push descriptors.
  iree_hal_pipeline_layout_t* current_pipeline_layout;

  iree_allocator_t host_allocator;

  // Maintains a reference to all resources used within the command buffer. Resets on each begin.
  iree_hal_resource_set_t* resource_set;
} iree_hal_metal_command_buffer_t;

static const iree_hal_command_buffer_vtable_t iree_hal_metal_command_buffer_vtable;

static iree_hal_metal_command_buffer_t* iree_hal_metal_command_buffer_cast(
    iree_hal_command_buffer_t* base_value) {
  IREE_HAL_ASSERT_TYPE(base_value, &iree_hal_metal_command_buffer_vtable);
  return (iree_hal_metal_command_buffer_t*)base_value;
}

id<MTLCommandBuffer> iree_hal_metal_direct_command_buffer_handle(
    iree_hal_command_buffer_t* base_command_buffer) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  return command_buffer->command_buffer;
}

static void iree_hal_metal_end_compute_encoder(iree_hal_metal_command_buffer_t* command_buffer) {
  if (command_buffer->compute_encoder) {
    [command_buffer->compute_encoder endEncoding];
    [command_buffer->compute_encoder release];  // -1
    command_buffer->compute_encoder = nil;
  }
}

static void iree_hal_metal_end_blit_encoder(iree_hal_metal_command_buffer_t* command_buffer) {
  if (command_buffer->blit_encoder) {
    [command_buffer->blit_encoder endEncoding];
    [command_buffer->blit_encoder release];  // -1
    command_buffer->blit_encoder = nil;
  }
}

static id<MTLComputeCommandEncoder> iree_hal_metal_get_or_begin_compute_encoder(
    iree_hal_metal_command_buffer_t* command_buffer) {
  if (command_buffer->blit_encoder) iree_hal_metal_end_blit_encoder(command_buffer);

  @autoreleasepool {  // Use @autoreleasepool to trigger the autorelease within encoder creation.
    if (!command_buffer->compute_encoder) {
      // We manage commands dependencies and insert barriers explicitly in IREE; so use the
      // concurrent dispatch type for compute encoders.
      command_buffer->compute_encoder = [[command_buffer->command_buffer
          computeCommandEncoderWithDispatchType:command_buffer->dispatch_type] retain];  // +1
    }
  }
  return command_buffer->compute_encoder;
}

static id<MTLBlitCommandEncoder> iree_hal_metal_get_or_begin_blit_encoder(
    iree_hal_metal_command_buffer_t* command_buffer) {
  if (command_buffer->compute_encoder) iree_hal_metal_end_compute_encoder(command_buffer);

  @autoreleasepool {  // Use @autoreleasepool to trigger the autorelease within encoder creation.
    if (!command_buffer->blit_encoder) {
      command_buffer->blit_encoder =
          [[command_buffer->command_buffer blitCommandEncoder] retain];  // +1
    }
  }
  return command_buffer->blit_encoder;
}

iree_status_t iree_hal_metal_direct_command_buffer_create(
    iree_hal_device_t* device, iree_hal_command_buffer_mode_t mode,
    iree_hal_command_category_t command_categories, iree_host_size_t binding_capacity,
    id<MTLCommandQueue> queue, iree_allocator_t host_allocator, iree_arena_block_pool_t* block_pool,
    iree_hal_command_buffer_t** out_command_buffer) {
  IREE_ASSERT_ARGUMENT(device);
  IREE_ASSERT_ARGUMENT(out_command_buffer);
  IREE_ASSERT_TRUE(iree_all_bits_set(mode, IREE_HAL_COMMAND_BUFFER_MODE_ONE_SHOT));
  IREE_ASSERT_TRUE(!iree_any_bit_set(mode, IREE_HAL_COMMAND_BUFFER_MODE_NESTED));
  *out_command_buffer = NULL;

  if (binding_capacity > 0) {
    // TODO(#10144): support indirect command buffers with binding tables.
    return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented indirect command buffers");
  }

  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_metal_command_buffer_t* command_buffer = NULL;
  iree_status_t status =
      iree_allocator_malloc(host_allocator, sizeof(*command_buffer), (void**)&command_buffer);
  if (iree_status_is_ok(status)) {
    iree_hal_command_buffer_initialize(
        device, mode, command_categories, IREE_HAL_QUEUE_AFFINITY_ANY, binding_capacity,
        &iree_hal_metal_command_buffer_vtable, &command_buffer->base);
    command_buffer->queue = [queue retain];  // +1
    @autoreleasepool {  // Use @autoreleasepool to trigger the autorelease within encoder creation.
      // We track resource lifetime by ourselves in IREE; so just do unretained references to
      // resources in Metal command buffer, which avoids overhead and gives better performance.
      command_buffer->command_buffer =
          [[queue commandBufferWithUnretainedReferences] retain];  // +1
    }
    const iree_hal_metal_device_params_t* params = iree_hal_metal_device_params(device);
    command_buffer->dispatch_type =
        params->command_dispatch_type == IREE_HAL_METAL_COMMAND_DISPATCH_TYPE_CONCURRENT
            ? MTLDispatchTypeConcurrent
            : MTLDispatchTypeSerial;
    command_buffer->compute_encoder = nil;
    command_buffer->blit_encoder = nil;
    memset(command_buffer->current_descriptors, 0,
           IREE_HAL_METAL_MAX_BINDING_COUNT * sizeof(command_buffer->current_descriptors[0]));
    command_buffer->current_total_binding_count = 0;
    command_buffer->current_max_set_number = -1;
    command_buffer->current_pipeline_layout = NULL;
    command_buffer->host_allocator = host_allocator;
    status = iree_hal_resource_set_allocate(block_pool, &command_buffer->resource_set);
  }

  *out_command_buffer = &command_buffer->base;
  IREE_TRACE_ZONE_END(z0);
  return status;
}

static void iree_hal_metal_command_buffer_destroy(iree_hal_command_buffer_t* base_command_buffer) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  IREE_TRACE_ZONE_BEGIN(z0);

  IREE_ASSERT_EQ(command_buffer->compute_encoder, nil);
  IREE_ASSERT_EQ(command_buffer->blit_encoder, nil);
  [command_buffer->command_buffer release];  // -1
  [command_buffer->queue release];           // -1
  iree_hal_resource_set_free(command_buffer->resource_set);
  iree_allocator_free(command_buffer->host_allocator, command_buffer);

  IREE_TRACE_ZONE_END(z0);
}

bool iree_hal_metal_command_buffer_isa(iree_hal_command_buffer_t* command_buffer) {
  return iree_hal_command_buffer_dyn_cast(command_buffer, &iree_hal_metal_command_buffer_vtable);
}

static void* iree_hal_metal_command_buffer_dyn_cast(iree_hal_command_buffer_t* command_buffer,
                                                    const void* vtable) {
  if (vtable == &iree_hal_metal_command_buffer_vtable) {
    IREE_HAL_ASSERT_TYPE(command_buffer, vtable);
    return command_buffer;
  }
  return NULL;
}

static iree_status_t iree_hal_metal_command_buffer_begin(
    iree_hal_command_buffer_t* base_command_buffer) {
  // Nothing to do.
  return iree_ok_status();
}

static iree_status_t iree_hal_metal_command_buffer_end(
    iree_hal_command_buffer_t* base_command_buffer) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  iree_hal_metal_end_blit_encoder(command_buffer);
  iree_hal_metal_end_compute_encoder(command_buffer);
  return iree_ok_status();
}

static void iree_hal_metal_command_buffer_begin_debug_group(
    iree_hal_command_buffer_t* base_command_buffer, iree_string_view_t label,
    iree_hal_label_color_t label_color, const iree_hal_label_location_t* location) {
  // TODO(antiagainst): implement support for debug group
}

static void iree_hal_metal_command_buffer_end_debug_group(
    iree_hal_command_buffer_t* base_command_buffer) {
  // TODO(antiagainst): implement support for debug group
}

static iree_status_t iree_hal_metal_command_buffer_execution_barrier(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_execution_stage_t source_stage_mask,
    iree_hal_execution_stage_t target_stage_mask, iree_hal_execution_barrier_flags_t flags,
    iree_host_size_t memory_barrier_count, const iree_hal_memory_barrier_t* memory_barriers,
    iree_host_size_t buffer_barrier_count, const iree_hal_buffer_barrier_t* buffer_barriers) {
  if (iree_any_bit_set(source_stage_mask, IREE_HAL_EXECUTION_STAGE_HOST) ||
      iree_any_bit_set(target_stage_mask, IREE_HAL_EXECUTION_STAGE_HOST)) {
    return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented barrier involving host");
  }

  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  id<MTLComputeCommandEncoder> encoder =
      iree_hal_metal_get_or_begin_compute_encoder(command_buffer);

  if (memory_barrier_count != 0) {
    // If there is a memory barrier specified, we have to place a catch-all barrier for all buffers.
    // Metal does not provide a more fine-grained control here.
    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    return iree_ok_status();
  }

  if (buffer_barrier_count != 0) {
    // But we do have the option to specify a list of buffers to synchronize if only buffer barriers
    // are specified.
    id<MTLResource>* resources =
        (id<MTLResource>*)iree_alloca(sizeof(id<MTLResource>) * buffer_barrier_count);
    for (unsigned i = 0; i < buffer_barrier_count; ++i) {
      resources[i] =
          iree_hal_metal_buffer_handle(iree_hal_buffer_allocated_buffer(buffer_barriers[i].buffer));
    }
    [encoder memoryBarrierWithResources:resources count:buffer_barrier_count];
  }
  return iree_ok_status();
}

static iree_status_t iree_hal_metal_command_buffer_signal_event(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_event_t* event,
    iree_hal_execution_stage_t source_stage_mask) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented signal event");
}

static iree_status_t iree_hal_metal_command_buffer_reset_event(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_event_t* event,
    iree_hal_execution_stage_t source_stage_mask) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented reset event");
}

static iree_status_t iree_hal_metal_command_buffer_wait_events(
    iree_hal_command_buffer_t* base_command_buffer, iree_host_size_t event_count,
    const iree_hal_event_t** events, iree_hal_execution_stage_t source_stage_mask,
    iree_hal_execution_stage_t target_stage_mask, iree_host_size_t memory_barrier_count,
    const iree_hal_memory_barrier_t* memory_barriers, iree_host_size_t buffer_barrier_count,
    const iree_hal_buffer_barrier_t* buffer_barriers) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented wait event");
}

static iree_status_t iree_hal_metal_command_buffer_discard_buffer(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_buffer_t* buffer) {
  // This is a hint to the device and we have nothing to do for Metal.
  return iree_ok_status();
}

static iree_status_t iree_hal_metal_command_buffer_fill_buffer(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_buffer_t* target_buffer,
    iree_device_size_t target_offset, iree_device_size_t length, const void* pattern,
    iree_host_size_t pattern_length) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented fill buffer");
}

static iree_status_t iree_hal_metal_command_buffer_update_buffer(
    iree_hal_command_buffer_t* base_command_buffer, const void* source_buffer,
    iree_host_size_t source_offset, iree_hal_buffer_t* target_buffer,
    iree_device_size_t target_offset, iree_device_size_t length) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented update buffer");
}

static iree_status_t iree_hal_metal_command_buffer_copy_buffer(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_buffer_t* source_buffer,
    iree_device_size_t source_offset, iree_hal_buffer_t* target_buffer,
    iree_device_size_t target_offset, iree_device_size_t length) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented copy buffer");
}

static iree_status_t iree_hal_metal_command_buffer_collective(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_channel_t* channel,
    iree_hal_collective_op_t op, uint32_t param, iree_hal_buffer_binding_t send_binding,
    iree_hal_buffer_binding_t recv_binding, iree_device_size_t element_count) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented buffer collective");
}

static iree_status_t iree_hal_metal_command_buffer_push_constants(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_pipeline_layout_t* pipeline_layout,
    iree_host_size_t offset, const void* values, iree_host_size_t values_length) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented push constants");
}

static int compare_descriptor(const void* a, const void* b) {
  const iree_hal_metal_descriptor_t* buffer_a = (const iree_hal_metal_descriptor_t*)a;
  const iree_hal_metal_descriptor_t* buffer_b = (const iree_hal_metal_descriptor_t*)b;
  if (buffer_a->set != buffer_b->set) return buffer_a->set - buffer_b->set;
  return buffer_a->binding - buffer_b->binding;
}

// Returns true if the given |descriptors| array contains descriptors in ascending binding slot
// order and there is no duplicated binding slots.
static bool iree_hal_metal_is_sorted_unique_descriptors(iree_hal_metal_descriptor_t* descriptors,
                                                        int descriptor_count) {
  for (int i = 1; i < descriptor_count; ++i) {
    if (compare_descriptor(&descriptors[i - 1], &descriptors[i]) >= 0) return false;
  }
  return true;
}

static iree_status_t iree_hal_metal_command_buffer_push_descriptor_set(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_pipeline_layout_t* pipeline_layout,
    uint32_t set, iree_host_size_t binding_count,
    const iree_hal_descriptor_set_binding_t* bindings) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  IREE_TRACE_ZONE_BEGIN(z0);

  for (iree_host_size_t i = 0; i < binding_count; ++i) {
    if (bindings[i].buffer) continue;
    IREE_TRACE_ZONE_END(z0);
    return iree_make_status(IREE_STATUS_UNIMPLEMENTED,
                            "unimplemented null buffer in push descriptor set");
  }

  iree_hal_metal_descriptor_t* descriptors = command_buffer->current_descriptors;
  IREE_ASSERT(iree_hal_metal_is_sorted_unique_descriptors(
      descriptors, command_buffer->current_total_binding_count));

  if (command_buffer->current_max_set_number >= (int)set) {
    // We are pushing an already seen set. This would invalidate all sets with the given number and
    // larger ones. So clear all affected bindings.
    // TODO(antiagainst): We should actually check current pipeline's layout compatibility with
    // previous one and decide whether we should invalidate lower numbered sets too. For now we
    // assume the compiler side is doing proper job of guaranteeing that.
    // https://registry.khronos.org/vulkan/specs/1.3-extensions/html/chap14.html#descriptorsets-compatibility
    int* count = &command_buffer->current_total_binding_count;
    while (*count > 0 && descriptors[*count - 1].set >= (int)set) --(*count);
    command_buffer->current_max_set_number = (*count == 0) ? -1 : descriptors[*count - 1].set;
  }

  // Pushing a new set with a larger number. All sets with smaller number remain active. Just sort
  // the current one and copy over the data. This is the expected usage pattern in IREE, where the
  // compiler sorts/deduplicates descriptor sets, and pushes them in ascending order.
  if (binding_count + command_buffer->current_total_binding_count >
      IREE_HAL_METAL_MAX_BINDING_COUNT) {
    IREE_TRACE_ZONE_END(z0);
    return iree_make_status(IREE_STATUS_RESOURCE_EXHAUSTED,
                            "exceeded available binding slots for push descriptor sets");
  }

  int start_index = command_buffer->current_total_binding_count;
  for (iree_host_size_t i = 0; i < binding_count; ++i) {
    iree_hal_metal_descriptor_t* descriptor = &descriptors[start_index + i];
    descriptor->set = set;
    descriptor->binding = bindings[i].binding;
    descriptor->buffer = bindings[i].buffer;
    descriptor->offset = bindings[i].offset;
  }
  qsort(&descriptors[start_index], binding_count, sizeof(descriptors[0]), compare_descriptor);

  command_buffer->current_max_set_number = set;
  command_buffer->current_total_binding_count += binding_count;

  IREE_ASSERT(iree_hal_metal_is_sorted_unique_descriptors(
      descriptors, command_buffer->current_total_binding_count));

  // Retain all buffers bound in this descriptor set.
  for (iree_host_size_t i = 0; i < binding_count; ++i) {
    if (bindings[i].buffer) {
      IREE_RETURN_AND_END_ZONE_IF_ERROR(
          z0, iree_hal_resource_set_insert(command_buffer->resource_set, 1, &bindings[i].buffer));
    }
  }

  command_buffer->current_pipeline_layout = pipeline_layout;
  IREE_RETURN_AND_END_ZONE_IF_ERROR(
      z0, iree_hal_resource_set_insert(command_buffer->resource_set, 1, &pipeline_layout));

  IREE_TRACE_ZONE_END(z0);
  return iree_ok_status();
}

static inline MTLResourceUsage iree_hal_metal_get_metal_resource_usage(
    iree_hal_descriptor_set_layout_binding_t* binding) {
  MTLResourceUsage usage = MTLResourceUsageRead;
  if (binding->flags != IREE_HAL_DESCRIPTOR_FLAG_READ_ONLY) usage |= MTLResourceUsageWrite;
  return usage;
}

// Prepares kernels and argument buffers needed for kernel dispatches.
static iree_status_t iree_hal_metal_command_buffer_prepare_dispatch(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_executable_t* executable,
    int32_t entry_point, iree_hal_metal_kernel_params_t* kernel_params) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  IREE_TRACE_ZONE_BEGIN(z0);

  IREE_RETURN_AND_END_ZONE_IF_ERROR(z0, iree_hal_metal_kernel_library_entry_point_kernel_params(
                                            executable, entry_point, kernel_params));
  if (!command_buffer->current_pipeline_layout) {
    IREE_TRACE_ZONE_END(z0);
    return iree_make_status(IREE_STATUS_INVALID_ARGUMENT, "missing pipeline layout when dispatch");
  }

  // Set the compute kernel to dispatch.
  id<MTLComputeCommandEncoder> compute_encoder =
      iree_hal_metal_get_or_begin_compute_encoder(command_buffer);
  [compute_encoder setComputePipelineState:kernel_params->pso];

  iree_status_t status = iree_ok_status();

  // Bind all buffers in all descriptor sets.
  iree_hal_metal_descriptor_t* descriptors = command_buffer->current_descriptors;
  int binding_count = command_buffer->current_total_binding_count;
  int i = 0;
  while (i < binding_count) {
    // Build argument encoder and argument buffer for the current descriptor set.
    uint32_t current_set = descriptors[i].set;

    id<MTLArgumentEncoder> argument_encoder =
        [kernel_params->function newArgumentEncoderWithBufferIndex:current_set];  // +1
    if (!argument_encoder) {
      status =
          iree_make_status(IREE_STATUS_INVALID_ARGUMENT, "invalid argument buffer index #%u", i);
      break;
    }

    __block id<MTLBuffer> argument_buffer = [command_buffer->command_buffer.device
        newBufferWithLength:argument_encoder.encodedLength
                    options:MTLResourceStorageModeShared];  // +1
    if (!argument_buffer) {
      status = iree_make_status(IREE_STATUS_RESOURCE_EXHAUSTED,
                                "failed to create argument buffer with size = %ld bytes",
                                argument_encoder.encodedLength);
      break;
    }

    // The arugment encoder and buffer can be deleted once the command buffer completes.
    [command_buffer->command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cmdbuf) {
      [argument_buffer release];   // -1
      [argument_encoder release];  // -1
    }];

    [argument_encoder setArgumentBuffer:argument_buffer offset:0];

    iree_hal_descriptor_set_layout_t* set_layout =
        iree_hal_metal_pipeline_layout_descriptor_set_layout(
            command_buffer->current_pipeline_layout, current_set);
    if (!set_layout) {
      status = iree_make_status(IREE_STATUS_INVALID_ARGUMENT,
                                "cannot find descriptor set layout for set #%u", current_set);
      break;
    }

    // Now put all bound buffers belonging to the current descriptor set into the argument buffer.
    for (; i < binding_count && descriptors[i].set == current_set; ++i) {
      unsigned current_binding = descriptors[i].binding;
      id<MTLBuffer> current_buffer =
          iree_hal_metal_buffer_handle(iree_hal_buffer_allocated_buffer(descriptors[i].buffer));
      iree_host_size_t offset =
          iree_hal_buffer_byte_offset(descriptors[i].buffer) + descriptors[i].offset;
      [argument_encoder setBuffer:current_buffer offset:offset atIndex:current_binding];

      iree_hal_descriptor_set_layout_binding_t* binding_params =
          iree_hal_metal_descriptor_set_layout_binding(set_layout, current_binding);
      if (!binding_params) {
        status = iree_make_status(IREE_STATUS_INVALID_ARGUMENT,
                                  "cannot find information for binding #%u in set #%u",
                                  current_binding, current_set);
        break;
      }
      [compute_encoder useResource:current_buffer
                             usage:iree_hal_metal_get_metal_resource_usage(binding_params)];
    }
    if (!iree_status_is_ok(status)) break;

    [compute_encoder setBuffer:argument_buffer offset:0 atIndex:current_set];
  }

  if (iree_status_is_ok(status)) {
    IREE_RETURN_AND_END_ZONE_IF_ERROR(
        z0, iree_hal_resource_set_insert(command_buffer->resource_set, 1, &executable));
  }

  IREE_TRACE_ZONE_END(z0);
  return status;
}

static iree_status_t iree_hal_metal_command_buffer_dispatch(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_executable_t* executable,
    int32_t entry_point, uint32_t workgroup_count_x, uint32_t workgroup_count_y,
    uint32_t workgroup_count_z) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_metal_kernel_params_t kernel_params;
  IREE_RETURN_AND_END_ZONE_IF_ERROR(
      z0, iree_hal_metal_command_buffer_prepare_dispatch(base_command_buffer, executable,
                                                         entry_point, &kernel_params));

  id<MTLComputeCommandEncoder> compute_encoder =
      iree_hal_metal_get_or_begin_compute_encoder(command_buffer);
  uint32_t* workgroup_size = kernel_params.threadgroup_size;
  [compute_encoder
       dispatchThreadgroups:MTLSizeMake(workgroup_count_x, workgroup_count_y, workgroup_count_z)
      threadsPerThreadgroup:MTLSizeMake(workgroup_size[0], workgroup_size[1], workgroup_size[2])];

  IREE_TRACE_ZONE_END(z0);
  return iree_ok_status();
}

static iree_status_t iree_hal_metal_command_buffer_dispatch_indirect(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_executable_t* executable,
    int32_t entry_point, iree_hal_buffer_t* workgroups_buffer,
    iree_device_size_t workgroups_offset) {
  iree_hal_metal_command_buffer_t* command_buffer =
      iree_hal_metal_command_buffer_cast(base_command_buffer);
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_metal_kernel_params_t kernel_params;
  IREE_RETURN_AND_END_ZONE_IF_ERROR(
      z0, iree_hal_metal_command_buffer_prepare_dispatch(base_command_buffer, executable,
                                                         entry_point, &kernel_params));

  id<MTLComputeCommandEncoder> compute_encoder =
      iree_hal_metal_get_or_begin_compute_encoder(command_buffer);
  uint32_t* workgroup_size = kernel_params.threadgroup_size;
  id<MTLBuffer> metal_buffer =
      iree_hal_metal_buffer_handle(iree_hal_buffer_allocated_buffer(workgroups_buffer));
  [compute_encoder
      dispatchThreadgroupsWithIndirectBuffer:metal_buffer
                        indirectBufferOffset:workgroups_offset
                       threadsPerThreadgroup:MTLSizeMake(workgroup_size[0], workgroup_size[1],
                                                         workgroup_size[2])];

  IREE_TRACE_ZONE_END(z0);
  return iree_ok_status();
}

static iree_status_t iree_hal_metal_command_buffer_execute_commands(
    iree_hal_command_buffer_t* base_command_buffer, iree_hal_command_buffer_t* base_commands,
    iree_hal_buffer_binding_table_t binding_table) {
  return iree_make_status(IREE_STATUS_UNIMPLEMENTED, "unimplemented secondary command buffer");
}

static const iree_hal_command_buffer_vtable_t iree_hal_metal_command_buffer_vtable = {
    .destroy = iree_hal_metal_command_buffer_destroy,
    .dyn_cast = iree_hal_metal_command_buffer_dyn_cast,
    .begin = iree_hal_metal_command_buffer_begin,
    .end = iree_hal_metal_command_buffer_end,
    .begin_debug_group = iree_hal_metal_command_buffer_begin_debug_group,
    .end_debug_group = iree_hal_metal_command_buffer_end_debug_group,
    .execution_barrier = iree_hal_metal_command_buffer_execution_barrier,
    .signal_event = iree_hal_metal_command_buffer_signal_event,
    .reset_event = iree_hal_metal_command_buffer_reset_event,
    .wait_events = iree_hal_metal_command_buffer_wait_events,
    .discard_buffer = iree_hal_metal_command_buffer_discard_buffer,
    .fill_buffer = iree_hal_metal_command_buffer_fill_buffer,
    .update_buffer = iree_hal_metal_command_buffer_update_buffer,
    .copy_buffer = iree_hal_metal_command_buffer_copy_buffer,
    .collective = iree_hal_metal_command_buffer_collective,
    .push_constants = iree_hal_metal_command_buffer_push_constants,
    .push_descriptor_set = iree_hal_metal_command_buffer_push_descriptor_set,
    .dispatch = iree_hal_metal_command_buffer_dispatch,
    .dispatch_indirect = iree_hal_metal_command_buffer_dispatch_indirect,
    .execute_commands = iree_hal_metal_command_buffer_execute_commands,
};

// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "experimental/metal/builtin_executables.h"

#include <string.h>
#include "experimental/metal/builtin/fill_buffer_generic.h"
#include "iree/base/api.h"
#include "iree/base/tracing.h"
#include "iree/hal/api.h"

// The list of builtin executable entry points. This MUST be consistent with kernel function names
// in MSL source code.
static const char* iree_hal_metal_builtin_executable_entry_points[] = {
    "fill_buffer_16byte",  // Buffer fills; 16-byte aligned offset/length
    "fill_buffer_4byte",   // Buffer fills; 4-byte aligned offset/length
    "fill_buffer_1byte",   // Buffer fills; 1-byte aligned offset/length
};

// The buffer fill specificiation. This MUST be consistent with the same struct in MSL source code.
typedef struct iree_hal_metal_buffer_fill_spec {
  uint64_t buffer_offset;  // Buffer offset to fill (in bytes)
  uint64_t buffer_length;  // Buffer length to fill (in bytes)
  uint32_t pattern;        // 32-bit fill pattern
} iree_hal_metal_buffer_fill_spec;

iree_status_t iree_hal_metal_builtin_executable_create(
    id<MTLDevice> device, iree_allocator_t host_allocator,
    iree_hal_metal_builtin_executable_t** out_executable) {
  IREE_ASSERT_ARGUMENT(out_executable);
  *out_executable = NULL;
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_metal_builtin_executable_t* executable = NULL;
  unsigned entry_point_count = IREE_ARRAYSIZE(iree_hal_metal_builtin_executable_entry_points);
  iree_host_size_t total_size =
      sizeof(*executable) + entry_point_count * sizeof(executable->entry_points[0]);
  iree_status_t status = iree_allocator_malloc(host_allocator, total_size, (void**)&executable);

  if (iree_status_is_ok(status)) {
    executable->host_allocator = host_allocator;
    executable->entry_point_count = entry_point_count;

    // Compile each MSL source string into a MTLLibrary and get the MTLFunction for the entry point
    // to build the pipeline state object.
    // TODO(antiagainst): We are performing synchronous compilation at runtime here. This is good
    // for debugging purposes but bad for performance. Enable offline compilation and make that as
    // the default.

    MTLCompileOptions* compile_options = [MTLCompileOptions new];  // +1
    compile_options.languageVersion = MTLLanguageVersion3_0;

    const char* fill_buffer_source_data = fill_buffer_generic_create()[0].data;
    for (unsigned i = 0; i < IREE_ARRAYSIZE(iree_hal_metal_builtin_executable_entry_points); ++i) {
      const char* entry_point = iree_hal_metal_builtin_executable_entry_points[i];

      id<MTLLibrary> library = nil;
      id<MTLFunction> function = nil;
      id<MTLComputePipelineState> pso = nil;
      status = iree_hal_metal_compile_msl(fill_buffer_source_data, entry_point, device,
                                          compile_options, &library, &function, &pso);
      if (!iree_status_is_ok(status)) break;

      // Package required parameters for kernel launches for each entry point.
      iree_hal_metal_kernel_params_t* params = &executable->entry_points[i];
      params->library = library;
      params->function = function;
      params->pso = pso;
      // Thread group size for builtin executables are determined at runtime dispatch time.
      params->threadgroup_size[0] = 0;
      params->threadgroup_size[1] = 0;
      params->threadgroup_size[2] = 0;
      // We don't need the layout parameter for builtin executables too.
      params->layout = NULL;

      // Stash the entry point name in the string table for use when tracing.
      IREE_TRACE({ params->function_name = IREE_SV(entry_point); });
    }

    [compile_options release];  // -1
  }

  if (iree_status_is_ok(status)) {
    *out_executable = executable;
  } else {
    iree_allocator_free(host_allocator, executable);
  }

  IREE_TRACE_ZONE_END(z0);
  return iree_ok_status();
}

void iree_hal_metal_builtin_executable_destroy(iree_hal_metal_builtin_executable_t* executable) {
  IREE_TRACE_ZONE_BEGIN(z0);

  for (iree_host_size_t i = 0; i < executable->entry_point_count; ++i) {
    iree_hal_metal_kernel_params_t* entry_point = &executable->entry_points[i];
    [entry_point->pso release];
    [entry_point->function release];
    [entry_point->library release];
    IREE_ASSERT_EQ(entry_point->layout, NULL);
  }
  iree_allocator_free(executable->host_allocator, executable);

  IREE_TRACE_ZONE_END(z0);
}

static unsigned iree_hal_metal_ceil_div(unsigned a, unsigned b) { return (a + b - 1) / b; }

iree_status_t iree_hal_metal_builtin_executable_fill_buffer(
    const iree_hal_metal_builtin_executable_t* executable, id<MTLComputeCommandEncoder> encoder,
    id<MTLBuffer> target_buffer, iree_device_size_t target_offset, iree_device_size_t length,
    uint32_t pattern) {
  id<MTLComputePipelineState> pso = nil;
  MTLResourceUsage usage = MTLResourceUsageWrite;
  const unsigned workgroup_size = 32;
  unsigned workgroup_count = 0;

  if (target_offset % 16 == 0 && length % 16 == 0) {  // 16-byte aligned case
    pso = executable->entry_points[0].pso;
    workgroup_count = iree_hal_metal_ceil_div(length, workgroup_size * 16);
  } else if (target_offset % 4 == 0 && length % 4 == 0) {  // 4-byte aligned case
    pso = executable->entry_points[1].pso;
    workgroup_count = iree_hal_metal_ceil_div(length, workgroup_size * 4);
  } else {  // 1-byte aligned case
    pso = executable->entry_points[2].pso;
    // We may potentially need to read some 32-bit scalars at unaligned addresses.
    usage |= MTLResourceUsageRead;
    // Calculate unaligned partial prefix/suffix byte count, and then get the middle aligned byte
    // count for distributing threads. This logic MUST be consistent with the MSL source code.
    unsigned left_byte_count = target_offset % 4;
    unsigned right_byte_count = (target_offset + length) % 4;
    int64_t middle_byte_count = length - left_byte_count - right_byte_count;
    // Note that in the extreme case, we don't have aligned bytes in the middle (0), or actually
    // prefix and suffix partial bytes are the same (< 0). We'd need one thread to handle the
    // partial bytes at least.
    if (middle_byte_count <= 0) middle_byte_count = 1;
    workgroup_count = iree_hal_metal_ceil_div(middle_byte_count, workgroup_size * 4);
  }

  iree_hal_metal_buffer_fill_spec spec = {
      .buffer_offset = target_offset,
      .buffer_length = length,
      .pattern = pattern,
  };

  [encoder setComputePipelineState:pso];

  // The following MUST exactly match the pipeline layout from MSL source code.
  // buffer(0) is the target buffer to fill. Note that we MUST set 0 as offset here--the offset
  // is to be handled directly in the kernels!
  [encoder setBuffer:target_buffer offset:0 atIndex:0];
  [encoder useResource:target_buffer usage:usage];
  // buffer(1) is the buffer fill spec.
  [encoder setBytes:&spec length:sizeof(spec) atIndex:1];

  // Encode the dispatch.
  [encoder dispatchThreadgroups:MTLSizeMake(workgroup_count, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(workgroup_size, 1, 1)];
  return iree_ok_status();
}

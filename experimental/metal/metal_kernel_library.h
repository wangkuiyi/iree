// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_EXPERIMENTAL_METAL_METAL_KERNEL_LIBRARY_H_
#define IREE_EXPERIMENTAL_METAL_METAL_KERNEL_LIBRARY_H_

#import <Metal/Metal.h>
#include <stdint.h>

#include "iree/base/api.h"
#include "iree/base/tracing.h"
#include "iree/hal/api.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

typedef struct iree_hal_metal_kernel_params_t {
  id<MTLLibrary> library;
  id<MTLFunction> function;
  id<MTLComputePipelineState> pso;
  uint32_t threadgroup_size[3];
  iree_hal_pipeline_layout_t* layout;
  IREE_TRACE(iree_string_view_t function_name;)
} iree_hal_metal_kernel_params_t;

// Creates a Metal kernel library as an IREE executable. The Metal library may
// contain several kernel functions that can be extracted along with the
// associated block size.
//
// Metal represents compute kernels as MTLFunctions. MTLLibrary is just an
// allocation of MTLFunctions. One creates a MTLComputePipelineState from a
// MTLFunction and uses the pipeline state for creating compute pipelines.
// This class bundles all the necesary Metal objects for getting pipeline state
// objects for a compute kernel.
iree_status_t iree_hal_metal_kernel_library_create(
    iree_allocator_t host_allocator, id<MTLDevice> device,
    const iree_hal_executable_params_t* executable_params,
    iree_hal_executable_t** out_executable);

// Returns the kernel launch parameters for the given |entry_point|.
iree_status_t iree_hal_metal_kernel_library_entry_point_kernel_params(
    iree_hal_executable_t* executable, int32_t entry_point,
    iree_hal_metal_kernel_params_t* out_params);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_EXPERIMENTAL_METAL_METAL_KERNEL_LIBRARY_H_

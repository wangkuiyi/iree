// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_EXPERIMENTAL_METAL_METAL_COMMAND_BUFFER_H_
#define IREE_EXPERIMENTAL_METAL_METAL_COMMAND_BUFFER_H_

#import <Metal/Metal.h>

#include "experimental/metal/builtin_executables.h"
#include "iree/base/internal/arena.h"
#include "iree/hal/api.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Creates a Metal command buffer that directly records into a MTLCommandBuffer.
// Such command buffers are one shot--they can only be submitted once.
//
// If |block_pool| is non-NULL then the command buffer will retain copies of
// input data until reset. If NULL then the caller must ensure the lifetime of
// input data outlives the command buffer.
iree_status_t iree_hal_metal_direct_command_buffer_create(
    iree_hal_device_t* device, iree_hal_command_buffer_mode_t mode,
    iree_hal_command_category_t command_categories,
    iree_host_size_t binding_capacity, id<MTLCommandQueue> queue,
    iree_allocator_t host_allocator, iree_arena_block_pool_t* block_pool,
    iree_hal_metal_builtin_executable_t* builtin_executable,
    iree_hal_command_buffer_t** out_command_buffer);

// Returns true if |command_buffer| is a direct Metal command buffer.
bool iree_hal_metal_direct_command_buffer_isa(
    iree_hal_command_buffer_t* command_buffer);

// Returns the underlying Metal command buffer handle for the given
// |base_command_buffer|.
id<MTLCommandBuffer> iree_hal_metal_direct_command_buffer_handle(
    iree_hal_command_buffer_t* base_command_buffer);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_EXPERIMENTAL_METAL_METAL_COMMAND_BUFFER_H_

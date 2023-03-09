// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_EXPERIMENTAL_METAL_METAL_BUFFER_H_
#define IREE_EXPERIMENTAL_METAL_METAL_BUFFER_H_

#import <Metal/Metal.h>

#include "iree/base/api.h"
#include "iree/hal/api.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Wraps a Metal allocation in an iree_hal_buffer_t by retaining |metal_buffer|.
iree_status_t iree_hal_metal_buffer_wrap(
    id<MTLBuffer> metal_buffer, iree_hal_allocator_t* allocator,
    iree_hal_memory_type_t memory_type, iree_hal_memory_access_t allowed_access,
    iree_hal_buffer_usage_t allowed_usage, iree_device_size_t allocation_size,
    iree_device_size_t byte_offset, iree_device_size_t byte_length,
    iree_hal_buffer_release_callback_t release_callback,
    iree_hal_buffer_t** out_buffer);

// Returns the underlying Metal buffer handle for the given |base_buffer|.
id<MTLBuffer> iree_hal_metal_buffer_handle(
    const iree_hal_buffer_t* base_buffer);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_EXPERIMENTAL_METAL_METAL_BUFFER_H_

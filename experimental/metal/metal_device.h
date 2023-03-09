// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_EXPERIMENTAL_METAL_METAL_DEVICE_H_
#define IREE_EXPERIMENTAL_METAL_METAL_DEVICE_H_

#import <Metal/Metal.h>

#include "experimental/metal/api.h"
#include "iree/base/api.h"
#include "iree/hal/api.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Creates a Metal device.
iree_status_t iree_hal_metal_device_create(
    iree_hal_driver_t* driver, iree_string_view_t identifier,
    const iree_hal_metal_device_params_t* params, id<MTLDevice> device,
    iree_allocator_t host_allocator, iree_hal_device_t** out_device);

// Returns the parameters used for creating the device.
const iree_hal_metal_device_params_t* iree_hal_metal_device_params(
    const iree_hal_device_t* base_device);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_EXPERIMENTAL_METAL_METAL_DEVICE_H_

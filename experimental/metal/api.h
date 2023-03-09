// Copyright 2023 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

// See iree/base/api.h for documentation on the API conventions used.

#ifndef IREE_EXPERIMENTAL_METAL_API_H_
#define IREE_EXPERIMENTAL_METAL_API_H_

#include "iree/base/api.h"
#include "iree/hal/api.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

//===----------------------------------------------------------------------===//
// iree_hal_metal_device_params_t
//===----------------------------------------------------------------------===//

typedef enum iree_hal_metal_command_dispatch_type_e {
  // Dispatching commands in command buffer in parallel.
  IREE_HAL_METAL_COMMAND_DISPATCH_TYPE_CONCURRENT = 0,
  // Dispatching commands in command buffer sequentially.
  IREE_HAL_METAL_COMMAND_DISPATCH_TYPE_SERIAL = 1,
} iree_hal_metal_command_dispatch_type_t;

typedef enum iree_hal_metal_resource_hazard_tracking_mode_e {
  // Letting the app to prevent hazards when modifying this object's contents.
  IREE_HAL_METAL_RESOURCE_HAZARD_TRACKING_MODE_UNTRACKED = 0,
  // Letting the Metal runtime to prevent hazards when modifying this object's
  // contents.
  IREE_HAL_METAL_RESOURCE_HAZARD_TRACKING_MODE_TRACKED = 1,
} iree_hal_metal_resource_hazard_tracking_mode_t;

// Parameters configuring an iree_hal_metal_device_t.
// Must be initialized with iree_hal_metal_device_params_initialize prior to
// use.
typedef struct iree_hal_metal_device_params_t {
  // Total size of each block in the device shared block pool.
  // Larger sizes will lower overhead and ensure the heap isn't hit for
  // transient allocations while also increasing memory consumption.
  iree_host_size_t arena_block_size;

  // Command dispatch type in command buffers.
  // Normally we want to dispatch commands in command buffers in parallel, given
  // that IREE performs explicit dependency tracking and synchronization by
  // itself. Though being able to specify serial command dispatching helps
  // debugging in certain cases.
  iree_hal_metal_command_dispatch_type_t command_dispatch_type;

  // Resource hazard tracking mode.
  // IREE is following explicit GPU API model and tracks resource dependency by
  // itself. So normally we don't need to let Metal runtime to track resource
  // usages and prevent hazards, which incurs runtime overhead. But it can be
  // helpful for debugging purposes.
  iree_hal_metal_resource_hazard_tracking_mode_t resource_hazard_tracking_mode;
} iree_hal_metal_device_params_t;

// Initializes |out_params| to default values.
void iree_hal_metal_device_params_initialize(
    iree_hal_metal_device_params_t* out_params);

//===----------------------------------------------------------------------===//
// iree_hal_metal_driver_t
//===----------------------------------------------------------------------===//

// Creates a Metal HAL driver.
//
// |out_driver| must be released by the caller (see |iree_hal_driver_release|).
IREE_API_EXPORT iree_status_t iree_hal_metal_driver_create(
    iree_string_view_t identifier,
    const iree_hal_metal_device_params_t* device_params,
    iree_allocator_t host_allocator, iree_hal_driver_t** out_driver);

// Returns the parameters used for creating the device.
const iree_hal_metal_device_params_t* iree_hal_metal_driver_device_params(
    const iree_hal_driver_t* base_driver);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_EXPERIMENTAL_METAL_API_H_

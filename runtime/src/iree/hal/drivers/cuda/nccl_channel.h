// Copyright 2022 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_HAL_DRIVERS_CUDA_NCCL_CHANNEL_H_
#define IREE_HAL_DRIVERS_CUDA_NCCL_CHANNEL_H_

#include "iree/base/api.h"
#include "iree/hal/api.h"
#include "iree/hal/drivers/cuda/api.h"
#include "iree/hal/drivers/cuda/context_wrapper.h"
#include "iree/hal/drivers/cuda/cuda_headers.h"
#include "iree/hal/utils/collective_batch.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Creates a new NCCL communicator channel.
typedef struct ncclComm* ncclComm_t;

iree_status_t iree_hal_cuda_nccl_channel_create(
    iree_hal_cuda_context_wrapper_t* context_wrapper,
    const iree_hal_cuda_nccl_id_t* id, int rank, int count,
    iree_hal_channel_t** out_channel);

// Returns the NCCL communicator for the given |channel|, if available.
ncclComm_t iree_hal_cuda_nccl_channel_comm(iree_hal_channel_t* channel);

// Performs a non-blocking submission of |batch| to |stream|.
// The backing storage of |batch| is dropped immediately but all resources
// referenced will be retained by the parent command buffer for its lifetime.
// Note that operations in the batch may apply to different channels.
iree_status_t iree_hal_cuda_nccl_submit_batch(
    iree_hal_cuda_context_wrapper_t* context,
    const iree_hal_collective_batch_t* batch, CUstream stream);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // IREE_HAL_DRIVERS_CUDA_NCCL_CHANNEL_H_

// Copyright 2020 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_COMPILER_DIALECT_HAL_TARGET_METALSPIRV_SPIRVTOMSL_H_
#define IREE_COMPILER_DIALECT_HAL_TARGET_METALSPIRV_SPIRVTOMSL_H_

#include <array>
#include <string>

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/Optional.h"
#include "llvm/ADT/StringRef.h"
#include "mlir/Support/LLVM.h"

namespace mlir {
namespace iree_compiler {

struct MetalShader {
  std::string source;
  struct ThreadGroupSize {
    uint32_t x;
    uint32_t y;
    uint32_t z;
  } threadgroupSize;
};

// Cross compiles SPIR-V into Metal Shading Language source code for the
// compute shader with |entryPoint| and returns the MSL source and the new
// entry point name. Returns std::nullopt on failure.
llvm::Optional<std::pair<MetalShader, std::string>> crossCompileSPIRVToMSL(
    llvm::ArrayRef<uint32_t> spvBinary, StringRef entryPoint);

}  // namespace iree_compiler
}  // namespace mlir

#endif  // IREE_COMPILER_DIALECT_HAL_TARGET_METALSPIRV_SPIRVTOMSL_H_

# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  stdenv,
  nixComponents,
  rustPlatform,
  pkg-config,
  cmake,
  boost,
  nlohmann_json,
  llvmPackages ? null,
  enableSanitizers ? false,
  nixVersion ? nixComponents.version or "unknown",
}:

assert enableSanitizers -> llvmPackages != null;
assert enableSanitizers -> stdenv.cc.isClang;
# The minimal UBSan runtime is statically pulled in via GNU-ld
# --whole-archive from compiler-rt's lib/linux/; no darwin equivalent is
# wired up.
assert enableSanitizers -> stdenv.hostPlatform.isLinux;

let
  rustLib = import ./rust.nix { inherit lib rustPlatform; };
in
stdenv.mkDerivation {
  pname = "cargo-nix-plugin";
  version = "0.1.0";

  src = ../cpp;

  nativeBuildInputs = [
    pkg-config
    cmake
  ];

  buildInputs = [
    nixComponents.nix-expr
    nixComponents.nix-store
    boost
    nlohmann_json
  ];

  cmakeFlags = [
    "-DRUST_LIB_DIR=${rustLib}/lib"
    "-DNIX_COMPILE_VERSION=${nixVersion}"
  ]
  ++ lib.optionals enableSanitizers [
    "-DENABLE_SANITIZERS=ON"
    # compiler-rt names the archive after the clang arch token
    # (x86_64, aarch64, …), which matches `parsed.cpu.name`.
    "-DSANITIZER_RT_LIB=${llvmPackages.compiler-rt}/lib/linux/libclang_rt.ubsan_minimal-${stdenv.hostPlatform.parsed.cpu.name}.a"
  ];

  # Don't strip sanitizer-instrumented binaries — removes UBSan metadata.
  dontStrip = enableSanitizers;

  meta = {
    description = "Nix plugin for resolving Cargo workspaces";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}

# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "build-rust-crate";
  version = "0.1.0";
  src = ../builder;
  cargoLock.lockFile = ../builder/Cargo.lock;
  doCheck = true;

  meta = {
    description = "Rust-native buildRustCrate phase runner";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}

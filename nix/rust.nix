# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# Build the resolver static library and the prefetch binary once. Both the
# plugin and the `cargo-nix-prefetch` package consume this output.
{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "cargo-nix-plugin-core";
  version = "0.1.0";
  src = ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
  cargoBuildFlags = [
    "--lib"
    "--bin"
    "cargo-nix-prefetch"
  ];

  meta = {
    description = "Cargo workspace resolver shared by the plugin and prefetch CLI";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}

# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  pkgs,
  rustPlatform,
}:

let
  rust = import ./rust.nix { inherit lib rustPlatform; };
in
pkgs.runCommand "cargo-nix-prefetch"
  {
    meta = {
      description = "Warm the sparse registry index cache for a Cargo workspace";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
      mainProgram = "cargo-nix-prefetch";
    };
  }
  ''
    mkdir -p $out/bin
    ln -s ${rust}/bin/cargo-nix-prefetch $out/bin/cargo-nix-prefetch
  ''

# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# A plugin whose compiled version is in a different minor must be rejected
# before it is used, even when the binary ABI happens to load.
{
  pkgs,
  plugin,
  nix,
  pluginSrc,
  testFixtures,
}:

pkgs.runCommand "cargo-nix-plugin-minor-mismatch-test"
  {
    nativeBuildInputs = [ nix ];
  }
  ''
    export HOME=$(mktemp -d)
    export NIX_STORE_DIR=$TMPDIR/nix/store
    export NIX_STATE_DIR=$TMPDIR/nix/var
    export NIX_LOG_DIR=$TMPDIR/nix/log
    mkdir -p $NIX_STORE_DIR $NIX_STATE_DIR $NIX_LOG_DIR

    if nix-instantiate --eval --strict --read-write-mode \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr '
        let
          pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
        in
        builtins.length (builtins.attrNames (import ${pluginSrc}/lib {
          inherit pkgs;
          metadata = builtins.readFile "${testFixtures}/metadata.json";
          cargoLock = builtins.readFile "${testFixtures}/Cargo.lock";
          src = /dev/null;
        }).workspaceMembers)
      ' > guard.out 2> guard.err
    then
      echo "minor version mismatch was accepted" >&2
      exit 1
    fi
    grep -q "plugin version mismatch" guard.err
    touch $out
  ''

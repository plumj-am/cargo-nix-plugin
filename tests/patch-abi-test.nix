# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# Load a plugin built against an older patch in the current minor into the
# current patch binary. The ABI is expected to stay compatible inside a
# minor; the library guard must accept the patch mismatch with a warning.
{
  pkgs,
  plugin,
  nix,
  pluginSrc,
  testFixtures,
  expectedVersion,
}:

pkgs.runCommand "cargo-nix-plugin-patch-abi-test"
  {
    nativeBuildInputs = [ nix ];
  }
  ''
    export HOME=$(mktemp -d)
    export NIX_STORE_DIR=$TMPDIR/nix/store
    export NIX_STATE_DIR=$TMPDIR/nix/var
    export NIX_LOG_DIR=$TMPDIR/nix/log
    mkdir -p $NIX_STORE_DIR $NIX_STATE_DIR $NIX_LOG_DIR

    nix_instantiate() {
      nix-instantiate --eval --strict --read-write-mode \
        --option plugin-files "${plugin}/lib/nix/plugins" \
        --expr "$1"
    }

    # The plugin reports its build patch; the host reports the current
    # patch. Both must be in the same minor for this check.
    version=$(nix-instantiate --eval --strict --raw --read-write-mode \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr 'builtins.cargoNixNixVersion')
    [[ "$version" == "${expectedVersion}" ]] || {
      echo "unexpected plugin version: $version (want ${expectedVersion})" >&2
      exit 1
    }

    # Exercise the primop directly.
    nix_instantiate 'import ${pluginSrc}/tests/eval-test.nix { fixtures = ${testFixtures}; }' \
      > $out

    # Exercise the wrapper guard. It must accept the patch skew and warn.
    nix_instantiate '
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
    grep -q "patch mismatch" guard.err
    test "$(cat guard.out)" = 224
  ''

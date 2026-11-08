# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# Plugin boundary test: malformed input must produce an eval error, not an
# abort. Runs nix-instantiate with the plugin loaded and asserts on stderr.
{
  pkgs,
  plugin,
  testFixtures,
  nix,
}:

let
  # `lib/default.nix` resolves `../nix` and `../tests` relative to the source
  # tree, so the wrapper test needs a copy that keeps those paths together.
  repo = builtins.path {
    path = ../.;
    name = "cargo-nix-plugin-source";
    filter =
      path: _type:
      let
        rel = pkgs.lib.removePrefix (toString ../.) path;
      in
      rel == ""
      || rel == "/tests"
      || pkgs.lib.hasPrefix "/lib" rel
      || pkgs.lib.hasPrefix "/builder" rel
      || pkgs.lib.hasPrefix "/nix" rel
      || pkgs.lib.hasPrefix "/tests/external-path-dep" rel
      || pkgs.lib.hasPrefix "/tests/external-path-workspace" rel;
  };
in
pkgs.runCommand "cargo-nix-plugin-error-path-test"
  {
    nativeBuildInputs = [ nix ];
  }
  ''
    export HOME=$(mktemp -d)
    export NIX_STORE_DIR=$TMPDIR/nix/store
    export NIX_STATE_DIR=$TMPDIR/nix/var
    export NIX_LOG_DIR=$TMPDIR/nix/log
    mkdir -p $NIX_STORE_DIR $NIX_STATE_DIR $NIX_LOG_DIR

    nix_eval() {
      nix-instantiate --eval --strict --read-write-mode \
        --option plugin-files "${plugin}/lib/nix/plugins" \
        --expr "$1"
    }

    expect_error() {
      local label="$1"
      local pattern="$2"
      local expr="$3"
      if nix_eval "$expr" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"; then
        echo "FAIL: $label unexpectedly succeeded"
        exit 1
      fi
      grep -Fq "$pattern" "$TMPDIR/stderr" || {
        echo "FAIL: $label missing '$pattern':"
        sed -n '1,20p' "$TMPDIR/stderr"
        exit 1
      }
    }

    nix_eval_no_plugin() {
      nix-instantiate --eval --strict --read-write-mode --expr "$1"
    }

    expect_error_no_plugin() {
      local label="$1"
      local pattern="$2"
      local expr="$3"
      if nix_eval_no_plugin "$expr" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"; then
        echo "FAIL: $label unexpectedly succeeded"
        exit 1
      fi
      grep -Fq "$pattern" "$TMPDIR/stderr" || {
        echo "FAIL: $label missing '$pattern':"
        sed -n '1,20p' "$TMPDIR/stderr"
        exit 1
      }
    }

    target='{
      name = "x86_64-unknown-linux-gnu";
      os = "linux";
      arch = "x86_64";
      vendor = "unknown";
      env = "";
      abi = "";
      family = [ "unix" ];
      pointer_width = "64";
      endian = "little";
      unix = true;
      windows = false;
    }'

    expect_error \
      "missing resolve mode" \
      "Provide either 'metadata'" \
      "builtins.resolveCargoWorkspace { target = $target; }"

    expect_error_no_plugin \
      "missing plugin" \
      "builtins.resolveCargoWorkspace is not loaded" \
      "let
        cargoNix = import ${repo}/lib {
          pkgs = import ${pkgs.path} { system = \"${pkgs.stdenv.hostPlatform.system}\"; };
          metadata = builtins.readFile \"${testFixtures}/metadata.json\";
          cargoLock = builtins.readFile \"${testFixtures}/Cargo.lock\";
          src = /dev/null;
        };
      in cargoNix.resolved"

    expect_error \
      "malformed metadata" \
      "Failed to parse metadata" \
      "builtins.resolveCargoWorkspace {
        metadata = \"not json\";
        cargoLock = builtins.readFile \"${testFixtures}/Cargo.lock\";
        target = $target;
      }"

    expect_error \
      "malformed Cargo.lock" \
      "failed to parse Cargo.lock" \
      "builtins.resolveCargoWorkspace {
        metadata = builtins.readFile \"${testFixtures}/metadata.json\";
        cargoLock = \"this is not toml\";
        target = $target;
      }"

    cat > "$TMPDIR/bad-checksum.lock" <<'EOF'
version = 4

[[package]]
name = "bad"
version = "1.0.0"
checksum = "nothex"
EOF
    expect_error \
      "invalid checksum" \
      "invalid checksum for bad 1.0.0" \
      "builtins.resolveCargoWorkspace {
        metadata = builtins.readFile \"${testFixtures}/metadata.json\";
        cargoLock = builtins.readFile \"$TMPDIR/bad-checksum.lock\";
        target = $target;
      }"

    expect_error \
      "metadata with rootFeatures" \
      "rootFeatures and noDefaultFeatures require lockfile-resolve mode" \
      "builtins.resolveCargoWorkspace {
        metadata = builtins.readFile \"${testFixtures}/metadata.json\";
        cargoLock = builtins.readFile \"${testFixtures}/Cargo.lock\";
        target = $target;
        rootFeatures = [ \"serde\" ];
      }"

    expect_error \
      "wrapper metadata with rootFeatures" \
      "rootFeatures and noDefaultFeatures require lockfile-resolve mode" \
      "let
        cargoNix = import ${repo}/lib {
          pkgs = import ${pkgs.path} { system = \"${pkgs.stdenv.hostPlatform.system}\"; };
          metadata = builtins.readFile \"${testFixtures}/metadata.json\";
          cargoLock = builtins.readFile \"${testFixtures}/Cargo.lock\";
          src = /dev/null;
          rootFeatures = [ \"serde\" ];
        };
      in cargoNix.resolved"

    expect_error \
      "wrapper external path without localSrc" \
      "out-of-tree path dependency" \
      "let
        cargoNix = import ${repo}/lib {
          pkgs = import ${pkgs.path} { system = \"${pkgs.stdenv.hostPlatform.system}\"; };
          src = ${repo}/tests;
          manifestPath = ${repo}/tests/external-path-workspace/Cargo.toml;
          allowExternalPathDeps = true;
        };
      in cargoNix.workspaceMembers.external-path-workspace.build.drvPath"

    touch $out
  ''

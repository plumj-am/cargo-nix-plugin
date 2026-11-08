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

    touch $out
  ''

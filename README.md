# cargo-nix-plugin

A Nix plugin that resolves Cargo workspaces natively, replacing the generated
`Cargo.nix` file from crate2nix with a single `builtins.resolveCargoWorkspace`
primop.

## What It Does

- Reads `Cargo.lock` and the sparse registry index directly, so there is no
  `cargo` binary at eval time (you can also feed it pre-generated
  `cargo metadata` JSON)
- Evaluates `cfg()` target expressions for your platform during resolution
- Produces an attrset that plugs into `buildRustCrate`
- No more `crate2nix generate` step or checked-in 50K-100K line `Cargo.nix`

## Install

The primop must be loaded by the **Nix that evaluates your build**. Adding
the flake input alone does not load it.

Build the plugin for that Nix version (the default is built against 2.35,
see [Compatibility](#compatibility)):

```bash
PLUGIN=$(nix build .#cargo-nix-plugin --print-out-paths)
echo "plugin-files = $PLUGIN/lib/nix/plugins"
```

Add that line to `nix.conf`, or pass it per invocation:

```bash
NIX_CONFIG="plugin-files = $PLUGIN/lib/nix/plugins" nix build .#myPackage
```

The flake input supplies `lib` and matched client/plugin package outputs:

```nix
{
  inputs.cargo-nix-plugin.url = "github:anthropics/cargo-nix-plugin";
}
```

Build the pair for a specific Nix version:

```bash
NIX=$(nix build .#nix_2_35 --print-out-paths | grep -v man)
PLUGIN=$(nix build .#cargo-nix-plugin-nix_2_35 --print-out-paths)
```

Or use the bootstrap wrapper, which preloads the matching plugin:

```bash
nix run .#nixBootstrap -- build .#myPackage
```

`.#nixBootstrap` is built for the default plugin version. The per-version
wrapper is also available, for example
`.#nix-with-cargo-nix-plugin-nix_2_34`.

`.#cargo-nix-nix` selects a plugin for the `nix` on `PATH`, probes it in a
child process, then execs that Nix with the plugin loaded. It supports the
stable minors listed in `nixVersions`:

```bash
nix run .#cargo-nix-nix -- build .#myPackage
```

A consuming flake can also set `nixConfig.plugin-files`, but that only works
for trusted flakes and makes evaluation impure. Prefer `nix.conf` for CI and
shared machines.

On NixOS, import `nixosModules.default`. It sets `nix.package` from the
matched Nix output and adds `plugin-files`:

```nix
{
  inputs.cargo-nix-plugin.url = "github:anthropics/cargo-nix-plugin";
  # nixpkgs follows your host flake
}
```

```nix
nixosConfigurations.host = nixpkgs.lib.nixosSystem {
  modules = [
    cargo-nix-plugin.nixosModules.default
    { cargo-nix-plugin.enable = true; }
  ];
};
```

Override both `cargo-nix-plugin.package` and `cargo-nix-plugin.nixPackage`
with the matching versioned outputs when you intentionally run a different
Nix version:

```nix
{
  cargo-nix-plugin.package =
    inputs.cargo-nix-plugin.packages.${pkgs.stdenv.hostPlatform.system}.cargo-nix-plugin-nix_2_34;
  cargo-nix-plugin.nixPackage =
    inputs.cargo-nix-plugin.packages.${pkgs.stdenv.hostPlatform.system}.nix_2_34;
}
```

## Usage

### Default (lockfile resolve)

Point at your workspace root:

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;  # must contain Cargo.toml + Cargo.lock
};
```

The plugin reads `Cargo.lock` plus the sparse registry index directly — no
`cargo` binary, no crate sources at eval time. On first use it fetches each
crate's index entry (a few hundred bytes) into `$CARGO_HOME` and reuses it
on later runs.

If you already redirect cargo to a mirror (`CARGO_REGISTRIES_CRATES_IO_INDEX`
or `[source.crates-io] replace-with` in `.cargo/config.toml`), the resolver
picks that up too:

```toml
# .cargo/config.toml — used by both cargo and the plugin
[source.crates-io]
replace-with = "mirror"
[source.mirror]
registry = "sparse+https://artifactory.example/api/cargo/crates/index/"
```

If every index lookup fails (e.g. egress to `index.crates.io` is blocked and
no mirror is configured), evaluation fails rather than silently producing
derivations with missing features.

### Explicit metadata

You can also generate cargo's resolution up front and pass it in:

```bash
cargo metadata --format-version 1 --locked > metadata.json
```

Then:

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  metadata = builtins.readFile ./metadata.json;
  cargoLock = builtins.readFile ./Cargo.lock;
  src = ./.;
};
```

Or use the helper:

```bash
nix run .#generate-metadata -- > metadata.json
```

### Pre-fetching the index cache

If the machine doing the evaluation can't reach any index, run
`cargo-nix-prefetch` on one that can. It fills `$CARGO_HOME` and follows the
same mirror configuration as the plugin:

```bash
nix run .#cargo-nix-prefetch -- --manifest-path ./Cargo.toml
nix run .#cargo-nix-prefetch -- --manifest-path ./Cargo.toml --check   # verify
```

Use `--output DIR` to write to a separate directory instead of `$CARGO_HOME`
and point the resolver at it:

```bash
nix run .#cargo-nix-prefetch -- --manifest-path ./Cargo.toml --output ./.cargo-index
```

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;
  cargoHome = ./.cargo-index;   # pre-warmed by cargo-nix-prefetch
};
```

You can also wrap this in a fixed-output derivation if you'd rather pin the
cache by hash than check it in.

### Git dependencies

`git+…` entries in `Cargo.lock` are fetched at eval time with
`builtins.fetchGit { url; rev; allRefs = true; submodules = true; }` so the
resolver can read each crate's `Cargo.toml` (the registry index has no
record of them). Submodules are pulled to match cargo, which always
recurses them for git deps. When the upstream repo is a Cargo workspace,
the resolver locates the right member and passes its sub-directory to
`buildRustCrate` as `workspace_member`.

Override `gitSources` when `fetchGit` can't reach the repo (private auth,
vendored fixture), to pin a `narHash`/use a FOD fetcher, or to skip
submodules for a repo that doesn't need them:

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;
  gitSources = {
    # key = "${url}#${rev}" with git+ and ?query stripped — exactly what
    # appears in Cargo.lock after `git+` and before `?`, plus `#REV`.
    "https://github.com/Byron/gitoxide#abcdef…" = pkgs.fetchgit {
      url = "git@github.com:Byron/gitoxide";
      rev = "abcdef…";
      hash = "sha256-…";
    };
  };
};
```

A `git+` source without a pinned `#rev` is rejected; `Cargo.lock` always
pins one.

### Debug logging

The resolver is quiet by default. Set `CARGO_NIX_DEBUG=1` to get
informational logs (mirror selection, index prefetch timings, per-crate
retries) on stderr. Warnings and errors are always printed.

## Options

`import ./lib` accepts these arguments. Defaults are shown.

| Option | Default | Purpose |
|---|---|---|
| `src` | required unless `metadata` | Workspace root containing `Cargo.toml` and `Cargo.lock` |
| `metadata` | `null` | Explicit `cargo metadata --format-version 1 --locked` JSON |
| `cargoLock` | `null` | `Cargo.lock` contents; required with `metadata` |
| `manifestPath` | `src + "/Cargo.toml"` | Lockfile-mode manifest path override |
| `target` | `stdenv.hostPlatform` | Target platform description for cfg resolution |
| `rootFeatures` | `[ ]` | Root features, bare or `member/feature`; lockfile mode only |
| `noDefaultFeatures` | `false` | Disable root default features; lockfile mode only |
| `localSrc` | workspace source | Per-crate source override; receives relative paths, and absolute paths for out-of-tree deps |
| `extraRegistries` | `{ }` | Map registry index URL to `{ dl, fetchurl ? … }` |
| `extraCfgs` | `[ ]` | Extra bare cfg names for dependency resolution |
| `allowExternalPathDeps` | `false` | Permit out-of-tree path deps; pair with `localSrc` |
| `procMacroCrates` | `[ ]` | Registry crates to force-route as proc-macros |
| `cargoHome` | `$CARGO_HOME` or `~/.cargo` | Registry index cache location |
| `gitSources` | auto from `Cargo.lock` | Pre-fetched git checkouts keyed by `url#rev` |
| `crateOverrides` | `null` | Passed to `buildRustCrate` |
| `buildRustCrateForPkgs` | vendored builder | Customize instead of replace the builder |
| `clippyArgs` | `[ ]` | Extra clippy-driver arguments |
| `clippyCapLints` | `"forbid"` | `--cap-lints` value for clippy builds |
| `clippyAllFeatures` | `false` | Re-resolve with every workspace feature; lockfile mode only |
| `allowVersionMismatch` | `false` | Bypass the plugin apiLevel/Nix version guard |

## Example

The plugin must be loaded by Nix in the same major.minor version it was
compiled against (see [Compatibility](#compatibility)); patch releases in
one minor are accepted with a warning. Evaluate with the plugin loaded via
`--option`:

```bash
PLUGIN=$(nix build .#cargo-nix-plugin-nix_2_35 --print-out-paths)
NIX=$(nix build .#nix_2_35 --print-out-paths | grep -v man)

$NIX/bin/nix-instantiate --eval \
  --option plugin-files "$PLUGIN/lib/nix/plugins" \
  -E '(import ./lib { pkgs = import <nixpkgs> {}; src = ./.; }).workspaceMembers'
```

Or permanently in `nix.conf` / `~/.config/nix/nix.conf` (only if your system
Nix matches the plugin's build version):

```ini
plugin-files = /path/to/cargo-nix-plugin/lib/nix/plugins
```

### flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    cargo-nix-plugin.url = "github:anthropics/cargo-nix-plugin";
  };

  outputs = { self, nixpkgs, cargo-nix-plugin }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      cargoNix = cargo-nix-plugin.lib {
        inherit pkgs;
        src = ./.;
      };
    in {
      packages.x86_64-linux.default = cargoNix.rootCrate.build;
    };
}
```

## Clippy

The wrapper provides cached clippy checks via `cargoNix.clippy`. Dependencies
are compiled once with `rustc` and cached in the Nix store; only workspace
members are re-checked with `clippy-driver`. This means running clippy on a
large workspace is as fast as compiling just your local crates.

Pass `clippyAllFeatures = true` (lockfile-resolve mode only) to lint with
every workspace feature enabled, like `cargo clippy --all-features`, so
feature-gated code is checked too.

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;
};

# Check all workspace members
cargoNix.clippy.allWorkspaceMembers

# Check a single member without retaining linked terminal artifacts
cargoNix.clippy.workspaceMembers.my-crate.check

# Include library, binary, unit-test, and integration-test targets
cargoNix.clippy.workspaceMembers.my-crate.checkTests

# Collect cached JSON diagnostics from all workspace members
cargoNix.clippy.report
```

To fail on warnings, pass extra clippy flags:

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;
  clippyArgs = [ "-D" "warnings" ];
};
```

Workspace members are built with `--cap-lints forbid` (no effective cap,
matching cargo). Pass `clippyCapLints = "warn"` to demote all findings to
warnings instead.

Each clippy member build retains its raw rustc JSON diagnostics at
`cargoNix.clippy.workspaceMembers.<name>.report`. The aggregate
`cargoNix.clippy.report` derivation collects those cached diagnostics as one
`<name>.jsonl` file per workspace member, so CI can publish annotations without
re-running clippy. The build log still shows the rendered diagnostics; only the
on-disk report is JSON.

The compatibility `.build` output installs normal artifacts. `.check` and
`.checkTests` use metadata emission only for terminal bin and test targets;
dependency libraries, proc macros, and build scripts remain normal reusable
builds. The selected root library is compiled normally for its terminal targets
but is not installed in the metadata verdict output. That output retains JSON
diagnostics and direct dependency references, but no terminal executables.

The report is an output of the clippy build, so it only exists when that build
succeeds. If you need both the JSON and a failing CI gate, leave `clippyArgs`
without `-D warnings` and build `cargoNix.clippy.reportCheck` instead — it
depends on `clippy.report` and fails if any member has warning- or error-level
findings.

### How clippy caching works

`clippy-driver` is a drop-in replacement for `rustc` — it accepts identical
command-line flags and produces the same artifacts, but also runs lint passes.
The wrapper creates a small shim package where `bin/rustc` calls
`clippy-driver`, and passes it as the `rust` override to `buildRustCrate` for
each selected workspace root. All dependency edges, including workspace-member
dependencies, use normal lib-only `rustc` outputs. They therefore resolve to the
**exact same Nix store paths** as a regular build — no redundant terminal builds.
With `clippyAllFeatures = true`, dependencies whose feature set grows are rebuilt
once for the clippy path; everything else is still shared with the regular build.

## Tests

```nix
checks.x86_64-linux.my-crate-tests =
  cargoNix.workspaceMembers.my-crate.runTests;

# Link production or test targets without retaining their executables
checks.x86_64-linux.my-crate-verify =
  cargoNix.workspaceMembers.my-crate.verify;
checks.x86_64-linux.my-crate-verify-tests =
  cargoNix.workspaceMembers.my-crate.verifyTests;
```

`runTests` compiles lib unit tests and integration tests under `tests/`
(with `[dev-dependencies]` wired in) and runs them sequentially. The regular
`.build` derivation is unchanged. Integration tests can spawn the crate's
binaries via `env!("CARGO_BIN_EXE_<name>")` exactly as under `cargo test`.

Tests that shell out to external tools at runtime declare them via
`nativeCheckInputs` in `crateOverrides`; `runTests` puts them on PATH:

```nix
cargoNix = cargo-nix-plugin.lib {
  inherit pkgs;
  src = ./.;
  crateOverrides = pkgs.defaultCrateOverrides // {
    my-crate = _: { nativeCheckInputs = [ pkgs.sqlite ]; };
  };
};
```

The runner sets `RUST_BACKTRACE=1` and points `CARGO_TARGET_TMPDIR` at a
fresh temp dir. If you need different behaviour (test filters, `--nocapture`,
a custom harness), the compiled artefacts are at `.buildTests` —
`$out/tests/*` are the test executables, `$out/bin/*` the real binaries —
and `runTests.passthru.testsDrv` points there too.

Each member keeps the existing `.build`, `.buildTests`, and `.runTests`
interfaces. `.verify` and `.verifyTests` perform the same full compilation and
linking as their install variants, then retain only a success verdict and the
direct effective dependency references. Nix follows those references
transitively, so Cargo-Nix does not serialize a duplicate dependency graph.

`buildRustCrate` also accepts `debugInfo = 0`, `1`, or `2`. Release builds
default to `0`; non-release builds default to `2`. The value is passed to both
target and build-script rustc invocations and controls whether stdenv strips
the installed output.

### Nextest

Each member exposes nextest targets, plus a metadata export for reusing the
build in an external nextest invocation:

```nix
checks.x86_64-linux.my-crate-nextest =
  cargoNix.workspaceMembers.my-crate.nextestRun;

# Explicit workspace source, e.g. a filtered copy with only manifests.
checks.x86_64-linux.my-crate-nextest-filtered =
  cargoNix.workspaceMembers.my-crate.nextestRunFor ./filtered-src;

# cargo-metadata-shaped JSON for nextest's reuse-build.
checks.x86_64-linux.my-crate-nextest-metadata =
  cargoNix.nextestCargoMetadata;
```

`nextestRun` compiles lib, integration, and bin test targets, then runs
`cargo nextest`. The `mkNextestCargoMetadata { memberDir = …; }` variant lets
you override where each member's source lives when passing a filtered tree.

### Doctests

```nix
checks.x86_64-linux.my-crate-doctest =
  cargoNix.workspaceMembers.my-crate.doctest;
```

`doctest` runs the member's `///` examples with `rustdoc --test`
(equivalently `cargo test --doc`) in the sandbox. It builds on the
`buildTests` variant, so the crate's own rlib and every dependency —
dev-dependencies included — are present, and reuses the exact externs,
features, edition, and build-script cfgs that compiled the crate, so a
doctest can't pass vacuously against a divergent dependency set. The
derivation fails iff a doctest fails. A member with no lib target is a
no-op, matching `cargo test --doc`.

Known limitations: per-`[[bin]]` unit tests are not compiled, and tests
under `examples/` / `benches/` are not discovered.

## How It Works

1. **Nix plugin**: Adds a `builtins.resolveCargoWorkspace` primop to Nix. When
   you call `cargo-nix-plugin.lib { ... }`, this primop resolves your entire
   Cargo workspace — dependencies, features, platform-specific conditionals —
   and returns the crate graph as a Nix attrset. In the default mode it reads
   `Cargo.lock` and the sparse registry index directly; in explicit mode it
   parses pre-provided `cargo metadata` JSON.

2. **Nix wrapper**: Takes the resolved crate graph and
   builds each crate with `buildRustCrate`, wiring up dependencies
   automatically. Supports proc-macro cross-compilation, crate overrides,
   and the standard `workspaceMembers`/`rootCrate` interface.

## Target Platform

The plugin accepts a target description attrset:

```nix
target = {
  name = "x86_64-unknown-linux-gnu";
  os = "linux"; arch = "x86_64"; vendor = "unknown"; env = "gnu";
  family = ["unix"]; pointer_width = "64"; endian = "little";
  unix = true; windows = false;
};
```

The wrapper auto-detects this from `stdenv.hostPlatform`.

## Custom cfgs

To set custom cfgs during `[target.'cfg(...)']` dependency resolution
(equivalent to `RUSTFLAGS="--cfg foo"` at cargo-metadata time), pass
`extraCfgs`:

```nix
extraCfgs = [ "my_platform" ];
```

Pair with passing the same `--cfg` via rustc opts so `#[cfg(foo)]` in source
compiles too — `extraCfgs` only affects dependency resolution.

## Compatibility

- **Nix**: The plugin must match the evaluating Nix **major.minor**. Patch
  releases in one minor are treated as compatible and produce a warning when
  they differ. The ABI is not stable across minors. If you see errors like
  `expected a set but found a set`, the plugin and Nix are in different
  minors. `.#cargo-nix-plugin` (the default) is built against Nix 2.35, so
  use Nix 2.35.x to evaluate:

  ```bash
  # Use the matching pair from this flake
  NIX=$(nix build .#nix_2_35 --print-out-paths | grep -v man)
  PLUGIN=$(nix build .#cargo-nix-plugin-nix_2_35 --print-out-paths)

  $NIX/bin/nix build .#myPackage \
    --option plugin-files "$PLUGIN/lib/nix/plugins"
  ```

  The flake emits `nix_<version>`, `cargo-nix-plugin-nix_<version>`, and
  `nix-with-cargo-nix-plugin-nix_<version>` for each matrix entry, plus the
  default `nix`, `nixBootstrap`, and auto-selecting `cargo-nix-nix` outputs.
  For other Nix minors, use the matching pair, e.g. `.#nix_2_34` with
  `.#cargo-nix-plugin-nix_2_34`. The flake's `nixVersions` set (in
  `flake.nix`) lists what is currently built; Nix >= 2.34 is required.

  Patch compatibility is checked in both directions for each minor:
  `patch-abi-test-nix_2_34`/`patch-abi-test-nix_2_35` build a plugin
  against the oldest patch and load it into the current patch binary;
  `patch-host-test-nix_2_34`/`patch-host-test-nix_2_35` load the current
  plugin into a Nix binary built from the oldest patch source. A minor
  mismatch is rejected by `minor-mismatch-test-nix_*`.

- **Platforms**: `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
  Cross-compilation to other target platforms is supported.

- **API level**: `lib/` checks that the loaded plugin speaks the same
  contract version before resolving and warns on mismatch (e.g. when the
  plugin baked into your Nix lags the `lib/` checkout). The wrapper
  result exposes both sides so you can turn that into a hard failure:

  ```nix
  let cargoNix = import ./lib { inherit pkgs; src = ./.; }; in
  assert cargoNix.apiLevel == cargoNix.resolverApiLevel;
  cargoNix.workspaceMembers
  ```

  `apiLevel` is what this `lib/` speaks; `resolverApiLevel` is what the
  loaded plugin reports (0 if the plugin predates the check).

- **buildRustCrate**: Compatible with nixpkgs `buildRustCrate` and
  `defaultCrateOverrides`

## Status

Maintained by Anthropic. Provided AS IS without warranty (see LICENSE).
We triage issues and review pull requests but do not commit to fixing every
bug or accepting every feature request. For security issues, see
`SECURITY.md`.

## License

Apache License 2.0. See [LICENSE](LICENSE).

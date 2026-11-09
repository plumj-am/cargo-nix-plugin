# Copyright 2026 Anthropic, PBC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

{
  description = "Nix plugin for resolving Cargo workspaces — replaces generated Cargo.nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f (import nixpkgs { inherit system; }));

      # Nix versions to build the plugin against and test with.
      # Each entry maps a suffix to { components, binary } attribute paths
      # under pkgs.nixVersions. Track what the locked nixpkgs still ships;
      # nixpkgs aggressively removes EOL nix releases.
      nixVersions = {
        "2_34" = {
          components = "nixComponents_2_34";
          binary = "nix_2_34";
          # Oldest patch in this minor that the plugin is tested against.
          # Loading newer-patch plugins into newer binaries is covered by
          # the regular matrix; this entry covers stale patch builds.
          oldestPatch = {
            tag = "2.34.6";
            hash = "sha256-kHMyhuzhLtH3f+wAcNvAL62ct2kmwZOp2B54SHkMMo0=";
          };
        };
        "2_35" = {
          components = "nixComponents_2_35";
          binary = "nix_2_35";
          oldestPatch = {
            tag = "2.35.0";
            hash = "sha256-EDJDon2Jkp+fg3p4F0L1mx2nh3C9w4F8J+Ddcy9X+J4=";
          };
        };
        # Pre-release: catches plugin ABI breaks before the next stable
        # nix release lands. Expected to break occasionally on nixpkgs bumps.
        "git" = {
          components = "nixComponents_git";
          binary = "git";
        };
      };

      # Build the plugin against a specific nix version's components.
      mkVersionedPlugin =
        pkgs: nixComponents: nixVersion:
        let
          pluginVersion = if nixVersion == null then (nixComponents.version or "unknown") else nixVersion;
        in
        pkgs.callPackage ./nix/plugin.nix {
          inherit nixComponents;
          nixVersion = pluginVersion;
        };

      mkPlugin = pkgs: nixComponents: mkVersionedPlugin pkgs nixComponents null;

      # Build a plugin against an older patch's Nix source while keeping
      # the minor's packaging. This is the ABI check for stale patch
      # builds: the resulting .so is loaded into the current patch binary.
      mkPatchPlugin =
        pkgs: nixComponents: patch:
        let
          source = pkgs.fetchFromGitHub {
            owner = "NixOS";
            repo = "nix";
            inherit (patch) tag hash;
          };
        in
        mkVersionedPlugin pkgs (nixComponents.overrideSource source) patch.tag;

      mkPluginSanitized =
        pkgs: nixComponents:
        (mkPlugin pkgs nixComponents).override {
          stdenv = pkgs.llvmPackages.stdenv;
          llvmPackages = pkgs.llvmPackages;
          enableSanitizers = true;
        };

      # A Nix client with a matching plugin preloaded. Select the plugin
      # by the client's major.minor version and probe it in a child process
      # before using it. A stale patch build may be ABI-compatible; the
      # probe turns a bad load into a clear error instead of a crashed
      # evaluator. `nix = null` uses the `nix` found on PATH.
      mkNixBootstrap =
        pkgs: pluginsByMinor: nix:
        let
          nixBinary = if nix != null then "${nix}/bin/nix" else "nix";
          pluginArms = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              minor: plugin: "${minor}.*) plugin=\"${plugin}/lib/nix/plugins\" ;;"
            ) pluginsByMinor
          );
        in
        pkgs.writeShellApplication {
          name = "nix-with-cargo-nix-plugin";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            set -euo pipefail
            nix_bin=${lib.escapeShellArg nixBinary}
            nix_version_raw=$("$nix_bin" --option plugin-files "" --version)
            nix_version="''${nix_version_raw##* }"
            case "$nix_version" in
              ${pluginArms}
              *)
                echo "cargo-nix-plugin: no plugin for Nix $nix_version" >&2
                echo "supported major.minor versions: ${lib.concatStringsSep ", " (builtins.attrNames pluginsByMinor)}" >&2
                exit 1
                ;;
            esac
            if ! "$nix_bin" \
              --extra-experimental-features "nix-command flakes" \
              --option plugin-files "$plugin" \
              eval --impure --expr 'builtins.cargoNixApiLevel' >/dev/null 2>&1
            then
              echo "cargo-nix-plugin: plugin for Nix $nix_version failed to load" >&2
              exit 1
            fi
            exec "$nix_bin" \
              --extra-experimental-features "nix-command flakes" \
              --option plugin-files "$plugin" "$@"
          '';
        };

      # Generate test derivations for a given nix version.
      mkTests =
        pkgs: plugin: nix:
        {
          eval-test = pkgs.callPackage ./nix/eval-test.nix {
            inherit plugin nix;
            testFixtures = ./rust/tests/fixtures;
          };

          error-path-test = pkgs.callPackage ./tests/error-path-test.nix {
            inherit plugin nix;
            testFixtures = ./rust/tests/fixtures;
          };

          torture-test = pkgs.callPackage ./tests/torture-test.nix {
            inherit plugin nix;
            testFixtures = ./rust/tests/fixtures;
            pluginSrc = ./.;
          };

          sample-build-test = pkgs.callPackage ./tests/sample-build-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            sampleProject = ./tests/sample-project;
          };

          offline-build-test = pkgs.callPackage ./tests/offline-build-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            sampleProject = ./tests/sample-project;
          };

          remote-sparse-test = pkgs.callPackage ./tests/remote-sparse-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            sampleProject = ./tests/sample-project;
          };

          mirror-test = pkgs.callPackage ./tests/mirror-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            sampleProject = ./tests/sample-project;
          };

          retry-test = pkgs.callPackage ./tests/retry-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            sampleProject = ./tests/sample-project;
          };

          git-source-test = pkgs.callPackage ./tests/git-source-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
          };

        }
        # `nix build --store local?root=…` needs the bind-mount-based
        # chroot store, which only exists on Linux.
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nextest-run-test = pkgs.callPackage ./tests/nextest-run-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            # nodeps variant: the test workspace resolves without
            # registry access inside the sandbox.
            sampleProject = ./tests/sample-project-nodeps;
          };

          doctest-run-test = pkgs.callPackage ./tests/doctest-run-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            # nodeps variant: doctests compile in the sandbox without
            # registry access.
            sampleProject = ./tests/sample-project-nodeps;
          };

          chroot-store-test = pkgs.callPackage ./tests/chroot-store-test.nix {
            inherit plugin nix;
            pluginSrc = ./.;
            # nodeps variant: cargo metadata inside the sandbox can't reach
            # crates.io, and the remap logic under test doesn't need it to.
            sampleProject = ./tests/sample-project-nodeps;
          };
        };

      # Build plugins keyed by major.minor. Used by the auto-selecting
      # bootstrap wrapper so consumers don't pick a plugin by hand.
      pluginsByMinorFor =
        pkgs:
        lib.listToAttrs (
          map (
            ver:
            let
              cfg = nixVersions.${ver};
              nix = pkgs.nixVersions.${cfg.binary};
              components = pkgs.nixVersions.${cfg.components};
            in
            {
              name = lib.versions.majorMinor nix.version;
              value = mkPlugin pkgs components;
            }
          ) (builtins.filter (ver: ver != "git") (builtins.attrNames nixVersions))
        );

      # Build packages/tests for every nix version, suffixed with the version.
      # e.g. eval-test-nix_2_34, torture-test-nix_2_34, etc.
      perVersionPackages =
        pkgs:
        builtins.foldl' (
          acc: ver:
          let
            cfg = nixVersions.${ver};
            components = pkgs.nixVersions.${cfg.components};
            nix = pkgs.nixVersions.${cfg.binary};
            plugin = mkPlugin pkgs components;
            bootstrap = mkNixBootstrap pkgs {
              ${lib.versions.majorMinor nix.version} = plugin;
            } nix;
            tests = mkTests pkgs plugin nix;
            patchPlugin = if cfg ? oldestPatch then mkPatchPlugin pkgs components cfg.oldestPatch else null;
            # The UBSan build statically links compiler-rt's minimal
            # runtime via GNU-ld --whole-archive from lib/linux/; no
            # darwin equivalent is wired up, so keep it Linux-only.
            sanitizedTests = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
              mkTests pkgs (mkPluginSanitized pkgs components) nix
            );
          in
          acc
          // {
            "cargo-nix-plugin-nix_${ver}" = plugin;
            "nix_${ver}" = nix;
            "nix-with-cargo-nix-plugin-nix_${ver}" = bootstrap;
          }
          // nixpkgs.lib.optionalAttrs (patchPlugin != null) {
            "cargo-nix-plugin-${cfg.oldestPatch.tag}" = patchPlugin;
          }
          // nixpkgs.lib.mapAttrs' (name: drv: nixpkgs.lib.nameValuePair "${name}-nix_${ver}" drv) tests
          // nixpkgs.lib.mapAttrs' (
            name: drv: nixpkgs.lib.nameValuePair "${name}-ubsan-nix_${ver}" drv
          ) sanitizedTests
        ) { } (builtins.attrNames nixVersions);

      # The default nix version used for the top-level plugin package.
      # Keep README.md (## Example, ## Compatibility) in sync when bumping.
      defaultNixComponents = "nixComponents_2_35";
      defaultNixBinary = builtins.replaceStrings [ "nixComponents_" ] [ "nix_" ] defaultNixComponents;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          defaultPlugin = mkPlugin pkgs pkgs.nixVersions.${defaultNixComponents};
          defaultNix = pkgs.nixVersions.${defaultNixBinary};
          defaultPluginsByMinor = {
            ${lib.versions.majorMinor defaultNix.version} = defaultPlugin;
          };
          defaultBootstrap = mkNixBootstrap pkgs defaultPluginsByMinor defaultNix;
          autoBootstrap = mkNixBootstrap pkgs (pluginsByMinorFor pkgs) null;
        in
        {
          default = defaultPlugin;
          cargo-nix-plugin = defaultPlugin;
          nix = defaultNix;
          nixBootstrap = defaultBootstrap;
          # Auto-selects a plugin for the `nix` found on PATH and probes it
          # before use. This is the consumer-facing wrapper.
          cargo-nix-nix = autoBootstrap;
          cargo-nix-prefetch = pkgs.callPackage ./nix/cargo-nix-prefetch.nix { };
          # Optional: helper for generating metadata JSON explicitly.
          # Only needed for explicit-metadata mode (`metadata` + `cargoLock`).
          # The default `src`-only path resolves from Cargo.lock directly.
          # Useful for offline/pure evaluation workflows.
          generate-metadata = pkgs.writeShellApplication {
            name = "generate-metadata";
            runtimeInputs = [ pkgs.cargo ];
            text = ''
              exec cargo metadata --format-version 1 --locked "$@"
            '';
          };
          # Exercises cargo-nix-prefetch (the standalone binary), not the
          # nix plugin, so it isn't per-nix-version.
          cargo-compat-test = pkgs.callPackage ./tests/cargo-compat-test.nix { };
          build-rust-crate-bin = pkgs.callPackage ./nix/build-rust-crate-bin.nix { };
        }
        // perVersionPackages pkgs
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.rust-analyzer
            pkgs.clippy
            pkgs.rustfmt
            pkgs.cargo-nextest
            pkgs.cmake
            pkgs.pkg-config
            pkgs.boost
            pkgs.nlohmann_json
            pkgs.nixVersions.nix_2_35
            pkgs.nixfmt-rfc-style
          ];
          shellHook = ''
            echo "cargo-nix-plugin devshell: nix build .#cargo-nix-plugin"
            echo "Run nix flake check for the full matrix."
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        cargo-nix-prefetch = {
          type = "app";
          program = "${
            self.packages.${pkgs.stdenv.hostPlatform.system}.cargo-nix-prefetch
          }/bin/cargo-nix-prefetch";
        };
        generate-metadata = {
          type = "app";
          program = "${
            self.packages.${pkgs.stdenv.hostPlatform.system}.generate-metadata
          }/bin/generate-metadata";
        };
        nixBootstrap = {
          type = "app";
          program = "${
            self.packages.${pkgs.stdenv.hostPlatform.system}.nixBootstrap
          }/bin/nix-with-cargo-nix-plugin";
        };
        cargo-nix-nix = {
          type = "app";
          program = "${
            self.packages.${pkgs.stdenv.hostPlatform.system}.cargo-nix-nix
          }/bin/nix-with-cargo-nix-plugin";
        };
      });

      # Checks run against every nix version in the matrix, on every
      # supported system. Linux gets the UBSan variants on top via
      # perVersionPackages; recursive-nix tests are gated by
      # requiredSystemFeatures so a darwin builder without that feature
      # simply won't be assigned them.
      checks = forAllSystems (
        pkgs:
        builtins.foldl' (
          acc: ver:
          let
            cfg = nixVersions.${ver};
            components = pkgs.nixVersions.${cfg.components};
            nix = pkgs.nixVersions.${cfg.binary};
            plugin = mkPlugin pkgs components;
            tests = mkTests pkgs plugin nix;
            patchPlugin = if cfg ? oldestPatch then mkPatchPlugin pkgs components cfg.oldestPatch else null;
            minorMismatchPlugin = mkVersionedPlugin pkgs components "2.999.0";
            sanitizedTests = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
              mkTests pkgs (mkPluginSanitized pkgs components) nix
            );
          in
          acc
          // nixpkgs.lib.mapAttrs' (name: drv: nixpkgs.lib.nameValuePair "${name}-nix_${ver}" drv) tests
          // nixpkgs.lib.optionalAttrs (patchPlugin != null) {
            "patch-abi-test-nix_${ver}" = pkgs.callPackage ./tests/patch-abi-test.nix {
              plugin = patchPlugin;
              inherit nix;
              pluginSrc = ./.;
              testFixtures = ./rust/tests/fixtures;
              expectedVersion = cfg.oldestPatch.tag;
            };
          }
          // {
            "minor-mismatch-test-nix_${ver}" = pkgs.callPackage ./tests/minor-mismatch-test.nix {
              plugin = minorMismatchPlugin;
              inherit nix;
              pluginSrc = ./.;
              testFixtures = ./rust/tests/fixtures;
            };
          }
          // nixpkgs.lib.mapAttrs' (
            name: drv: nixpkgs.lib.nameValuePair "${name}-ubsan-nix_${ver}" drv
          ) sanitizedTests
        ) { } (builtins.attrNames nixVersions)
        // {
          cargo-compat-test = pkgs.callPackage ./tests/cargo-compat-test.nix { };
          auto-bootstrap-test = pkgs.runCommand "cargo-nix-plugin-auto-bootstrap-test" { } ''
            export HOME=$(mktemp -d)
            export NIX_STORE_DIR=$TMPDIR/nix/store
            export NIX_STATE_DIR=$TMPDIR/nix/var
            export NIX_LOG_DIR=$TMPDIR/nix/log
            mkdir -p $NIX_STORE_DIR $NIX_STATE_DIR $NIX_LOG_DIR

            wrapper=${
              self.packages.${pkgs.stdenv.hostPlatform.system}.cargo-nix-nix
            }/bin/nix-with-cargo-nix-plugin
            for nix_bin in ${pkgs.nixVersions.nix_2_34}/bin ${pkgs.nixVersions.nix_2_35}/bin; do
              PATH="$nix_bin:$PATH" "$wrapper" --version >/dev/null
              api=$(PATH="$nix_bin:$PATH" "$wrapper" eval --impure --raw \
                --expr 'toString (builtins.cargoNixApiLevel or 0)')
              test "$api" = 4
            done
            touch $out
          '';
          bootstrap-test = pkgs.runCommand "cargo-nix-plugin-bootstrap-test" { } ''
            export HOME=$(mktemp -d)
            export NIX_STORE_DIR=$TMPDIR/nix/store
            export NIX_STATE_DIR=$TMPDIR/nix/var
            export NIX_LOG_DIR=$TMPDIR/nix/log
            mkdir -p $NIX_STORE_DIR $NIX_STATE_DIR $NIX_LOG_DIR

            bootstrap=${
              self.packages.${pkgs.stdenv.hostPlatform.system}.nixBootstrap
            }/bin/nix-with-cargo-nix-plugin
            expected=${self.packages.${pkgs.stdenv.hostPlatform.system}.nix.version}
            version=$($bootstrap --version)
            case "$version" in
              *"$expected"*) ;;
              *)
                echo "unexpected Nix version from bootstrap: $version (want $expected)" >&2
                exit 1
                ;;
            esac
            api=$($bootstrap eval --impure --raw --expr 'toString (builtins.cargoNixApiLevel or 0)')
            test "$api" = 4
            touch $out
          '';
        }
      );

      lib = import ./lib;

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.cargo-nix-plugin;
        in
        {
          options.cargo-nix-plugin = {
            enable = lib.mkEnableOption "cargo-nix-plugin primop";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.cargo-nix-plugin;
              description = "Plugin build; must match the Nix evaluating builds.";
            };
            nixPackage = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.nix;
              description = "Nix client that the default plugin was built against.";
            };
          };

          config = lib.mkIf cfg.enable {
            # Keep the host Nix and the plugin's nixComponents in the same
            # minor. Use the flake's locked nixpkgs, not the consumer's,
            # so the default pair has a tested patch release.
            nix.package = lib.mkDefault cfg.nixPackage;
            nix.settings.plugin-files = lib.mkAfter [
              "${cfg.package}/lib/nix/plugins"
            ];
          };
        };
    };
}

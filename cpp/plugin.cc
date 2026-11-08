// Copyright 2026 Anthropic, PBC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <nix/expr/eval.hh>
#include <nix/expr/primops.hh>
#include <nix/expr/value.hh>
#include <nix/expr/json-to-value.hh>
#include <nix/expr/value-to-json.hh>
#include <nix/store/local-fs-store.hh>
#include <nlohmann/json.hpp>
#include <sstream>

#ifndef NIX_COMPILE_VERSION
#define NIX_COMPILE_VERSION "unknown"
#endif

// Rust FFI declarations
extern "C" {
    int resolve_cargo_workspace(
        const char *input_json,
        const char *store_remap_json,
        char **out,
        char **err_out
    );
    void free_string(char *s);
    unsigned cargo_nix_api_level(void);
}

using namespace nix;

static void resolveCargoWorkspaceImpl(EvalState &state, PosIdx pos,
                                       Value *const *args, Value &v) {
    state.forceAttrs(*args[0], pos,
        "while evaluating the argument to builtins.resolveCargoWorkspace");

    // Serialize the input attrset directly to a stream. Path remapping for
    // chroot stores happens in Rust, so the whole JSON tree is not built
    // and re-dumped here.
    NixStringContext context;
    std::ostringstream inputStream;
    printValueAsJSON(state, true, *args[0], pos, inputStream, context, false);

    // Under a chroot store (`--store local?root=/tmp/foo`) the logical
    // /nix/store/... paths don't exist on disk. Hand Rust the mapping and
    // let it rewrite the path fields after deserialization.
    std::string storeRemapJson = "null";
    if (auto *localFS = dynamic_cast<LocalFSStore *>(state.store.operator->())) {
        auto realStoreDir = localFS->getRealStoreDir();
        auto logicalStoreDir = state.store->storeDir;
        if (realStoreDir != logicalStoreDir) {
            nlohmann::json remap;
            remap["from"] = logicalStoreDir;
            remap["to"] = realStoreDir;
            storeRemapJson = remap.dump();
        }
    }

    std::string inputStr = inputStream.str();

    char *resultJson = nullptr;
    char *errorMsg = nullptr;

    int rc = resolve_cargo_workspace(
        inputStr.c_str(), storeRemapJson.c_str(), &resultJson, &errorMsg);

    if (rc != 0) {
        std::string err = errorMsg ? errorMsg : "unknown error";
        if (errorMsg) free_string(errorMsg);
        state.error<EvalError>("resolveCargoWorkspace: %s", err).atPos(pos).debugThrow();
    }

    // Parse the result JSON into a Nix value
    std::string result(resultJson);
    free_string(resultJson);

    parseJSON(state, result, v);
}

static void cargoNixApiLevelImpl(Value &v) {
    v.mkInt(cargo_nix_api_level());
}

static void cargoNixNixVersionImpl(EvalState &state, Value &v) {
    v.mkString(NIX_COMPILE_VERSION, state.mem);
}

#ifdef NIX_PRIMOP_CALLSITE
static void prim_resolveCargoWorkspace(EvalState &state, CallSite callSite,
                                        Value *const *args, Value &v) {
    resolveCargoWorkspaceImpl(state, callSite.pos, args, v);
}

static void prim_cargoNixApiLevel(EvalState &, CallSite, Value *const *, Value &v) {
    cargoNixApiLevelImpl(v);
}

static void prim_cargoNixNixVersion(EvalState &state, CallSite, Value *const *, Value &v) {
    cargoNixNixVersionImpl(state, v);
}
#else
static void prim_resolveCargoWorkspace(EvalState &state, PosIdx pos,
                                        Value **args, Value &v) {
    resolveCargoWorkspaceImpl(state, pos, args, v);
}

static void prim_cargoNixApiLevel(EvalState &, PosIdx, Value **, Value &v) {
    cargoNixApiLevelImpl(v);
}

static void prim_cargoNixNixVersion(EvalState &state, PosIdx, Value **, Value &v) {
    cargoNixNixVersionImpl(state, v);
}
#endif

// Nix >=2.34 names the implementation field PrimOp::impl.
static RegisterPrimOp rp(PrimOp {
    .name = "resolveCargoWorkspace",
    .args = {"attrs"},
    .arity = 1,
    .doc = R"(
      Resolve a Cargo workspace into a crate metadata attrset compatible with buildRustCrate.

      Accepts an attrset with:
      - `metadata`: JSON string from `cargo metadata --format-version 1 --locked`
      - `cargoLock`: Contents of `Cargo.lock`
      - `target`: Attrset describing the target platform
      - `rootFeatures` (optional): List of features to enable (defaults to `["default"]`)
    )",
    .impl = prim_resolveCargoWorkspace,
});

// Internal probe so lib/ can detect a skewed .so before calling
// resolveCargoWorkspace. Not user API; see cargoNix.{apiLevel,
// resolverApiLevel}.
static RegisterPrimOp rpApiLevel(PrimOp {
    .name = "__cargoNixApiLevel",
    .args = {},
    .arity = 0,
    .doc = "Internal: contract version of the loaded cargo-nix-plugin resolver.",
    .impl = prim_cargoNixApiLevel,
});

// Internal probe so lib/ can reject a plugin built for another Nix version.
static RegisterPrimOp rpNixVersion(PrimOp {
    .name = "__cargoNixNixVersion",
    .args = {},
    .arity = 0,
    .doc = "Internal: Nix version the loaded cargo-nix-plugin was compiled against.",
    .impl = prim_cargoNixNixVersion,
});

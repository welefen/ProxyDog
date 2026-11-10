#!/usr/bin/env bash
# Shared build environment for ProxyDog.
# SPM is wrapped because the harness sandbox forbids writes to the default
# ~/Library caches and nests sandbox-exec, so we keep every cache inside the repo
# and pass --disable-sandbox.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

mkdir -p "$ROOT/.build-tmp" "$ROOT/.build-cache/clang" "$ROOT/.build-config"
export TMPDIR="$ROOT/.build-tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build-cache/clang"

SWIFT_BIN="$(xcrun --find swift 2>/dev/null || command -v swift)"
SWIFTC_BIN="$(xcrun --find swiftc 2>/dev/null || command -v swiftc)"
PD_SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
export SWIFTC_BIN PD_SDK
export SWIFT_BIN

export PD_FLAGS=(--disable-sandbox --cache-path "$ROOT/.build-cache/spm" --config-path "$ROOT/.build-config")

# Build the package (debug by default). Extra args are forwarded to swift build.
pd_build() {
  (cd "$ROOT" && "$SWIFT_BIN" build "${PD_FLAGS[@]}" "$@")
}

# Run `swift <subcommand>` with our flags appended, from the repo root.
pd_swift() {
  local sub="$1"; shift
  (cd "$ROOT" && "$SWIFT_BIN" "$sub" "${PD_FLAGS[@]}" "$@")
}

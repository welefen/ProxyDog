#!/usr/bin/env bash
# Regenerate Support/AppIcon.icns from scripts/make_icon.swift
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

ICONSET="$ROOT/.build-cache/AppIcon.iconset"
rm -rf "$ICONSET"
"$SWIFTC_BIN" -sdk "$PD_SDK" -O "$ROOT/scripts/make_icon.swift" -o "$ROOT/.build-cache/make-icon"
"$ROOT/.build-cache/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Support/AppIcon.icns"
echo "Wrote $ROOT/Support/AppIcon.icns"

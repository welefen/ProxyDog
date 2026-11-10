#!/usr/bin/env bash
# Capture a screenshot of the ProxyDog window (light mode) for the README.
# Usage: ./scripts/screenshot.sh [output.png] [app-name]
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

OUT="${1:-/tmp/proxydog-window.png}"
APP_NAME="${2:-ProxyDog}"
HELPER="$ROOT/.build-cache/window-id"

if [ ! -x "$HELPER" ] || [ "$ROOT/scripts/window-id.swift" -nt "$HELPER" ]; then
  "$SWIFTC_BIN" -sdk "$PD_SDK" -O "$ROOT/scripts/window-id.swift" -o "$HELPER"
fi

WINDOW_ID=""
for _ in $(seq 1 20); do
  WINDOW_ID="$("$HELPER" "$APP_NAME" 2>/dev/null || true)"
  if [ -n "$WINDOW_ID" ]; then break; fi
  sleep 0.4
done

if [ -z "$WINDOW_ID" ]; then
  echo "No window found for $APP_NAME" >&2
  exit 1
fi

screencapture -x -o -l "$WINDOW_ID" "$OUT"
echo "$OUT"

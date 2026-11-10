#!/usr/bin/env bash
# Rebuild the app bundle and launch it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build_app.sh" >/dev/null
pkill -f "ProxyDog.app/Contents/MacOS/ProxyDog" 2>/dev/null || true
sleep 0.3
open "$(cd "$SCRIPT_DIR/.." && pwd)/build/ProxyDog.app" --args "$@"
echo "Launched ProxyDog.app"

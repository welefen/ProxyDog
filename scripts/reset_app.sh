#!/usr/bin/env bash
# Stop ProxyDog and forget its preferences (so onboarding shows again).
set -uo pipefail
pkill -f "ProxyDog.app/Contents/MacOS/ProxyDog" 2>/dev/null || true
sleep 0.5
defaults delete com.proxydog.app 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/ProxyDog" 2>/dev/null || true
echo "ProxyDog state reset"

#!/usr/bin/env bash
# Build ProxyDog.app (release) into build/ProxyDog.app
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

cd "$ROOT"
"$SWIFT_BIN" build "${PD_FLAGS[@]}" -c release --product ProxyDog

APP="$ROOT/build/ProxyDog.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/ProxyDog" "$APP/Contents/MacOS/ProxyDog"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# Merge Localizable.strings fragments per language into the bundle.
LOCSRC="$ROOT/Resources/Localization"
if [ -d "$LOCSRC" ]; then
  for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    MERGED="$APP/Contents/Resources/$lang.lproj/Localizable.strings"
    cat "$LOCSRC"/*."$lang".strings > "$MERGED" 2>/dev/null || true
    if [ -s "$MERGED" ]; then
      plutil -lint "$MERGED" >/dev/null || echo "warning: invalid strings file $MERGED"
    fi
  done
fi

if [ -f "$ROOT/Support/AppIcon.icns" ]; then
  cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

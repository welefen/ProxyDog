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
# Inject build-time configuration (Aptabase app key) into the bundle Info.plist.
# The key lives in Support/AppConfig.plist, which is gitignored: it is supplied by
# whoever builds the app, not asked from end users at runtime.
CONFIG_PLIST="$ROOT/Support/AppConfig.plist"
if [ ! -f "$CONFIG_PLIST" ]; then
  cp "$ROOT/Support/AppConfig.plist.example" "$CONFIG_PLIST"
  echo "note: created Support/AppConfig.plist from the template — analytics stays disabled until you fill in the Aptabase App Key."
fi
APP_KEY="$(/usr/libexec/PlistBuddy -c "Print :AptabaseAppKey" "$CONFIG_PLIST" 2>/dev/null || true)"
/usr/libexec/PlistBuddy -c "Delete :ProxyDogAptabaseAppKey" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
if [ -n "$APP_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProxyDogAptabaseAppKey string $APP_KEY" "$APP/Contents/Info.plist"
  echo "Aptabase analytics: enabled"
else
  echo "Aptabase analytics: disabled (no key in Support/AppConfig.plist)"
fi

/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

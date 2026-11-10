#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DIST="$ROOT/dist"

./scripts/build_app.sh

rm -rf "$DIST"
mkdir -p "$DIST/stage"
ditto "$ROOT/build/ProxyDog.app" "$DIST/stage/ProxyDog.app"
ln -sfn /Applications "$DIST/stage/Applications"

echo "▸ Creating DMG"
if hdiutil create \
  -volname "ProxyDog" \
  -srcfolder "$DIST/stage" \
  -ov -format UDZO \
  "$DIST/ProxyDog-$VERSION.dmg" >/dev/null 2>&1; then
  echo "  DMG ready"
else
  rm -f "$DIST/ProxyDog-$VERSION.dmg"
  echo "  DMG creation unavailable in this environment; ZIP only."
fi

echo "▸ Creating ZIP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$ROOT/build/ProxyDog.app" "$DIST/ProxyDog-$VERSION.zip"

echo "▸ Checksums"
rm -f "$DIST/SHA256SUMS.txt"
(
  cd "$DIST"
  for file in ProxyDog-"$VERSION".dmg ProxyDog-"$VERSION".zip; do
    [[ -f "$file" ]] && shasum -a 256 "$file"
  done | tee "$DIST/SHA256SUMS.txt"
)
echo "▸ Done: $DIST/ProxyDog-$VERSION.zip"

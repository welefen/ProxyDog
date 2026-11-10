#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
./scripts/package.sh

mkdir -p updates
ZIP="updates/ProxyDog-$VERSION.zip"
DMG="updates/ProxyDog-$VERSION.dmg"
cp "dist/ProxyDog-$VERSION.zip" "$ZIP"
if [[ -f "dist/ProxyDog-$VERSION.dmg" ]]; then
  cp "dist/ProxyDog-$VERSION.dmg" "$DMG"
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
cat > updates/latest.json <<JSON
{
  "version": "$VERSION",
  "downloadURL": "https://raw.githubusercontent.com/welefen/ProxyDog/master/$ZIP",
  "sha256": "$SHA",
  "releaseNotes": "ProxyDog $VERSION"
}
JSON

echo "▸ Published update manifest"
echo "  version: $VERSION"
echo "  sha256:  $SHA"
echo "  file:    $ZIP"
echo
echo "Next:"
echo "  git add updates scripts && git commit -m 'release: ProxyDog $VERSION' && git push origin master"
echo "The GitHub repository must be public for the in-app updater to download the archive."

if [[ "${1:-}" == "--push" ]]; then
  git add updates scripts
  if ! git diff --cached --quiet; then
    git commit -m "release: ProxyDog $VERSION"
  fi
  git push origin master
  git tag -f "v$VERSION"
  git push origin "v$VERSION"
fi

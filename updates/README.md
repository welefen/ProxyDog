# Update feed

`latest.json` is read by the in-app updater (ProxyDog → menu **Check for Updates…** or
Settings → Appearance → Updates). The manifest format is:

```json
{
  "version": "1.0.1",
  "downloadURL": "https://raw.githubusercontent.com/welefen/ProxyDog/master/updates/ProxyDog-1.0.1.zip",
  "sha256": "<sha256 of the zip>",
  "releaseNotes": "ProxyDog 1.0.1"
}
```

The updater downloads the ZIP, verifies the SHA-256, checks the bundle identifier and
version, stages `ProxyDog.app`, then swaps it after the app quits and relaunches.

## Publishing a release

1. Bump `CFBundleShortVersionString` in `Support/Info.plist`.
2. Run `./scripts/publish_update.sh` (builds the app, writes the ZIP and `latest.json`).
3. Commit `updates/` and push to `master`, or pass `--push` to the script to commit and tag.

The repository must be public (or provide `PROXYDOG_UPDATE_TOKEN`) so the app can fetch
the manifest and archive over HTTPS.

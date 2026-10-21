#!/bin/zsh
# Packages build/My AI Teacher.app into a drag-to-install disk image: build/My-AI-Teacher-<version>.dmg
#   scripts/build-app.sh && scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/My AI Teacher.app"
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo "1.0.0")
DMG="$ROOT/build/My-AI-Teacher-$VERSION.dmg"
[[ -d "$APP" ]] || { echo "build the app first: scripts/build-app.sh"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/My AI Teacher.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $DMG…"
rm -f "$DMG"
hdiutil create -volname "My AI Teacher" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG" 2>/dev/null || true
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) sha256 $(shasum -a 256 "$DMG" | cut -c1-16)…"

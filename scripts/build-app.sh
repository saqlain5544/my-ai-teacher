#!/bin/zsh
# Builds an optimised, ad-hoc signed "My AI Teacher.app" into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
CONFIG=${1:-release}
APP="$ROOT/build/My AI Teacher.app"

echo "▸ Compiling ($CONFIG)…"
# A failed compile must stop here: the binary from the previous build would otherwise be packaged as if it were new.
LOG=$(mktemp)
if ! swift build -c "$CONFIG" --arch arm64 >"$LOG" 2>&1; then
  grep -E "error" "$LOG" | head -20; rm -f "$LOG"; echo "✗ build failed"; exit 1
fi
grep -E "warning: unre|Build complete" "$LOG" || true; rm -f "$LOG"
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/MyAITeacher"
[[ -x "$BIN" ]] || { echo "✗ build failed"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyAITeacher"
rsync -a --delete "$ROOT/Resources/web/" "$APP/Contents/Resources/web/"
rsync -a --delete "$ROOT/Resources/skills/" "$APP/Contents/Resources/skills/"

ICONSET="$ROOT/build/AppIcon.iconset"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
  echo "▸ Rendering icon…"
  rm -rf "$ICONSET"; swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo "1.0.0")
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>My AI Teacher</string>
  <key>CFBundleDisplayName</key><string>My AI Teacher</string>
  <key>CFBundleIdentifier</key><string>com.saqlain.myaiteacher</string>
  <key>CFBundleExecutable</key><string>MyAITeacher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Dictate questions to your teacher.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Convert your speech to text so you can talk to your teacher.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --options runtime --entitlements "$ROOT/scripts/entitlements.plist" "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"
echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

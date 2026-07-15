#!/bin/bash
# Build Hermes_Pairing.app — native Swift menu bar + Python control window
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Hermes_Pairing"
APP="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VENV="$ROOT/venv"
SRC_PY="$ROOT/src/hermes_pairing.py"
SRC_SWIFT="$ROOT/src/MenuBarApp.swift"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Missing venv. Run: python3 -m venv venv && venv/bin/pip install 'pyobjc-core==10.3.2' 'pyobjc-framework-Cocoa==10.3.2'"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Compile native menu bar binary (this is what actually shows in the menu bar)
swiftc -O -o "$MACOS/$APP_NAME" "$SRC_SWIFT" \
  -framework AppKit -framework Foundation \
  -target arm64-apple-macosx13.0

cp "$ROOT/resources/menubar-template.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/menubar-template@2x.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon.icns" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon-1024.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/pair-illustration.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-blue.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-orange.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-black.png" "$RES/" 2>/dev/null || true
cp "$SRC_PY" "$RES/hermes_pairing.py"
chmod 644 "$RES/hermes_pairing.py"

echo "$ROOT" > "$RES/project_root"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Hermes_Pairing</string>
  <key>CFBundleDisplayName</key>
  <string>Hermes_Pairing</string>
  <key>CFBundleIdentifier</key>
  <string>com.kulpio.hermes-pairing</string>
  <key>CFBundleVersion</key>
  <string>1.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>Hermes_Pairing</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Hermes_Pairing controls Terminal to pair Hermes and Claude Code sessions.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$CONTENTS/PkgInfo"

codesign -s - --force --deep "$APP" 2>/dev/null || true

echo "Built: $APP"
file "$MACOS/$APP_NAME"

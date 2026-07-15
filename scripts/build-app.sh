#!/bin/bash
# Build Hermes Pong.app — native Swift menu bar + nested Panel.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HermesPong"
DISPLAY_NAME="Hermes Pong"
APP="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VENV="$ROOT/venv"
SRC_PY="$ROOT/src/hermes_pairing.py"
SRC_SWIFT="$ROOT/src/MenuBarApp.swift"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Missing venv. Run: bash scripts/setup.sh"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

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
cp "$ROOT/resources/logo-monochrome.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-mono-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-dim.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-bright.png" "$RES/" 2>/dev/null || true
cp "$SRC_PY" "$RES/hermes_pairing.py"
chmod 644 "$RES/hermes_pairing.py"
echo "$ROOT" > "$RES/project_root"

# Nested Panel.app (accessory — no second Dock icon)
PANEL="$RES/Panel.app"
PANEL_CONTENTS="$PANEL/Contents"
PANEL_MACOS="$PANEL_CONTENTS/MacOS"
PANEL_RES="$PANEL_CONTENTS/Resources"
mkdir -p "$PANEL_MACOS" "$PANEL_RES"
cp "$RES/hermes_pairing.py" "$PANEL_RES/"
cp "$RES/AppIcon.icns" "$PANEL_RES/" 2>/dev/null || true
cp "$RES/AppIcon-1024.png" "$PANEL_RES/" 2>/dev/null || true
cp "$RES/pair-illustration.png" "$PANEL_RES/" 2>/dev/null || true
cp "$RES/project_root" "$PANEL_RES/"

cat > "$PANEL_MACOS/Panel" <<'LAUNCH'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$(cd "$DIR/.." && pwd)"
RES="$CONTENTS/Resources"
ROOT="$(cat "$RES/project_root" 2>/dev/null || true)"
PY="$ROOT/venv/bin/python"
if [[ ! -x "$PY" ]]; then PY="/usr/bin/python3"; fi
export PYTHONUNBUFFERED=1
exec -a "Hermes Pong" "$PY" "$RES/hermes_pairing.py" --window-only
LAUNCH
chmod +x "$PANEL_MACOS/Panel"

cat > "$PANEL_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Hermes Pong</string>
  <key>CFBundleDisplayName</key>
  <string>Hermes Pong</string>
  <key>CFBundleIdentifier</key>
  <string>com.kulpio.hermes-pong.panel</string>
  <key>CFBundleVersion</key>
  <string>1.3.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>Panel</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Hermes Pong controls Terminal windows.</string>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$PANEL_CONTENTS/PkgInfo"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Hermes Pong</string>
  <key>CFBundleDisplayName</key>
  <string>Hermes Pong</string>
  <key>CFBundleIdentifier</key>
  <string>com.kulpio.hermes-pong</string>
  <key>CFBundleVersion</key>
  <string>1.3.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>HermesPong</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Hermes Pong controls Terminal to pair Hermes and Claude Code sessions.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$CONTENTS/PkgInfo"
codesign -s - --force --deep "$APP" 2>/dev/null || true

echo "Built: $APP"
file "$MACOS/$APP_NAME"

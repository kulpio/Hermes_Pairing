#!/bin/bash
# Build Hermes Pong.app — native Swift menu bar + control panel (no Python runtime)
# Usage: build-app.sh [--dev]
#   --dev  embed project_root (points the Panel at this checkout's venv).
#          Never use for release builds — it bakes in your local path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HermesPong"
DISPLAY_NAME="Hermes Pong"
APP="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VERSION="1.3.1"

DEV=0
[[ "${1:-}" == "--dev" ]] && DEV=1

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Universal binary: compile per-arch, lipo together. Relative source path so
# no absolute build path lands in the Mach-O.
cd "$ROOT"
swiftc -O -o "$MACOS/$APP_NAME-arm64" "src/MenuBarApp.swift" \
  -framework AppKit -framework Foundation \
  -target arm64-apple-macosx13.0
swiftc -O -o "$MACOS/$APP_NAME-x86_64" "src/MenuBarApp.swift" \
  -framework AppKit -framework Foundation \
  -target x86_64-apple-macosx13.0
lipo -create -output "$MACOS/$APP_NAME" "$MACOS/$APP_NAME-arm64" "$MACOS/$APP_NAME-x86_64"
rm -f "$MACOS/$APP_NAME-arm64" "$MACOS/$APP_NAME-x86_64"
lipo -info "$MACOS/$APP_NAME"

cp "$ROOT/resources/menubar-template.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/menubar-template@2x.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon.icns" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/AppIcon-1024.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/pair-illustration.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-blue.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-orange.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-black.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-monochrome.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-mono-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/logo-accent-128.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-dim.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-bright.png" "$RES/" 2>/dev/null || true
# Bridge CLIs bundled so the app works without relying only on ~/bin.
# (Stdlib-only Python — used by the Hermes side and the window relay.)
for f in claude-delegate.py pong-delegate.py claude-window-relay.py pong-ledger.py hermes_pong.py; do
  if [[ -f "$ROOT/scripts/$f" ]]; then
    cp "$ROOT/scripts/$f" "$RES/$f"
    chmod 755 "$RES/$f"
  fi
done
# project_root embeds an absolute local path — dev builds only.
if [[ "$DEV" == "1" ]]; then
  echo "$ROOT" > "$RES/project_root"
fi

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
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
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

# Ad-hoc sign for dev, no --deep (release signing is separate).
codesign -s - --force "$APP" 2>/dev/null || true
echo "hint: ad-hoc signed (dev). Release builds: bash scripts/sign-notarize.sh"

# Release bundles must not leak the local user path.
if [[ "$DEV" != "1" ]]; then
  if grep -r "dylandemnard" "$APP" >/dev/null 2>&1; then
    echo "FAIL: release bundle contains local user path strings:" >&2
    grep -rl "dylandemnard" "$APP" >&2
    exit 1
  fi
fi

echo "Built: $APP (v$VERSION, $([[ "$DEV" == "1" ]] && echo dev || echo release) build)"
file "$MACOS/$APP_NAME"

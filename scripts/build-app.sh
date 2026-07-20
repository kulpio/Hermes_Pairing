#!/bin/bash
# Build Pong.app (Agent-Pong) — native Swift menu bar + control panel
# Usage: build-app.sh [--dev]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pong"
# Public display name (bundle UI); executable stays Pong for path/compat.
DISPLAY_NAME="CyberPong"
APP="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VERSION="2.0.0-alpha"

DEV=0
[[ "${1:-}" == "--dev" ]] && DEV=1

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Universal binary: compile per-arch, lipo together. Relative source path so
# no absolute build path lands in the Mach-O.
cd "$ROOT"
# Compile all Swift sources in src/ (panel split out for maintainability)
SWIFT_SRCS=(src/*.swift)
swiftc -O -o "$MACOS/$APP_NAME-arm64" "${SWIFT_SRCS[@]}" \
  -framework AppKit -framework Foundation -framework SceneKit -framework QuartzCore -framework Metal -framework MetalKit \
  -target arm64-apple-macosx13.0
swiftc -O -o "$MACOS/$APP_NAME-x86_64" "${SWIFT_SRCS[@]}" \
  -framework AppKit -framework Foundation -framework SceneKit -framework QuartzCore -framework Metal -framework MetalKit \
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
cp "$ROOT/resources/logo-accent-256.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-dim.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/bolt-active-bright.png" "$RES/" 2>/dev/null || true
# Brand package (logo / wordmark / menubar states / favicon)
if [[ -d "$ROOT/resources/brand/pong" ]]; then
  mkdir -p "$RES/brand"
  cp -R "$ROOT/resources/brand/pong" "$RES/brand/" 2>/dev/null || true
  # Flatten state icons into Resources for NSImage(named:)
  if [[ -d "$ROOT/resources/brand/pong/macos-menubar/state" ]]; then
    cp "$ROOT/resources/brand/pong/macos-menubar/state/"*.png "$RES/" 2>/dev/null || true
  fi
  # Master mark SVG
  cp "$ROOT/resources/brand/pong/logo/"*.svg "$RES/" 2>/dev/null || true
fi
# CyberPong public wordmark (dark + light)
if [[ -d "$ROOT/resources/brand/cyberpong" ]]; then
  mkdir -p "$RES/brand"
  cp -R "$ROOT/resources/brand/cyberpong" "$RES/brand/" 2>/dev/null || true
  if [[ -d "$ROOT/resources/brand/cyberpong/wordmark" ]]; then
    cp "$ROOT/resources/brand/cyberpong/wordmark/"*.png "$RES/" 2>/dev/null || true
    cp "$ROOT/resources/brand/cyberpong/wordmark/"*.svg "$RES/" 2>/dev/null || true
  fi
fi
cp "$ROOT/resources/cyberpong-wordmark-dark.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/cyberpong-wordmark-light.png" "$RES/" 2>/dev/null || true
# Abstract tactical module textures (Imagine — conductor / worker / canvas void)
cp "$ROOT/resources/tex-conductor.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/tex-worker.png" "$RES/" 2>/dev/null || true
cp "$ROOT/resources/tex-canvas.png" "$RES/" 2>/dev/null || true
# Design fonts (Space Grotesk + IBM Plex Mono)
if [[ -d "$ROOT/resources/fonts" ]]; then
  mkdir -p "$RES/fonts"
  cp "$ROOT/resources/fonts/"*.ttf "$RES/fonts/" 2>/dev/null || true
fi
# Team install wizard templates (SOUL / SKILL / TEAM / POLICY)
if [[ -d "$ROOT/share/team-scaffold" ]]; then
  mkdir -p "$RES/team-scaffold"
  cp -R "$ROOT/share/team-scaffold/templates" "$RES/team-scaffold/" 2>/dev/null || true
fi
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
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.kulpio.pong</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>CyberPong controls Terminal windows to pair conductor and worker AI sessions.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc sign for local open (executable name MUST match CFBundleExecutable).
# Fail the build if signing fails — unsigned/mismatched bundles show as "damaged".
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
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

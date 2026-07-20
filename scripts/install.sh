#!/bin/bash
# Install Pong to /Applications and relaunch so the new binary is always running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pong.app"
SRC_APP="$ROOT/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

# Quit any running copy (including legacy names) so we never leave an old binary alive.
# Without this, `open` can attach to the already-running process and the install
# appears to “do nothing” until you quit by hand.
quit_apps() {
  local name
  for name in Pong HermesPong Hermes_Pairing HermesClaude; do
    osascript -e "tell application \"$name\" to quit" 2>/dev/null || true
  done
  # Give graceful quit a moment, then force leftover processes.
  sleep 0.6
  for name in Pong HermesPong Hermes_Pairing HermesClaude; do
    pkill -x "$name" 2>/dev/null || true
  done
  # Bundle executable paths (covers renamed/stale launches)
  pkill -f "/Applications/Pong.app/Contents/MacOS/Pong" 2>/dev/null || true
  pkill -f "/Applications/HermesPong.app/Contents/MacOS/HermesPong" 2>/dev/null || true
  pkill -f "$ROOT/dist/Pong.app/Contents/MacOS/Pong" 2>/dev/null || true
  sleep 0.2
}

quit_apps

# Remove old app bundle names from /Applications
rm -rf /Applications/Hermes_Pairing.app /Applications/HermesClaude.app /Applications/HermesPong.app 2>/dev/null || true

if [[ ! -d "$SRC_APP" ]]; then
  bash "$ROOT/scripts/build-app.sh"
fi

rm -rf "$DEST"
cp -R "$SRC_APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
# Re-sign ad-hoc (no --deep) only if the bundle isn't Developer ID signed —
# re-signing a notarized app would strip its valid signature.
if ! codesign -dv "$DEST" 2>&1 | grep -q "Authority=Developer ID"; then
  codesign -s - --force "$DEST" 2>/dev/null || true
fi

echo "Installed: $DEST (Pong)"

if [[ "${1:-}" == "--login" ]]; then
  osascript <<EOF
tell application "System Events"
  try
    delete login item "HermesPong"
  end try
  try
    delete login item "Hermes_Pairing"
  end try
  try
    delete login item "HermesClaude"
  end try
  try
    delete login item "Pong"
  end try
  make login item at end with properties {path:"$DEST", hidden:false}
end tell
EOF
  echo "Login item enabled."
fi

# Fresh launch only (never reuse a lingering instance)
open -n -a "$DEST"
echo "Launched Pong (fresh process)."

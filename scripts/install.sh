#!/bin/bash
# Install Hermes Pong to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HermesPong.app"
SRC_APP="$ROOT/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

# Remove old names
rm -rf /Applications/Hermes_Pairing.app /Applications/HermesClaude.app 2>/dev/null || true

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

echo "Installed: $DEST"

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
  make login item at end with properties {path:"$DEST", hidden:false}
end tell
EOF
  echo "Login item enabled."
fi

open "$DEST"
echo "Launched Hermes Pong."

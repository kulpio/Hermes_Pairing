#!/bin/bash
# One-shot install for Hermes_Pairing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking prerequisites…"
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v swiftc >/dev/null || { echo "Need Xcode Command Line Tools: xcode-select --install"; exit 1; }

if [[ ! -x "$ROOT/venv/bin/python" ]]; then
  echo "→ Creating Python env…"
  python3 -m venv venv
  venv/bin/pip install -q -U pip
  venv/bin/pip install -q 'pyobjc-core==10.3.2' 'pyobjc-framework-Cocoa==10.3.2'
fi

echo "→ Building app…"
bash "$ROOT/scripts/build-app.sh"

echo "→ Installing to /Applications…"
# no recursive login unless --login
bash "$ROOT/scripts/install.sh" "$@"

echo ""
echo "Done. Look for:"
echo "  • Hermes_Pairing in the Dock"
echo "  • Lightning bolt in the menu bar"
echo "  • Control panel window"
echo ""
echo "Repo: https://github.com/kulpio/Hermes_Pairing"

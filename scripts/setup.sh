#!/bin/bash
# One-shot install for Hermes Pong
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking prerequisites…"
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v swiftc >/dev/null || { echo "Need Xcode CLT: xcode-select --install"; exit 1; }

if [[ ! -x "$ROOT/venv/bin/python" ]]; then
  echo "→ Creating Python env…"
  python3 -m venv venv
  venv/bin/pip install -q -U pip
  venv/bin/pip install -q 'pyobjc-core==10.3.2' 'pyobjc-framework-Cocoa==10.3.2' 'pyobjc-framework-Quartz==10.3.2'
else
  venv/bin/pip install -q 'pyobjc-framework-Quartz==10.3.2' 2>/dev/null || true
fi

echo "→ Building…"
bash "$ROOT/scripts/build-app.sh"

echo "→ Installing…"
bash "$ROOT/scripts/install.sh" "$@"

echo ""
echo "Done."
echo "  • Hermes Pong in the Dock"
echo "  • Bolt in the menu bar"
echo "  • Control panel (guide popups for linking)"
echo ""
echo "Repo: https://github.com/kulpio/Hermes-Pong"

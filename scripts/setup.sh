#!/bin/bash
# One-shot install for Hermes Pong
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Checking prerequisites…"
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v swiftc >/dev/null || { echo "Need Xcode CLT: xcode-select --install"; exit 1; }

# v1.3: panel is native Swift — no Python/PyObjC runtime needed anymore.

echo "→ Installing bridge CLIs to ~/bin…"
mkdir -p "$HOME/bin"
for f in claude-delegate.py pong-delegate.py claude-window-relay.py pong-gate.py pong-ledger.py; do
  if [[ -f "$ROOT/scripts/$f" ]]; then
    cp "$ROOT/scripts/$f" "$HOME/bin/$f"
    chmod 755 "$HOME/bin/$f"
  fi
done

echo "→ Building…"
bash "$ROOT/scripts/build-app.sh"

echo "→ Installing…"
bash "$ROOT/scripts/install.sh" "$@"

echo ""
echo "Done — Hermes Pong 1.3"
echo "  • App: /Applications/HermesPong.app"
echo "  • Menu bar bolt + control panel"
echo "  • Bridge: ~/bin/claude-delegate.py"
echo ""
echo "Repo: https://github.com/kulpio/Hermes-Pong"
echo "Site: https://kulpio.github.io/Hermes-Pong/"

# Optional Hermes Agent skill (bridge behavior + autonomy)
if [[ "${1:-}" == "--with-hermes-skill" || "${2:-}" == "--with-hermes-skill" || "${INSTALL_HERMES_SKILL:-}" == "1" ]]; then
  echo "→ Installing optional Hermes skill pack…"
  bash "$ROOT/scripts/install-hermes-skill.sh"
else
  echo ""
  echo "Optional: make Hermes always use the bridge + autonomy like a full setup:"
  echo "  bash scripts/install-hermes-skill.sh"
  echo "  # or: bash scripts/setup.sh --with-hermes-skill"
fi


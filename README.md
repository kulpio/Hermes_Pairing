# Hermes_Pairing

Pair **Hermes** and **Claude Code** in Terminal — fast.

Two terminals. One bridge. As many pairs as you want.

---

## Install (Mac)

```bash
# 1) Clone
git clone https://github.com/kulpio/Hermes_Pairing.git
cd Hermes_Pairing

# 2) Install + open
bash scripts/setup.sh
```

That’s it.

Optional: open at login

```bash
bash scripts/setup.sh --login
```

### What you need

- macOS 13+
- Homebrew (for `tmux` if missing)
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code` then `claude`)
- Hermes agent for the other pane

---

## Use

| Action | What it does |
|--------|----------------|
| **New pair** | Starts a fresh Hermes + Claude pair |
| **Link two open Terminals** | Connects two Terminal windows you already have |
| **Rejoin / Front** | Brings that pair’s Terminal to the front |
| **Kill** | Ends that pair |

- First pair is named `hermes-claude`
- More pairs: `hermes-pair-1`, `hermes-pair-2`, …

**Menu bar:** dark lightning bolt. Glows blue → orange when a pair is active.  
**Dock:** Hermes_Pairing (click if the window is hidden).

---

## Update (after you change code)

```bash
cd Hermes_Pairing
bash scripts/push-update.sh "what you changed"
```

Rebuilds, reinstalls, commits, pushes to GitHub.

Or:

```bash
bash scripts/build-app.sh
bash scripts/install.sh
git add -A && git commit -m "…" && git push
```

---

## Uninstall

```bash
pkill -f Hermes_Pairing || true
pkill -f hermes_pairing.py || true
rm -rf /Applications/Hermes_Pairing.app
```

---

## Dev layout

```
src/MenuBarApp.swift     # menu bar (native)
src/hermes_pairing.py    # control panel window
scripts/setup.sh         # one-shot install
scripts/build-app.sh
scripts/install.sh
scripts/push-update.sh
resources/               # icons + art
```

## Signing

Ad-hoc sign runs on every build (local).  
To ship to other Macs: Apple Developer ID + notarize.

## License

MIT

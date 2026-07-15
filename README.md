# Hermes Pong

Pair **Hermes** and **Claude Code** in Terminal — fast.

Two terminals. One bridge. As many pairs as you want.

---

## Install (Mac)

```bash
git clone https://github.com/kulpio/Hermes_Pairing.git
cd Hermes_Pairing
bash scripts/setup.sh
```

Optional login item:

```bash
bash scripts/setup.sh --login
```

Opens **Hermes Pong** in `/Applications`.

---

## Use

| Action | What it does |
|--------|----------------|
| **New pair** | Fresh Hermes + Claude tmux pair |
| **Link two open Terminals** | Guide popup → **click** each Terminal (ring overlay) |
| **Front / Kill** | Per-pair controls in the panel |
| **Menu bar bolt** | Accent glow when a pair is live |
| **Quit Hermes Pong** | App menu (top left) or status menu |

---

## Bridge (from Hermes)

```bash
python ~/bin/claude-delegate.py "Your task… end with ##CLAUDE_DONE##"
```

---

## Dev

```bash
bash scripts/build-app.sh
bash scripts/install.sh
bash scripts/push-update.sh "msg"   # rebuild + install + git push
```

Repo path on Dylan’s machine:  
`~/DigitalBrain/Boreal/tools/hermes-claude-app`

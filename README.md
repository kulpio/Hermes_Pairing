# Hermes Pong

Two terminals. One bridge. Hermes talks to Claude while you watch.

---

## What this is

**Hermes Pong** pairs a **Hermes** Terminal with a **Claude Code** Terminal so Hermes can hand work to Claude.

- You keep **one Dock icon** and a **menu-bar bolt**.
- The **control panel** lists pairs (Front / Kill).
- Pairs stay linked **until you Kill them** — even if you quit Hermes Pong.

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

App: `/Applications/HermesPong.app`

---

## How it works (simple)

```
┌─────────────┐         bridge          ┌─────────────┐
│   Hermes    │  ───────────────────►   │ Claude Code │
│  terminal   │   (paste + Enter into   │  terminal   │
│             │    the Claude window)   │             │
└─────────────┘                         └─────────────┘
        ▲                                      │
        │         optional live stream         │
        └──────── Watch Claude stream ◄────────┘
```

1. You pick (or create) two Terminal windows.
2. Hermes Pong **remembers their window ids**.
3. When Hermes **delegates**, the bridge targets Claude:
   - **Link existing** → inject into **your** Claude window (keeps model + session).
   - **New pair** → Claude runs in a **fresh** tmux pane (clean start).
4. **Watch Claude stream** shows what actually landed in the Claude **tmux** side + last-sent (safety view if Hermes used raw tmux).

**Important:** Just chatting in Hermes does nothing to Claude. Hermes must run the bridge (`claude-delegate.py`) so text is pasted into Claude and Enter is pressed.

---

## Two ways to pair

### A) Link existing terminals  ← keep Claude model & context

Use this when Claude Code is **already open** with your model, resume, folder, etc.

**Steps**

1. Open Hermes in one Terminal (however you usually run it).
2. Open **Claude Code** in another Terminal — pick model, resume if you want.
3. Open **Hermes Pong** → control panel.
4. Click **Link existing terminals**.
5. Click the **Hermes** Terminal (popup shows ✓ Hermes).
6. Click the **Claude** Terminal (popup shows ✓ Claude).
7. Done. Pair stays until **Kill**.

Nothing is typed into Claude. Your session stays intact.

### B) New pair  ← two fresh Terminals

Use this for a clean setup.

**Steps**

1. Open **Hermes Pong** → **New pair**.
2. Two Terminal windows open:
   - one attached to Hermes pane
   - one attached to Claude pane (`claude` starts there)
3. Claude is **new** (no prior chat/model choice until you set it in that window).

You can still have multiple pairs; old ones stay until Kill.

---

## Panel buttons

| Control | What it does |
|--------|----------------|
| **New pair** | 2 new Terminals. Claude starts clean. |
| **Link existing terminals** | Register open Hermes + Claude windows. **Keeps Claude model/resume/chat.** |
| **Watch Claude stream** | Live I/O of what Hermes sent + Claude tmux pane. |
| **Front** | Raise + quick blink the **saved** pair windows. |
| **Kill** | Drop the pair (tmux session + registry). |
| **Refresh** | Reload pair list. |

Light copy under each button in the panel explains the same thing.

---

## After you connect

A tip may appear (always on top):

- Pair survives until **Kill**, even if the app quits.
- Link = keep Claude context; New pair = clean Claude.
- **Don't remind me** saves `~/.hermes-pong/dont-remind-pair-persist`.

Control panel, guide popup, tip, and stream stay **above other apps** so they don’t hide under Terminal.

---

## Bridge (Hermes → Claude)

Hermes (or any tool) should call:

```bash
python3 ~/bin/claude-delegate.py --no-wait 'Your task. When done print ##CLAUDE_DONE## and a short summary.'
```

That:

1. Reads `~/.hermes-pong/active-pair.json` (window vs tmux mode).
2. **Window mode** (Link existing Claude Code) → paste + Return into that Claude window.
3. **Tmux mode** (New pair) → paste + Enter into `session:1`.
4. Writes `~/.hermes-pong/last-sent.txt` (and often `last-claude.txt` in tmux mode).

**Do not** use raw:

```bash
tmux send-keys -t hermes-claude:1 '...'
```

That hits a hidden pane; your Claude Code UI can stay empty. Use **Watch Claude stream** if you need to see that pane anyway.

Skill for Hermes agents: `hermes-pong-bridge`.

---

## Files on disk

| Path | Role |
|------|------|
| `~/.hermes-pong/active-pair.json` | Current pair + window ids + mode |
| `~/.hermes-pong/pairs.json` | All pairs (for Front) |
| `~/.hermes-pong/last-sent.txt` | Last bridge prompt |
| `~/.hermes-pong/last-claude.txt` | Last captured reply |
| `~/Library/Logs/HermesPong.log` | App log |

---

## Permissions (macOS)

If paste into Claude fails:

**System Settings → Privacy & Security → Accessibility**  
Allow **Terminal** / **osascript** (and Hermes Pong if listed).

Automation for controlling Terminal may also be required the first time.

---

## Dev

```bash
bash scripts/build-app.sh
bash scripts/install.sh
bash scripts/push-update.sh "msg"
```

Local path (Dylan):  
`~/DigitalBrain/Boreal/tools/hermes-claude-app`

GitHub: [kulpio/Hermes_Pairing](https://github.com/kulpio/Hermes_Pairing)

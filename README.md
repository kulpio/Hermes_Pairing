# Hermes Pong

Two terminals. One bridge. Hermes hands work to Claude in the **Claude Code window you already have**.

---

## What this is

**Hermes Pong** links a Hermes Terminal to a Claude Code Terminal so Hermes can paste tasks into Claude (with Enter), while you keep Claude’s model, resume, and chat.

- One Dock icon + menu-bar bolt  
- Control panel: New pair / Link / Front / Kill  
- Pair stays until **Kill** — even if you quit the app  

---

## Install (Mac)

```bash
git clone https://github.com/kulpio/Hermes_Pairing.git
cd Hermes_Pairing
bash scripts/setup.sh
```

Optional login item: `bash scripts/setup.sh --login`  
App: `/Applications/HermesPong.app`

---

## How it works

```
Hermes terminal                    Claude Code terminal (yours)
      │                                      ▲
      │   claude-delegate.py                 │
      └──── paste + Enter ───────────────────┘
```

1. You **Link** (or create) two Terminals.  
2. Pong saves the **window ids**.  
3. When Hermes delegates, it must call **`claude-delegate.py`**, which pastes into the **Claude Code window** and presses Enter.  
4. You watch Claude work in that window — model, resume, context stay.

**Chatting in Hermes alone never appears in Claude.** Hermes has to use the bridge.

---

## Link existing terminals (keep model + context)

Use when Claude Code is already open.

1. Hermes running in one Terminal.  
2. Claude Code in another — pick model / resume as usual.  
3. Hermes Pong → **Link existing terminals**.  
4. Click **Hermes** Terminal (✓ in popup).  
5. Click **Claude** Terminal (✓ in popup).  
6. Done. Nothing is injected into Claude at link time.

---

## New pair (two fresh Terminals)

1. Hermes Pong → **New pair**.  
2. Two Terminal windows: **one runs Hermes**, **one runs Claude** (not Claude twice).  
3. Claude starts **clean** — for model/resume you already set up, use **Link existing** instead.

---

## Panel

| Control | Meaning |
|--------|---------|
| **New pair** | 2 new Terminals. Claude starts clean. |
| **Link existing terminals** | Register open Hermes + Claude. **Keeps Claude model/resume/chat.** |
| **Front** | Raise the paired windows (short blink). |
| **Kill** | Drop the pair. |
| **Refresh** | Reload list. |

---

## Bridge (must land in Claude Code)

```bash
python3 ~/bin/claude-delegate.py --no-wait 'Your task. When done print ##CLAUDE_DONE## and a short summary.'
```

- **Link existing** → window mode → paste into **your** Claude Code window.  
- **New pair** → tmux mode → paste into the Claude Terminal of that pair.  

**Do not** use raw `tmux send-keys -t hermes-claude:1 …` — that hits a hidden pane, not the Claude UI you’re watching.

Hermes skill: `hermes-pong-bridge`.

---

## Files

| Path | Role |
|------|------|
| `~/.hermes-pong/active-pair.json` | Current pair + window ids + mode |
| `~/.hermes-pong/pairs.json` | All pairs |
| `~/.hermes-pong/last-sent.txt` | Last bridge prompt |
| `~/.hermes-pong/last-claude.txt` | Last captured reply (tmux mode) |
| `~/Library/Logs/HermesPong.log` | Log |

---

## Permissions

If paste fails: **System Settings → Privacy & Security → Accessibility** (Terminal / osascript).

---

## Dev

```bash
bash scripts/build-app.sh && bash scripts/install.sh
bash scripts/push-update.sh "msg"
```

Repo: [kulpio/Hermes_Pairing](https://github.com/kulpio/Hermes_Pairing)  
Local: `~/DigitalBrain/Boreal/tools/hermes-claude-app`

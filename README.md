<p align="center">
  <img src="resources/AppIcon-1024.png" width="128" alt="Hermes Pong" />
</p>

<h1 align="center">Hermes Pong</h1>

<p align="center">
  <strong>Two terminals. One bridge.</strong><br />
  Hermes orchestrates. Claude Code builds — in the window you already use.
</p>

<p align="center">
  <a href="https://kulpio.github.io/Hermes-Pong/">Website</a> ·
  <a href="https://github.com/kulpio/Hermes-Pong/releases/latest">Download</a> ·
  <a href="#install-macos">Install</a>
</p>

<p align="center">
  <img src="resources/pair-illustration.png" width="480" alt="Hermes terminal bridged to Claude Code" />
</p>

---

## What it does

**Hermes Pong** is a small macOS app that pairs:

| | |
|--|--|
| <img src="resources/logo-accent-128.png" width="40" alt="Hermes" /> | **Hermes** — plans, orchestrates, decides next steps |
| <img src="resources/brand/claude-logo.svg.png" width="40" alt="Claude" /> | **Claude Code** — writes and runs the code |

Hermes sends a task into your **live Claude Code terminal** (paste + Enter). You keep Claude’s model, resume, and chat. You watch the work happen.

> Chatting only inside Hermes does **not** reach Claude. Work crosses the bridge with one command (below).

---

## Requirements

- macOS
- [Terminal.app](https://support.apple.com/guide/terminal/welcome/mac)
- [tmux](https://github.com/tmux/tmux) (`brew install tmux`)
- [Hermes](https://github.com/NousResearch/hermes-agent) (or your Hermes CLI)
- [Claude Code](https://claude.ai/code) CLI

---

## Install (macOS)

### Option A — release zip

1. Open the [latest release](https://github.com/kulpio/Hermes-Pong/releases/latest)
2. Download **HermesPong-macOS.zip** (or from the [landing page](https://kulpio.github.io/Hermes-Pong/))
3. Unzip → drag **Hermes Pong** into **Applications**
4. First open: right-click → **Open** if Gatekeeper warns (ad-hoc signed for now)

### Option B — from source

```bash
git clone https://github.com/kulpio/Hermes-Pong.git
cd Hermes-Pong
bash scripts/setup.sh
```

That builds and installs `/Applications/HermesPong.app`.

Optional: start at login:

```bash
bash scripts/setup.sh --login
```

---

## Quick start

### 1. Link what you already use (recommended)

Best when Claude Code is already open with the right model / session.

1. Open **Hermes** in one Terminal window  
2. Open **Claude Code** in another  
3. Launch **Hermes Pong** (menu bar bolt or Dock)  
4. Click **Link existing terminals**  
5. Select the **Hermes** window, then the **Claude** window  
6. You should see the pair under **Active pairs**

Nothing is injected into Claude at link time. Your model, resume, and chat stay as they are.

### 2. Or start a New pair

1. Click **New pair**  
2. Two Terminals open: one for Hermes, one for Claude  
3. Claude starts **fresh** (no prior session)

Use **Link** when you care about an existing Claude conversation.

---

## How the bridge works

```text
┌─────────────────┐         claude-delegate.py          ┌──────────────────┐
│  Hermes window  │  ── paste + Enter ─────────────────► │  Claude Code UI  │
│  (orchestrate)  │                                      │  (build & code)  │
└─────────────────┘                                      └──────────────────┘
```

From Hermes (or any shell), send work like this:

```bash
python3 ~/bin/claude-delegate.py --no-wait \
  'Your task here. When completely done, print exactly ##CLAUDE_DONE## then a short summary.'
```

| Mode | When | Where the task lands |
|------|------|----------------------|
| **Link existing** | You registered two open Terminals | Your real Claude Code window |
| **New pair** | App opened two fresh Terminals | That pair’s Claude terminal (via tmux) |

**Do not** hand-type raw `tmux send-keys` into a hidden pane if you want to *see* the work in Claude’s UI. Use `claude-delegate.py`.

---

## Control panel

| Control | What it does |
|--------|----------------|
| **New pair** | Open two Terminals (Hermes + Claude) |
| **Link existing terminals** | Pair open Hermes + Claude (keeps Claude context) |
| **Front** | Bring that pair’s windows forward |
| **Kill** | End the pair |
| **Every / Done / Full** | How often Hermes should ask you before continuing (autonomy) |

### Autonomy (simple)

- **Every** — ask after each Claude reply  
- **Done** — ask when Claude finishes the task (`##CLAUDE_DONE##`)  
- **Full** — keep going with minimal interruptions  

Autonomy is a preference for the orchestrator. It does not replace watching Claude’s window.

---

## Permissions

If paste into Claude fails:

**System Settings → Privacy & Security → Accessibility**  
Allow **Terminal** (and related tools you use to run the bridge).

---

## Tips & free download

Pay what you want (including **$0**):

**https://kulpio.github.io/Hermes-Pong/**

---

## Rebuild (developers)

```bash
bash scripts/build-app.sh
bash scripts/install.sh
```

---

<p align="center">
  <img src="resources/logo-accent.png" width="48" alt="" />
  <br />
  <sub>Built for people who want Hermes to drive and Claude Code to ship.</sub>
</p>

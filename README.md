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

## Install (macOS) — v1.3

### Option A — release zip

1. Open the [latest release](https://github.com/kulpio/Hermes-Pong/releases/latest)
2. Download **HermesPong-macOS.zip** (or from the [landing page](https://kulpio.github.io/Hermes-Pong/))
3. Unzip → drag **Hermes Pong** into **Applications**
4. Double-click to open — the app is signed and notarized, so Gatekeeper lets it straight through

On first launch a small welcome window explains the two one-time permissions (see [Permissions](#permissions)).

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

### Verdict loop

Since v1.3, Hermes doesn’t take Claude’s word for it. When Claude prints `##CLAUDE_DONE##` plus a **CLAIM block** (files changed, commands run, test tail), Hermes independently runs the acceptance checks before accepting. Every accept/reject lands in a local ledger (`~/.hermes-pong/ledger/`) so recurring failure patterns follow Claude into the next session. Three rejects on one task escalate to you with the full evidence trail.

<p align="center">
  <img src="resources/verdict-loop.svg" width="760" alt="Hermes sends a task to Claude Code; Claude ships and files a CLAIM; Hermes the detective runs the checks itself; failures loop back as rejections with evidence, passes are saved to the local ledger" />
</p>

The loop always runs — there are no supervision modes to configure. It works silently until accept, or escalates to you after three rejects. The menu bar shows the ledger at a glance (rounds, accept rate, reject streak).

**Privacy:** everything — pairs, tasks, and the verdict ledger — stays on your Mac. Nothing is sent anywhere.

---

## Control panel

| Control | What it does |
|--------|----------------|
| **New pair** | Open two Terminals (Hermes + Claude) |
| **Link existing terminals** | Pair open Hermes + Claude (keeps Claude context) |
| **Front** | Bring that pair’s windows forward |
| **Kill** | End the pair |
| **Perms** | Per-pair access bans + note (MCPs, root, network, system paths, freeform). Injected into every Claude handoff. |

The menu bar bolt glows while a pair is active and shows the verdict ledger (rounds, accept rate, reject streak, last verdict).

---

## Permissions

Two one-time permissions, both explained by the first-run welcome window:

- **Automation** — Hermes Pong sends tasks into your Terminal windows. macOS prompts the first time a task is sent; if you decline, re-enable it under **System Settings → Privacy & Security → Automation**.
- **Accessibility** — needed so paste + Enter lands reliably in the Claude window: **System Settings → Privacy & Security → Accessibility** (allow Terminal and the tools you use to run the bridge).

The welcome window has buttons that jump straight to both Settings panes.

---

## Tips & free download

Pay what you want (including **$0**):

**https://kulpio.github.io/Hermes-Pong/**

---


---

## Optional: Hermes Agent skill

The Mac app pairs windows. **Hermes Agent** still needs a skill so it keeps sending work to Claude (and runs the verdict loop on every CLAIM).

Optional install (no personal config; safe to re-run):

```bash
bash scripts/install-hermes-skill.sh
# or with full setup:
bash scripts/setup.sh --with-hermes-skill
```

This installs:

- Skill `hermes-pong-bridge` → `~/.hermes/skills/workflow/`
- CLIs → `~/bin` (`claude-delegate.py`, `claude-window-relay.py`, `pong-gate.py`, `pong-ledger.py`)
- Task template → `~/.hermes-pong/templates/task.md`
- Short agent hint → `~/.hermes-pong/AGENT-HINT.md`

Restart Hermes after installing. Then, when a pair is active:

```bash
python3 ~/bin/pong-gate.py   # BRIDGE_ON?
python3 ~/bin/claude-delegate.py --no-wait '… ##CLAUDE_DONE##'
```

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

# CyberPong

**Local agent mission control for Mac.**

CyberPong lets you run a **team of AI coding tools** on your machine: one conductor plans and assigns work, workers build in real Terminal sessions, and you stay in the loop when something needs a human.

The menu-bar app shows as **CyberPong**. The binary and paths still say `Pong` for compatibility (`/Applications/Pong.app`, `pong` CLI, `~/.pong/`).

| | |
|--|--|
| **UI name** | CyberPong |
| **Repo** | [kulpio/Agent-Pong](https://github.com/kulpio/Agent-Pong) |
| **Conductors** | Grok Build, Claude Code, Hermes Agent, custom CLI |
| **Workers** | Claude, Grok, Codex, Kimi, OpenCode, Hermes, custom |
| **State** | `~/.pong/` (jobs, events, ledger, teams) |
| **Platform** | macOS 13+ |

---

## What it can do

In plain language:

1. **Build multi-agent teams** — Pick a conductor and staff workers from the CLIs you already use. Each seat is a real Terminal / tmux session you can open anytime.
2. **See the mission live** — A 3D map shows orchestrator, agents, sub-agents, and you. Links and status update as work moves. Floor-line dots only travel when data is actually flowing.
3. **Talk without hunting windows** — Human console: send a prompt to the selected orchestrator, and answer “needs you” asks when a job waits on input.
4. **Keep handoffs honest** — Jobs are files under `~/.pong/jobs/…`. Create, list, and inspect work from the CLI or the app. Progress isn’t only “whatever got pasted into chat.”
5. **Design the topology** — Architecture editor for peer vs sub-agent links, snap-to-orchestrator, save the graph with the team.
6. **Schedule work** — Cron jobs on a 3D timeline (future into the distance) plus a left HUD list.
7. **Save and reopen lineups** — Save Team / Show Teams for names, seats, models, and graph.
8. **Stay local** — Teams, jobs, ledger, and events stay on your Mac. CyberPong does **not** store vendor API keys.

---

## Quick start

```bash
git clone https://github.com/kulpio/Agent-Pong.git
cd Agent-Pong
bash scripts/setup.sh --with-skills
```

CLIs install to `~/bin` (`pong`, `pong-gate.py`, `pong-delegate.py`, …).

### Build the Mac app

```bash
bash scripts/build-app.sh --dev
bash scripts/install.sh
```

That installs `/Applications/Pong.app` and launches **CyberPong**.

Migrate older Hermes Pong state if needed:

```bash
pong migrate
```

---

## In the app

1. **New team** — choose conductor + workers.
2. Send a mission from the **human console** or the conductor terminal.
3. Watch seats on the **mission map**; open Architecture when you want to edit links.
4. Intervene in any worker Terminal when you need to; use Focus / Stow / Kill as needed.
5. **Save Team** so you can reopen the lineup later.

---

## CLI (control plane)

```bash
pong status
pong gate                          # BRIDGE_ON / OFF
pong check                         # foundation self-check
pong snapshot                      # JSON the panel reads
pong job create --worker w1 --task 'Implement login. Tests must pass.'
pong job create --worker w1 --task '…' --no-paste
pong job list
pong job show job_…
pong events -n 20
pong ledger record --task-id T1 --round 1 --verdict accept --evidence 'npm test ok'
```

The UI is built on **`pong snapshot`**. Details: [`docs/UI-CONTRACT.md`](docs/UI-CONTRACT.md).

Architecture notes: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)  
Agent vocabulary / north star: [`docs/NORTH-STAR-AGENT-HANDOUT.md`](docs/NORTH-STAR-AGENT-HANDOUT.md)

Compat aliases: `pong-delegate.py`, `claude-delegate.py`, `pong-gate.py`.

---

## Skills

```bash
bash scripts/install-skills.sh          # Grok + Hermes
bash scripts/install-skills.sh grok
bash scripts/install-skills.sh hermes
```

| Skill | Role |
|-------|------|
| `pong-bridge` | Generic conductor protocol |
| `grok-pong-bridge` | Grok as conductor |
| `hermes-pong-bridge` | Hermes as conductor |

---

## State

| Path | What |
|------|------|
| `~/.pong/` | Primary state (teams, jobs, events, ledger) |
| `~/.hermes-pong/` | Legacy read path |

Env on team panes: `PONG_SESSION` (legacy: `HERMES_PONG_SESSION`).

---

## Landing page

Marketing site sources live in [`landing/`](landing/). Deploy that folder (e.g. Vercel) for the public page.

Brand kit (mark, wordmarks, favicons): [`brand/`](brand/) and [`resources/brand/`](resources/brand/).

---

## Version

**2.0.0-alpha** — control plane, multi-CLI teams, 3D mission map, architecture editor, cron timeline, human console.

---

## License / privacy

Local-only teams, jobs, and ledger. No vendor API keys stored by CyberPong.
}

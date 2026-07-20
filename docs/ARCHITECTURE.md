# Pong architecture (Agent-Pong)

**Pong** is local **agent mission control**: multi-CLI teams, conductor-agnostic orchestration, human-in-the-loop terminals, and a job control plane. Paste into a TUI is optional sugar — not the system of record.

**UI consumers:** read [`UI-CONTRACT.md`](UI-CONTRACT.md) — `pong snapshot` is the only envelope the panel should depend on.

**Product north star & naming:** [`NORTH-STAR-AGENT-HANDOUT.md`](NORTH-STAR-AGENT-HANDOUT.md) — live runtime console (teams, seats, session policy, jobs). Do not conflate with standing grants / Umbra.

## Goals

| Goal | How |
|------|-----|
| Grok Build as recommended conductor | First-class `conductor.type = grok` |
| Hermes users without Grok | `conductor.type = hermes` (or custom) — same app |
| Human can enter any terminal | Real CLIs stay open; intervene anytime |
| Robust handoff | **Jobs + claims** on disk; optional paste/headless notify |
| Multi-team isolation | Bound session (`PONG_SESSION` / `HERMES_PONG_SESSION`) |
| Verify, don’t trust | Verdict ledger + acceptance commands |

## Seats

```text
┌─────────────┐     jobs/claims      ┌──────────────┐
│  CONDUCTOR  │ ───────────────────► │   WORKERS    │
│  Grok /     │ ◄─────────────────── │  Claude /    │
│  Hermes /   │     claim + status   │  Codex / …   │
│  custom     │                      └──────────────┘
└─────────────┘
       │
       │ optional
       ▼
┌─────────────┐
│  OPS PEER   │  Hermes send → Photon / cron (not coding prompt box)
└─────────────┘
```

- **You type mission prompts into the conductor TUI** when that seat is Grok/Hermes/etc.
- **You type interventions into any worker TUI** (model change, plan-only, takeover).
- **Ops** (iMessage via Photon) is a peer channel, not the coding orchestra.

## State root

Primary: `~/.pong/`  
Legacy read/write fallback: `~/.hermes-pong/` (migrated on first write when only legacy exists)

| Path | Purpose |
|------|---------|
| `pairs.json` | All teams |
| `active-pair.json` | Last-focused team (compat) |
| `jobs/<session>/<job_id>.json` | Job queue (source of truth for handoffs) |
| `sessions/<session>/last-sent.txt` | Last outbound text artifact |
| `sessions/<session>/last-reply.txt` | Last worker reply artifact |
| `ledger/` | Verdicts + patterns |
| `binds/<session>.md` | Bind card for conductor skills |
| `briefs/<session>.md` | Team brief mirror |
| `teams.json` | Saved team snapshots |
| `workers.json` | Worker cmd overrides |
| `conductors.json` | Conductor cmd overrides |
| `settings.json` | App settings |

## Pair / team schema

```json
{
  "session": "pong-team",
  "schema_version": 2,
  "conductor": {
    "id": "c1",
    "type": "grok",
    "label": "Grok Build",
    "cmd": "grok",
    "window_id": "123",
    "mode": "tmux",
    "tmux_index": 0
  },
  "workers": [
    {
      "id": "w1",
      "type": "claude",
      "label": "Claude Code",
      "cmd": "claude",
      "window_id": "456",
      "mode": "tmux",
      "tmux_index": 1,
      "done_marker": "##WORKER_DONE##"
    }
  ],
  "transport_default": "job+paste",
  "project_root": "/path/to/repo",
  "team_brief": "…",
  "permissions": {},
  "autonomy_level": "full",
  "display_name": "Auth rewrite",
  "hermes_window_id": "123",
  "claude_window_id": "456",
  "claude_mode": "tmux"
}
```

Legacy v1 fields (`hermes_window_id`, single worker, no `conductor`) are **normalized on read** to v2 (Hermes as conductor).

Session name accept list: `pong-team`, `pong-team-N`, `hermes-pair*`, `hermes-claude*` (legacy).

## Job schema

```json
{
  "id": "job_20260719_a1b2",
  "session": "pong-team",
  "worker": "w1",
  "status": "queued",
  "task": "Implement …",
  "project_root": "/path",
  "team_brief": "…",
  "acceptance": [{"cmd": "npm test", "expect_exit": 0}],
  "done_marker": "##WORKER_DONE##",
  "require_claim": true,
  "human_takeover": false,
  "round": 1,
  "created_at": 0,
  "updated_at": 0,
  "claim": null,
  "error": null,
  "transports_used": ["job_file", "tmux_paste"]
}
```

Statuses: `queued` → `notified` → `running` → `done` | `failed` | `rejected` | `human_takeover` | `cancelled`

## Transports

| Id | Role |
|----|------|
| `job_file` | Always write job JSON (control plane) |
| `tmux_paste` | Optional: paste + Enter into worker pane |
| `window_paste` | Optional: clipboard into Terminal window |
| `headless` | Optional: run worker CLI non-interactively (`-p` / `-q`) |

Default **`job+paste`**: create job, then paste so the human sees work in the live TUI.  
If paste fails, job remains **queued** — system still progresses when a worker/headless runner picks it up.

## CLI surface

```bash
pong status
pong gate
pong job create --worker w1 --task '…' [--no-paste] [--headless]
pong job list [--session S]
pong job show <id>
pong job claim <id> --files a,b --summary '…'
pong job status <id> running|done|failed|human_takeover
pong delegate …     # compat: create job + transport
pong ledger …
```

Env bind order: explicit `-s` → `PONG_SESSION` → `HERMES_PONG_SESSION` → tmux pair name → `active-pair.json`.

## Skills

| Skill | When |
|-------|------|
| `pong-bridge` | Generic conductor rules |
| `grok-pong-bridge` | Grok is conductor |
| `hermes-pong-bridge` | Hermes is conductor (legacy + Hermes-first users) |

While bridge is on: conductor does **not** implement product code; it submits jobs, runs acceptance, records verdicts.

## App (macOS)

Menu bar + panel remain the **layout and team UX** (Front, Kill, Stow, colors, perms, Save Team).  
v2 adds: conductor picker (Grok recommended), mission/job strip, human-takeover affordance.

## Non-goals (for now)

- Hosting vendor API keys
- Replacing each vendor’s native TUI
- Live token streaming mirrors of worker UIs
- Cloud multi-tenant orchestration

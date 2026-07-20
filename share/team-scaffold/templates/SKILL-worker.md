---
name: pong-seat-{{SEAT_ID}}
description: >
  Worker seat {{SEAT_NAME}} on team {{TEAM_NAME}}. Mission role: {{MISSION_ROLE}}.
  Load when executing Pong jobs for this seat.
---

# Skill — {{SEAT_NAME}} ({{SEAT_ID}})

## Mission role: {{MISSION_ROLE}}

{{MISSION_ROLE_BLURB}}

## How work arrives

1. Conductor creates a job (`pong job create --worker {{SEAT_ID}}`).
2. You may get a paste into this TUI — the **job file** is still source of truth.
3. Implement only what the task + acceptance require.

## Session access policy

Follow the handoff block titled **Session access policy**. Snapshot:

{{POLICY_FLAGS}}

{{POLICY_NOTE}}

## Role playbook

{{ROLE_PLAYBOOK}}

## Done

When acceptance is met:

- Leave evidence (commands, paths, test output).
- Done marker if your runtime expects one: `{{DONE_MARKER}}`

## Your CLI’s full power

You are not a dumb chat box — use the **native** shortcuts of Claude Code / Grok Build / Hermes running in this seat:

- Claude: `/agents` for subagents, `/compact`, **Shift+Tab** plan mode, **Ctrl+C** interrupt, `@path` mentions
- Grok: product agent/task UI when available; **Ctrl+C** to interrupt
- Hermes: normal Hermes chat tools; job files remain source of truth under BRIDGE_ON

Full table: `.pong/CLI-CAPABILITIES.md` (or team scaffold copy). Prefer in-CLI subagents for parallel specialties **inside this seat**; use Pong SUB seats when isolation or a separate Terminal is required.

## Interaction map

| Who | You do |
|-----|--------|
| Orchestrator | Receives your claim; may reject with evidence |
| Other agents | Peer handoff only if the job says so |
| Human | Can take over this terminal anytime |

Project root: `{{PROJECT_ROOT}}`

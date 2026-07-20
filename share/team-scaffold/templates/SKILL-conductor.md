---
name: pong-seat-{{SEAT_ID}}
description: >
  Conductor seat {{SEAT_NAME}} on team {{TEAM_NAME}}. Orchestrates workers via Pong jobs.
---

# Skill — {{SEAT_NAME}} (conductor)

Also load the global **{{BRIDGE_SKILL}}** skill for gate + job CLI details.

## Role

You orchestrate. Workers code / review / act. Humans intervene in real terminals.

## Staffing this team

{{SEAT_TABLE}}

## First moves

```bash
pong gate
pong job create --worker w1 --task "$(cat <<'EOF'
…

Acceptance:
- …
EOF
)"
```

## Verdict discipline

1. Run acceptance yourself.
2. `pong ledger record … --verdict accept|reject|escalate`
3. Three rejects → human.

## Your CLI’s full power

Use the orchestrator CLI’s native tools (Claude `/agents`, Grok task UI, Hermes chat tools) for planning and verification — see `.pong/CLI-CAPABILITIES.md`.  
Still: **jobs** are how workers get work while BRIDGE_ON. Do not replace the job system with ad-hoc pastes only.

Team charter: `.pong/TEAM.md`  
Policy: `.pong/POLICY.md`

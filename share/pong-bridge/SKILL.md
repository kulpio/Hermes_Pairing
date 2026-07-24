---
name: pong-bridge
description: >
  Load when Pong (Agent-Pong) has an active team. You are the conductor —
  route implementation through jobs, never code product yourself while BRIDGE_ON.
---

# Pong bridge (generic conductor)

## Gate

```bash
pong gate
# or: python3 ~/bin/pong-gate.py
```

| Result | Meaning |
|--------|---------|
| `BRIDGE_OFF` | You may implement yourself |
| `BRIDGE_ON session=… conductor=…` | Orchestrate only — submit jobs to **this** team |

## Submit work (preferred)

```bash
pong job create --worker w1 --task "$(cat <<'EOF'
<task>

Acceptance:
- npm test exits 0
EOF
)"
```

- Default transport is **job file + TUI paste** (worker should see the prompt in Terminal). Job JSON is the source of truth.
- `--no-paste` — control plane only when you intentionally skip the TUI.
- **Do not use `--headless` by default** — it hides work from the Terminal seat. Only if paste is impossible and the human asked for offline run.
- **Architecture edges are enforced.** If Architecture shows `orch → Bob → Lil bob`, you **must** `job create --worker` Bob first; a direct job to Lil bob is refused (`flow_hop_required`). Bob then creates the sub-job for Lil bob. Claims notify along **claim** edges back to you — still run acceptance before ledger accept.

Compat:

```bash
pong delegate --worker w1 --no-wait '…'
```

## Verdict loop

Never accept a done marker on the claim alone.

1. Run acceptance checks yourself.
2. `pong ledger record --task-id <id> --round N --verdict accept|reject|escalate --evidence '…'`
3. On reject, create a new job round with specific evidence.
4. Three rejects → escalate to the human.

## Human intervention

Workers run real TUIs. Humans may type in any worker window anytime.
If the human takes over: `pong job status <id> human_takeover` — do not re-paste over them.

## Isolation

Bound via `PONG_SESSION` / `HERMES_PONG_SESSION` / tmux pair name.
Never send to another `pong-team*` / `hermes-pair*` session.

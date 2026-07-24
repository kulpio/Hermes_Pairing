---
name: grok-pong-bridge
description: >
  Load when you are Grok Build acting as Pong conductor (recommended default).
  Fan out work via pong jobs; verify claims; do not implement product code while BRIDGE_ON.
---

# Grok Build as Pong conductor

You are the **team lead**. Workers (Claude, Codex, etc.) implement in their own terminals.

1. `pong gate` — expect `BRIDGE_ON` with `conductor=grok`
2. Plan (use Plan mode if ambiguous), then **job create** per worker
3. Read claims / session reply files under `~/.pong/sessions/<session>/`
4. Run acceptance; ledger accept/reject/escalate
5. Optional ops: `hermes send --to photon "…"` for notifications (not for coding prompts)

## Fan-out pattern

```bash
pong job create --worker w1 --task 'Implement X in project_root. End with done marker + CLAIM.'
pong job create --worker w2 --task 'Write tests for X only. End with done marker + CLAIM.'
```

## Hard rules

- While BRIDGE_ON: **no product file edits** yourself — only verify, plan, job, ledger.
- Prefer default **job+paste** so workers see the handoff in Terminal. Use `--no-paste` only when intentionally silent. Avoid `--headless` unless the human asked for offline run (it hides the seat TUI).
- **Honor Architecture:** only assign seats you have a forward edge to. Subagents (e.g. Lil bob under Bob) get work via their parent seat’s job create — not a direct hop from you. If `pong job create` says `flow_hop_required`, follow the hop list.
- Respect TEAM CONTEXT / project_root on every job.
- `pong status` anytime for roster + bind card.

See also skill **pong-bridge** for shared protocol.

# Bridge delivery issue (flagged 2026-07-20)

## What the user saw
Claude on the pair bridge looked idle while Grok claimed to “send to Claude.”

## Root cause
1. **`transport_default` defaulted to `"job"`** in `python/pong/state.py`  
   → `pong-delegate` / `dispatch_job` only ran **`job_file`** (wrote `~/.pong/jobs/...`).  
   → **No `tmux_paste`** into Claude’s pane → Claude Code TUI never showed the task.  
   Evidence: `job_20260720_102035_86f775.json` has `"transports_used": ["job_file"]`, `"status": "queued"`.

2. **Grok sometimes bypassed the bridge** with raw `tmux paste-buffer` after the job stayed queued. That *can* wake Claude, but:
   - does not update Hermes job status / ledger
   - does not appear as a normal bridge handoff to the operator
   - is easy to miss if watching the Hermes rail

3. Pair **project_root is Umbra**, so even a successful paste wraps Agent-Pong tasks in “hard scope Umbra” context. Claude needs an explicit scope override every time (works, but fragile).

## Fix applied
- Default `transport_default` → **`job+paste`** in `python/pong/state.py`.
- Live `active-pair.json` / pairs entries updated to `job+paste` where they were `job`.
- Orchestrator rule: after `pong-delegate`, require `transport[ok] tmux_paste` / status **`notified`**, not only `queued`. If paste fails, re-dispatch with `--paste-only` and surface the failure — do not silently rely on out-of-band tmux.

## Verify next handoff
```bash
HERMES_PONG_SESSION=hermes-pair-2 python3 scripts/pong-delegate.py --worker w1 'ping from bridge'
# expect: transport[ok] job_file + transport[ok] tmux_paste, status=notified
# Claude pane should show the prompt
```

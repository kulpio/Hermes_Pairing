# Bridge routing

## State files
- `~/.hermes-pong/active-pair.json` — session, window ids, `claude_mode`, `autonomy_level`
- `~/.hermes-pong/pairs.json` — all pairs
- `~/.hermes-pong/last-sent.txt` — last bridge prompt
- `~/.hermes-pong/sessions/<session>/last-claude.txt` — your session's last captured reply (stronger in tmux mode). Top-level `last-claude.txt` mirrors the active session only.
- `~/.hermes-pong/relay.pid` — window-mode relay process

## Decision tree
1. Resolve the BOUND session: CLI `-s` → env `HERMES_PONG_SESSION` → surrounding tmux pair name → `active-pair.json`.
2. Load that session's entry from `pairs.json` (active-pair merges in only when it is the same session). Workers/labels/window ids come from there only.
3. If the resolved worker's `mode == window` and it has a window id → paste into that Terminal window.
4. Else paste into `bound_session:<tmux_index>` — never another pair's panes.
5. No session / no workers / ambiguous `--worker` key → exit 2 (fail closed, roster printed).

## “Sent” but Claude idle
- Prefer `claude-delegate.py` only (not raw `tmux send-keys`).
- Link/window mode uses `claude-window-relay.py` when Hermes types into a hidden pane.
- Log: `~/Library/Logs/HermesPong-relay.log`

## Accessibility
System Settings → Privacy & Security → Accessibility for Terminal / Python if paste fails.

## Mid-session drop
After a few handoffs Hermes may forget the bridge. Re-run `pong-gate.py` before every coding step. If `BRIDGE_ON`, only `claude-delegate.py`.

# Hermes Pong → multi-worker army

## Product truth

Hermes is the **orchestrator**. Terminal windows are **workers**.

Claude Code is the **default worker**, not the product identity.  
A worker is: any logged-in AI CLI/TUI the user already runs (Claude, Kimi, Grok, Codex, OpenCode, DeepSeek CLI, custom).

Naming: **never** “HermesClaude” as product language.  
Session ids: `hermes-pair` / `hermes-pair-N` (legacy `hermes-claude*` still loads).

## UX principles

1. **User signs in outside the app.** Pong does not own OAuth for every model. New pair launches the chosen CLI; Link attaches windows that are already live.
2. **New pair** = pick orchestrator (Hermes) + **one or more workers** (type + launch cmd).
3. **Link existing** = pick Hermes window + **N worker windows** (click sequence or multi-select). Keep each worker’s session/context.
4. **One Hermes → many workers.** Same orchestrator can run Claude on window A, Kimi on B, DeepSeek on C.
5. **Bridge routes by worker id**, not “the Claude pane.” Verdict loop stays Hermes-side.

## Worker registry (built-in seeds)

| id | Label | Default launch | Done marker (default) |
|----|--------|----------------|------------------------|
| `claude` | Claude Code | `claude` | `##CLAUDE_DONE##` (alias of generic) |
| `kimi` | Kimi | `kimi` (user override) | `##WORKER_DONE##` |
| `grok` | Grok | `grok` / custom | `##WORKER_DONE##` |
| `codex` | Codex | `codex` | `##WORKER_DONE##` |
| `opencode` | OpenCode | `opencode` | `##WORKER_DONE##` |
| `custom` | Custom | user command | `##WORKER_DONE##` |

Users can edit/add cmds in `~/.hermes-pong/workers.json`.

## State shape (target)

```json
{
  "session": "hermes-pair-1",
  "hermes_window_id": "123",
  "workers": [
    {
      "id": "w1",
      "type": "claude",
      "label": "Claude Code",
      "window_id": "456",
      "mode": "window",
      "cmd": "claude",
      "done_marker": "##WORKER_DONE##"
    },
    {
      "id": "w2",
      "type": "custom",
      "label": "Kimi",
      "window_id": "789",
      "mode": "window",
      "cmd": "kimi"
    }
  ],
  "permissions": {},
  "autonomy_level": "full"
}
```

Bridge:

```bash
python3 ~/bin/pong-delegate.py --worker w1 --no-wait 'task…'
# default worker = first / last-active
```

Legacy `claude-delegate.py` becomes a thin alias → default worker (Claude if present).

## Phases

### Phase 1 — identity + pick one worker (still 1:1)
- Rename product copy: Hermes + **worker** (Claude as default example).
- Session names: `hermes-pair*`.
- New pair: picker for worker type before launch.
- Link: still two clicks, but second is “worker” not “Claude” in UI.
- State: `worker_type`, `worker_cmd` on pair (prep for array).
- Landing: multi-model, Claude featured not exclusive.

### Phase 2 — multi-worker attach ✅ (shipped)
- Link: Hermes + add workers, then **Done**.
- New pair: multi-select types → N terminals.
- Panel row lists workers under the pair.
- `pong-delegate.py --worker <id>` (alias of claude-delegate).

### Phase 3 — army control
- Task 1 slice shipped: **Team Options** on the Hermes row (Save Team moved inside) with display name, `project_root`, and `team_brief` per pair. The bridge injects a TEAM CONTEXT block (bound session + project root + brief) on every handoff, and the brief is mirrored to `~/.hermes-pong/briefs/<session>.md`, so pairs on different projects cannot bleed into each other via agent context.
- Hermes prompt bank: fan-out, specialist roles, cross-check.
- Per-worker perms / tip milestones unchanged at pair level.
- Optional OpenRouter as a **custom** worker cmd only (no Pong-hosted login).

## Non-goals (for now)

- Building a model marketplace inside Pong
- Storing API keys for every vendor
- Replacing each vendor’s native TUI

## Done looks like

Dylan opens Hermes once, links Claude + Kimi + whatever is signed in, and Hermes routes claims/verdicts per worker — local, controlled, no single-vendor lock-in.

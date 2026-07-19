# Shell vs Claude TUI pre-flight

A pair can be ACTIVE while the Claude window is still a **shell**.

## Before every non-trivial send

1. Read `~/.hermes-pong/active-pair.json`.
2. Confirm Claude Code UI is visible (not `user@host %` / `$`).

| What you see | Action |
|--------------|--------|
| Shell prompt only | Stop. Re-Link to the real Claude Code terminal. |
| Claude Code TUI | Safe to send |
| zsh “command not found” after send | Target was a shell — re-Link |
| `claude` running on another TTY | Link that Terminal instead |

## Long tasks

Write briefs to `~/.hermes-pong/tasks/<name>.md`, then:

```bash
python3 ~/bin/claude-delegate.py --no-wait 'Read and fully execute ~/.hermes-pong/tasks/TASK.md. When done print exactly ##CLAUDE_DONE## then a short summary.'
```

## Soft vs hard failures

- Missing Quartz module — soft; osascript may still paste. Verify the pane.
- Shell target — hard; re-Link before retrying.

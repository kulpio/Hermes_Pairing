# CLI capabilities Pong agents should use

Pong seats run real CLIs. Use each product’s built-in shortcuts so you can spawn subagents, plan, interrupt, and manage context without waiting for a human to click.

---

## Claude Code (`claude`)

### Slash commands (type `/` on an empty prompt)
| Command | Use when |
|---|---|
| `/agents` | Create / list / manage **subagents** (separate context + persona) |
| `/help` | List every command in this install (custom + plugins + MCP) |
| `/clear` | Wipe conversation and start fresh |
| `/compact` | Compress context when the window is huge |
| `/plan` or plan mode | Design before editing (cycle with **Shift+Tab** on many builds) |
| `/cost` | Token / usage check |
| `/model` | Switch model mid-session if available |
| `/mcp` | MCP servers / tools |
| `/keybindings` | Customize shortcuts (`~/.claude/keybindings.json`) |

### Keyboard
| Shortcut | Action |
|---|---|
| **Enter** | Submit prompt |
| **Shift+Enter** | Newline |
| **Tab** | Autocomplete `/` commands, paths, `@` mentions |
| **Ctrl+C** | Interrupt current turn |
| **Ctrl+C** twice / **Ctrl+D** | Exit when idle |
| **Ctrl+L** | Clear screen (keep history) |
| **Ctrl+R** | Reverse-search prompt history |
| **↑ / ↓** | Prompt history |
| **Shift+Tab** | Toggle plan mode (when supported) |
| **`@` + path** | Reference a file/dir in the prompt |
| **`?`** | Show shortcuts for current terminal/IDE |

### Agent habit
When a task needs parallel specialists (reviewer, researcher), prefer **`/agents`** over inventing a parallel chat outside Claude.

---

## Grok Build (`grok`)

Grok Build is the coding CLI (same login / weekly pool as SuperGrok). Prefer product UI commands when available.

### Practical controls
| Action | How |
|---|---|
| Interrupt a long turn | **Ctrl+C** in the terminal |
| Multi-line input | **Shift+Enter** or terminal paste |
| File context | Paste paths or use the product’s attach/mention UX if shown |
| Subagents / parallel work | Use Grok’s **agent / task** UI when the TUI exposes it; otherwise ask the Pong orchestrator to open another seat |

### Agent habit
Stay inside the Grok seat for implementation. Do **not** open a second Grok process by hand unless the orchestrator assigns a new Pong seat — isolation tokens depend on Pong’s window titles.

---

## Hermes Agent (`hermes chat`)

Hermes is both a valid **orchestrator** and a **worker** seat in Pong.

### Practical controls
| Action | How |
|---|---|
| Chat session | `hermes chat` (seat command) |
| Interrupt | **Ctrl+C** |
| Exit | **Ctrl+D** / product quit |
| Bridge / Pong jobs | Read bind card + `pong` CLI when BRIDGE_ON; claim with evidence |

### Agent habit
As orchestrator: route via **pong job create / check / claim** — do not implement product code while BRIDGE_ON unless policy says otherwise.  
As worker: treat job files as source of truth; use Hermes tools the same way you would in a solo session.

---

## Cross-product rules for Pong teams

1. **Isolation** — each seat has an exact Terminal title / tmux pane. Do not retitle windows.
2. **Jobs** — open work is in `~/.pong/jobs/…`. Prefer job-file status over chat guesses.
3. **Subagents of the model** (Claude `/agents`, etc.) are *inside* that seat’s context; Pong **sub-agent seats** are separate Terminals on the SUB plane. Use both when useful, but do not confuse them.
4. **When stuck** — interrupt (Ctrl+C), compact/clear if context is poisoned, then claim `failed` or ask human takeover rather than thrashing.

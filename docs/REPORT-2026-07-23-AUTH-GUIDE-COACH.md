# Report — Auth gate, sequential accounts, proactive Guide

**Date:** 2026-07-23  
**Build:** CyberPong 1.4.0 (dev) — compiles clean, installed

## Confirmed already fixed (#3)

- **3D link edits without restart** — edge signature folded into `Agent3DMapView.reload()` change detection.
- **addWorker clobber race** — write path re-reads under `PairState.mutate` and appends only the new seat.

## Decision: #2 accounts

Shipped **sequential switch first** (recommended). Concurrent per-seat isolation deferred.

## Shipped this pass

### #1 Login-via-Terminal on team/agent create

New `ProviderAuth` (`src/ProviderAuth.swift`):

- Checks CLI installed (`~/.grok/bin`, Homebrew, `~/.local/bin`, …)
- Clear install message if missing
- Opens login Terminal + **I’m signed in** modal when provider not marked ready
- Wired into:
  - `AppAIMutator.createFirstTeam` (all distinct CLI types in the plan)
  - `Workers.addWorker` (unless `skipAuth: true` after mutator already gated)
  - Mutator `addSubagent` / `addWorker` intents

### #2 Sequential Switch account

- Menu: **CyberPong → Switch AI account…**
- Setup page: **Provider accounts → Switch account…**
- Clears `provider_auth[type].ready`, reopens login Terminal, marks ready on confirm
- One active account per provider CLI for all seats of that type

### #4 Proactive Guide

**(a) Live team state in chat prompt** — `GuideCoach.teamContextBlock()` injected into `AppAIRuntime.buildPrompt` (seats, pane_id / NO_PANE, roles, edges, open jobs).

**(b) Situation detectors on 4s poll** — `GuideCoach.tick`:

- Ghost sub-agents (parent_id, no pane) → nudge + **Remove ghosts**
- Orch busy / no subs → nudge + **Add Hermes sub**
- Long-queued jobs → advisory nudge

**(c) Mutator + Apply** — intents:

- `addSubagent` / `addWorker` (real `Workers.addWorker` + auth)
- `addFlowEdge` / `removeSeat`
- Chat parses user + Guide lines and offers **Apply N changes** bar

Guide bubble also keeps disconnect → login Terminal → headless reconnect.

## Files

| File | Role |
|------|------|
| `src/ProviderAuth.swift` | Install check + login gate + switch account |
| `src/GuideCoach.swift` | Team context + poll detectors |
| `src/AppAIMutator.swift` | Spawn/edge/remove intents + chat parse |
| `src/AppAIRuntime.swift` | Team state in prompt; auth ready sync |
| `src/AppAIChatBubble.swift` | Apply / coach action bar |
| `src/MenuBarApp.swift` | addWorker auth; Switch account menu |
| `src/PanelController.swift` | Coach tick; Setup switch UI |

## How to verify

1. **New team** with Claude workers first time → login Terminal for `grok` + `claude` if not ready.  
2. **+ add Hermes sub** without Hermes ready → install message or login gate; after confirm, real tmux window.  
3. Ghost seats on map → Guide orange/green Apply “Remove ghosts”.  
4. Guide chat: “add hermes scraper under c1” → Apply strip → live spawn.  
5. **Switch AI account…** → re-auth Grok/Claude/Hermes.  
6. Edit Architecture edge → 3D repaints without restart.

## Follow-ups

- Concurrent per-seat config dirs (option 2/3 second half)
- Richer intent parse / structured APPLY from Guide only
- Mark seats without `pane_id` visually offline on 3D map always

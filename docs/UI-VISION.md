# Pong control panel — lasting design

Not a port of Hermes Pong’s list panel. Not a clone of Orchestrate AI.  
A **local orchestration surface** that can age well for months.

## Product truth

| User wants | Surface |
|------------|---------|
| See the team | **Canvas** — full stage, agents as objects |
| Know system health | **Mission** — metrics + jobs from control plane |
| Start / link | **Setup** — rare; not the home screen |

The home experience is the **canvas**, not a form.

## Layout (durable)

```
┌─ titlebar safe ──────────────────────────────────────────┐
│  Pong · team selector              status pill           │
├────┬─────────────────────────────────────────────────────┤
│    │                                                     │
│ ◎  │              PRIMARY STAGE                          │
│ ▦  │         (Canvas | Mission | Setup)                  │
│ ⚙  │                                                     │
│    │                                                     │
└────┴─────────────────────────────────────────────────────┘
```

- **Left rail** (~56pt): three destinations only. No prose. Icons + labels on hover/selected.
- **Stage**: fills the rest. Resizable window; stage reflows.
- **No permanent footer** “Refresh / Close Panel” — window chrome closes; refresh is subtle in header or auto.
- Traffic lights never collide with logo (content inset under titlebar + leading clearance).

## Visual language

**Direction:** Anduril Lattice product UI + marketing site restraint.  
Black chrome, white type, **amber CTAs**, map/canvas as hero, floating HUD panels.  
Not neon cyber, not soft SaaS purple.

| Token | Choice |
|-------|--------|
| Void | Pure black `#000` (map stage) |
| Surface | Glass-black floating panels |
| **Line work** | **White** hairlines, frames, graph edges, grid dots |
| **Orchestrator** | **Blue only** (conductor rail, icon, Open, LIVE) |
| **Agents** | **Magenta only** (worker rail, icon, Open, LIVE) |
| Human | Amber (not a seat role) |
| Type | SF Pro; large editorial titles |
| Grid | Sparse white **dots** + white corner brackets |
| Chrome | Black bars; white structure; no blue/magenta on chrome |

## Canvas

- Conductor + workers as **large cards** (icon, title, type, status pill, one primary + one secondary action).
- Bezier links conductor → workers (violet).
- Drag to layout; positions persist.
- Team switcher in header when multiple teams.
- Floating glass toolbar bottom-center or top of stage: Fit · New team · Link.

## Mission

- Page title + one-line bridge state.
- **Metric row** (4 tiles): open jobs, accept %, agents, reject streak.
- **Activity** list from events.
- **Team job boards** below — not mixed into canvas.

## Setup

- Short, calm onboarding: New team, Link, Saved teams.
- Explain canvas once; no walls of tip text.

## Interaction principles

1. Click agent → Open terminal (primary).
2. Drag = arrange; never accidental.
3. Data from `pong snapshot` / pairs — UI never invents job state.
4. Prefer empty states that invite one action.

## Non-goals (for this generation)

- In-canvas marketplace / agent store
- Live token streaming panels
- Cloning third-party sidebar libraries
- Cramped multi-button tree rows from v1 Hermes Pong

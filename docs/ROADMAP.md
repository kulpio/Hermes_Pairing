# Pong roadmap — where we are

**Product:** Local multi-CLI agent mission control (canvas + jobs + human override).  
**Not the whole product yet** — solid spine, still mid-build.

**Long-term angle:** live layer of a broader access-control plane (session policy today → principal/grant/geo later). Naming and copy rules: [`NORTH-STAR-AGENT-HANDOUT.md`](NORTH-STAR-AGENT-HANDOUT.md). Do not expand v1 scope into standing registry/Umbra features unless a human job says so.

## Done (foundation + usable shell)

| Area | Status |
|------|--------|
| Job control plane (`pong job`, snapshot, events, ledger) | ✅ |
| Conductor-agnostic teams (Grok / Hermes / …) | ✅ |
| Canvas: drag nodes, multi-team, labeled edges + **arrows** | ✅ |
| Early north-star copy (seats, Policy, Session access policy) | ✅ |
| + docked on conductor / worker edges | ✅ |
| Focus inspector (task flow digest + terminals) | ✅ |
| Dual accents (blue / magenta / orange human) | ✅ |
| Menu dual-dot live states | ✅ |
| Link flow: Orchestrator-first | ✅ |

## In progress / next (to feel “done” for v1)

1. **Anduril design system** — black void, white line work, blue orch / magenta agents ✅  
2. **3D constellation map** — named plotlines, arrows, packets, TRACKING list, legend, module popup, dotted sphere ✅ ([UI-3D-MAP.md](UI-3D-MAP.md))  
3. **Flat canvas** — pan/zoom/snap grid, rename, 2D/3D toggle ✅  
4. **Mission / Setup** — digest, Focus CTAs, job → canvas highlight ✅  
5. **Team install wizard** — names, roles, policy, SOUL/SKILL/TEAM scaffold ✅  
6. **Subagent hierarchy** — `parent_id` on add-subagent → 3D SUB layer ✅  
7. **Job create from Focus** — New job → `pong job create --no-paste` ✅  
8. **Reliability** — add-worker edge cases, window id recovery, crash recovery  
9. **Ship** — notarized build, short demo video, docs for “day 1”

## Later (v1.x+)

- Drag orbs in 3D / temporal plotlines  
- Photon notify from Focus  
- Plugin slots (custom dashboards)  
- Headless worker runner UI  

## North star (final goal)

> One window: see every team, see work flowing (arrows + jobs), intervene in a real terminal when needed, without treating paste-RPC as truth.

**Rough completeness:** ~80% of that v1 north star. Isometric 3D + flow_graph + arch canvas + window recovery + Focus jobs; ship remaining.

### Design push (isometric blueprint)

| Item | Status |
|------|--------|
| Lime schematic chrome (`PongSheetChrome`) | ✅ |
| 3D stacked decks + tile seats (not orbs) | ✅ |
| `flow_graph` editable topology | ✅ |
| Architecture canvas in wizard | ✅ |
| Window id recovery on poll | ✅ |
| Mission/Setup plate reskin | ✅ |

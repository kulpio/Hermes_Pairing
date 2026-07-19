# Pong roadmap — where we are

**Product:** Local multi-CLI agent mission control (canvas + jobs + human override).  
**Not the whole product yet** — solid spine, still mid-build.

## Done (foundation + usable shell)

| Area | Status |
|------|--------|
| Job control plane (`pong job`, snapshot, events, ledger) | ✅ |
| Conductor-agnostic teams (Grok / Hermes / …) | ✅ |
| Canvas: drag nodes, multi-team, labeled edges + **arrows** | ✅ |
| + docked on orchestrator / worker edges | ✅ |
| Focus inspector (task flow digest + terminals) | ✅ |
| Dual accents (blue / magenta / orange human) | ✅ |
| Menu dual-dot live states | ✅ |
| Link flow: Orchestrator-first | ✅ |

## In progress / next (to feel “done” for v1)

1. **Canvas polish** — zoom/pan, fit all teams, clearer selection  
2. **Subagent hierarchy** — real parent/child workers (not peer-only)  
3. **Job ↔ canvas** — select job highlights edge/node; create job from Focus  
4. **Mission page** — parity with Focus (same digest, filters)  
5. **Human loop** — orange path when claim fails / needs input, one-click Focus  
6. **Reliability** — add-worker edge cases, window id recovery, crash recovery  
7. **Brand/pass** — remaining Hermes strings, onboarding rewrite  
8. **Ship** — notarized build, short demo video, docs for “day 1”

## Later (v1.x+)

- Editable edge labels / custom flow graph  
- Photon notify from Focus  
- Plugin slots (custom dashboards)  
- Headless worker runner UI  

## North star (final goal)

> One window: see every team, see work flowing (arrows + jobs), intervene in a real terminal when needed, without treating paste-RPC as truth.

**Rough completeness:** ~55–60% of that v1 north star. Control plane + canvas shell are real; depth of job UX and hierarchy still open.

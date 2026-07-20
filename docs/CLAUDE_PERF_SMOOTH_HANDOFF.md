# Claude + Grok — make Pong usable/smooth (perf throw-down)

**Date:** 2026-07-20  
**Repo (canonical):** `/Users/dylandemnard/Personal/Projects/HermesPong`  
**NOT Umbra.** Explicit scope override.

## User report
- Spinning beachball / lag on **window click, orbit, drag**
- Human should **not** glow as a solid — subtle **light behind** the shape only
- Shapes: **tiny** see-through (glass), not hollow cages
- Work with Grok: audit + prioritized surgical fixes

## Known costs (Grok starting now)
1. `PanelController` poll **every 2.5s** → full `map3D.reload` → `layoutSeats`
2. HDR + bloom while orbiting (MSAA 2X)
3. `renderer updateAtTime` still runs material writes every frame for active seats
4. Menu bar Timer 0.1s

## Ask Claude
Read: `src/Agent3DMapView.swift`, `src/PanelController.swift` (reload/poll), `src/MenuBarApp.swift` (0.1s timer).

Write **`docs/CLAUDE_PERF_SMOOTH_VERDICT.md`**:
1. Ranked top 5 main-thread / GPU killers with function names
2. Surgical fixes (no map rewrite)
3. What Grok should NOT touch
4. Verification: orbit 10s without beachball; idle GPU near zero

Findings only from you. Grok implements in parallel and will merge your list.

## Grok shipping immediately (don’t regress)
- Human: matte edges; soft amber **behind** disc only
- Body: slight glass (~0.88–0.92 SceneKit transparency)
- Perf: poll smart-diff; MSAA none; HDR/bloom off or minimal; poll interval 4s; menu timer 0.5s

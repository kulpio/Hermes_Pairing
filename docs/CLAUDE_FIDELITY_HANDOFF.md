# Claude fidelity audit — live Pong vs design reference (side-by-side)

**Date:** 2026-07-20  
**Repo:** `/Users/dylandemnard/src/Agent-Pong` (**NOT Umbra** — explicit scope override)  
**Ask:** Findings only first. Write `docs/CLAUDE_FIDELITY_VERDICT.md`. Grok will implement immediately after.

## Images (study pixel-precisely)

Side-by-side screenshot (LEFT = live Pong, RIGHT = design Figma/HTML target):

```
/Users/dylandemnard/.grok/sessions/%2FUsers%2Fdylandemnard/019f7878-c430-7461-a983-435b6e160322/assets/image-3f59a32e-47a2-45ec-92a4-7c60c12078eb.jpg
```

Also open if available: design HTML under `docs/design-handoff-agent-map/` and `SWIFT_GUIDE.md` + `README.md` tokens.

**Method:** Open the screenshot. List every visual delta LEFT vs RIGHT (style, color, shading, glow, shape fill vs wire, edge faintness, plane tint, links, HUD, YOU marker, faces, timeline). Then map each delta to code in `Agent3DMapView.swift` / `PongTheme.swift` / `PanelController.swift`. Prioritize P0 surgical fixes.

## Grok’s first-pass visual read (verify / correct / extend)

| Area | LEFT (live) | RIGHT (design) | Likely code |
|------|-------------|----------------|-------------|
| Node body | Near-black solid or empty cage; edges dominate | Soft dark fill `#0a1016` @**0.82**, reads as solid | `mapNodeBody` α=1.0; `unlitBody` |
| Edge lines | Bright neon cages, thick look | **Very faint** thin accent edges | `unlitEdge` idle 0.32 + active emission 0.85 too strong |
| See-through | Still cage-like; interior/far edges pop | Faint EdgesGeometry only; body blocks interior | body α + edge α balance |
| Info faces | Often missing / hard to read | Clear Anduril panel on front | face materials / size |
| Planes | Hot cyan/magenta plates | Tint opacity **0.03**, soft | plate α 0.045 + transparency 0.88 |
| Links | Bright white/pink lasers | Quiet idle 0.32, active 0.85 | `connect` line alpha |
| YOU / human | Small dim octa | Warm amber glow octa above stack | human materials / bloom |
| Ground rings | Present when live | Soft pulse on plane | `planeRings` |
| Bloom | Harsh / uneven | Soft camera bloom only | bloomIntensity 0.4 / threshold 0.5 |
| TRACKING HUD | SEATS/LINKS counts left | KPI tiles 4/4/1 + clean list | tracking panel layout |
| Timeline | White-ish dots | Magenta/pink bead trail | ruler colors |
| Density | Multi-team clutter | Single team calm | multiTeam layout |

Design tokens (README): body `#0a1016`@0.82; plane fill opacity **0.03**; grid `#2a3742`@0.55; rim@0.32; brackets@0.55; range ring@0.07; idle link 0.32 / active 0.85.

## Window / UI lag (separate but ship with fidelity)

User: **moving and resizing the Pong window lags hard.**

Suspects to confirm in code:
- `scnView.isPlaying = true` always on canvas + 20fps pulse Timer always running
- `layout()` on `Agent3DMapView` → `layoutRightHUD()` every layout pass (fires continuously during live resize)
- MSAA 2X full scene during drag
- No pause of SceneKit during `NSWindow.didResize` / live resize
- Poll 2.5s → `layoutSeats` while user is resizing

Propose surgical: pause `isPlaying` + pulse during live resize; debounce HUD layout; lower `preferredFramesPerSecond` when idle; `rendersContinuously` only when map needs animation.

## Key code

- `src/Agent3DMapView.swift` — `buildDotSphere`, `placeBlob` (hex-v5), `unlitBody`/`unlitEdge`/`unlitFace`, `connect`, `startPulse`, `layout()`, bloom in `setupScene`
- `src/PongTheme.swift` — map tokens
- `src/PanelController.swift` — window layout, canvas

## Output format (`docs/CLAUDE_FIDELITY_VERDICT.md`)

1. **TL;DR** — top 5 deltas that make LEFT ≠ RIGHT  
2. **Pixel/visual catalog** — ordered list with severity  
3. **Code map** — each delta → function + current vs target values  
4. **P0 surgical fix list** for Grok (exact numbers where possible)  
5. **Lag P0s** — resize/move freezes  
6. **Do-not-regress** from prior audits  
7. Verification checklist  

**No code changes from you** — findings only. Print short TL;DR when file is saved.

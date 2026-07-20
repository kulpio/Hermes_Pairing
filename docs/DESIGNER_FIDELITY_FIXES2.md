# Designer fidelity + perf brief — Agent3DMapView (post-audit)

Reviewed against the HTML prototype (`docs/design-handoff-agent-map/`) and the current Swift. The pass-2 audit fixes have landed (don't regress them). What remains splits into **why it's still laggy** and **why it still doesn't look the same**. All fixes are surgical and local to `src/Agent3DMapView.swift` + `src/PongTheme.swift`.

---

## A. Laggy / "slow to react"

### A1 — The scene renders continuously even when nothing is happening  *(biggest GPU/battery cost)*
`setupScene()` sets `scnView.isPlaying = true` and never turns it off (except `setMapPlaying(false)` for Mission/Setup). With `wantsHDR + bloom + MSAA 2X`, that's a full 60 fps HDR pass **forever**, including the common "queue clear / all idle" state where nothing moves.

**Fix — render on demand.** Keep `isPlaying = true` only while something actually animates:
- any seat where `isSeatActive(s)` (bob + packets), OR
- an in-flight gesture (orbit/pan/zoom, Move drag, ruler drag), OR
- `rulerDirty`.

When none hold, set `isPlaying = false`. Re-enable it (set true) at the start of every gesture handler and whenever `reload()`/state changes bring an active seat online. On an all-idle team this drops the map from 60 fps to ~0 — the single biggest win.

### A2 — Motion is driven by a 20 fps `Timer`, not the render loop  *(stutter + wasted frames)*
The class conforms to `SCNSceneRendererDelegate` and sets `scnView.delegate = self`, but there is **no `renderer(_:updateAtTime:)`** — motion lives in `startPulse()`'s `Timer` at `1/20 s`. So SceneKit renders at 60 fps while bob/yaw update at 20 fps → visibly steppy, and 40 of every 60 frames are identical (pure waste on top of A1).

**Fix — move the pulse body into the render loop.** Implement:
```swift
func renderer(_ r: SCNSceneRenderer, updateAtTime t: TimeInterval) { advancePulse(now: t) }
```
Drive `pulsePhase` from the real `time` delta (not `+= 0.085`), port the existing per-seat bob/yaw/ring/edge-breath loop into `advancePulse`, and **delete the `Timer`**. It fires every rendered frame *including during gestures* (that was the original "slow to react" freeze), and pairs perfectly with A1 (no render → no update → no cost). Keep the ~8 s `reloadCronTimeline()` throttle on a plain low-frequency timer or a `time`-based gate.

### A3 — Secondary
- `preferredFramesPerSecond` is only lowered during live-resize. With A1+A2 you can cap the map at 30 fps for its slow bob/pulse (the reference motion is calm) and halve steady-state GPU with no visible loss.
- MSAA 2X + HDR bloom are fine to keep **once A1 lands** — they only cost while actually rendering.

---

## B. Doesn't look the same

### B1 — Wrong typefaces  *(the strongest "feel" miss)*
`PongTheme.font/labelFont` return `NSFont.systemFont` (SF Pro) and `PongTheme.mono` returns SF Mono/Menlo. The design — and `SWIFT_GUIDE.md` explicitly — call for **Space Grotesk** (display/UI) and **IBM Plex Mono** (data/HUD/faces). The technical grotesk + mono pairing is core to the Anduril read; SF Pro makes every panel and baked face look generic.

**Fix:** bundle the two font families, register at launch (`CTFontManagerRegisterFontsForURL` or Info.plist `ATSApplicationFontsPath`), and return them from `PongTheme.font` (Space Grotesk) and `PongTheme.mono` (IBM Plex Mono) with graceful fallback. This one change re-skins the whole HUD **and** the baked cube faces (they use these same helpers).

### B2 — Only the "coder" glyph exists  *(role glyphs are the whole point)*
In `cubeFaceImage(...)`, the glyph switch draws concentric circles for `conductor`, a figure for `human`, and `"{  }"` for **everything else**. So researcher / delegate / auditor / operator agents all render braces — the distinct role glyphs the user specifically asked for are missing.

**Fix:** switch on `s.resolvedMission` (you already compute it) and draw the geometric glyphs from the design/`SWIFT_GUIDE`:
- coder → `{ }` (keep)
- researcher → magnifier (circle + handle)
- delegate → branch (dot → two diverging strokes → two end dots)
- auditor → check inside a circle
- orchestrator → concentric rings (keep), human → figure (keep)
Same white `#EEF4F7`, ~4px stroke, top-left of the face. Pure Core Graphics, no new assets.

### B3 — Bloom is present but conservative *(optional, to taste)*
`bloomThreshold 0.62 / intensity 0.22` with edges emissive only is close, but the reference reads a touch more neon on **active** edges/rings. If it still looks flat next to the HTML, nudge active-edge emission toward `full.withAlphaComponent(0.6)` and intensity ~0.3. Keep faces/bodies matte (`emission = .black`) so text stays crisp — do **not** bloom the faces.

### B4 — Verify (not confirmed)
- Human octahedron face (`octahedronWithFrontFace`) spans the image across two facets — confirm "YOU"/name doesn't kink at the seam; if it does, shrink the panel to the single largest front facet.

---

## Priority
1. **A1** on-demand rendering — kills idle lag/battery.
2. **A2** render-loop pulse (delete Timer) — smooth 60 fps + no interaction freeze.
3. **B1** bundle Space Grotesk + IBM Plex Mono — biggest visual-fidelity jump.
4. **B2** per-mission glyphs.
5. **B3/B4** bloom polish + human-face check.

## Verify
- [ ] Idle team (queue clear): map stops rendering (Instruments GPU ≈ 0), no 60 fps spin.
- [ ] Orbit/pan/scroll: bob/yaw/packets move *during* the gesture at 60 fps, no step or freeze.
- [ ] Panels + faces render in Space Grotesk / IBM Plex Mono, not SF.
- [ ] A researcher, a delegate, and an auditor seat each show distinct glyphs (not braces).
- [ ] Active edges/rings read neon against the dark planes; faces stay crisp.

---

## C. Exact color / opacity / shape / line deltas

Role hexes are actually **correct** (`PongTheme.blue/magenta/violet/amber` == `#35d6ff / #ff53c8 / #a98bff / #ffb43a`). The "everything's a bit off" comes from these value drifts, not the palette:

| Element | Prototype (HTML) | Current Swift | Fix |
|---|---|---|---|
| **Background void** | deep blue-black radial `#0b131b → #06090d` + edge vignette | `mapVoid` dark = pure `#000000` (`calibratedWhite 0.0`) | set void to ~`#06090d`; the flat black kills the depth/tint |
| **Distance fog** | none (CSS vignette only) | `scene.fog` start 42 / end 95 in the void color | push fog way out (start ~80) or remove; it's softening the far plane edges + labels into grey. Add a subtle radial vignette layer instead |
| **Node body opacity** | `#0a1016` @ **0.82** (slight glass) | `unlitBody` forces alpha **1.0** | design reads as tinted glass; if the audit's opaque was to stop see-through backs, keep single-sided + depth but drop to ~0.9 |
| **Silhouette edges (idle)** | bright accent, ~0.8–1.0 | `unlitEdge` idle diffuse **0.28**, emission black | edges are the main color carrier — 0.28 is why it looks washed/"less colorful". Raise idle to ~0.6, active to ~0.85 |
| **Silhouette edges (active)** | full accent + glow | diffuse 0.55 / emission 0.12 | raise diffuse ~0.85, emission ~0.5 so bloom fires (ties to A/B3) |
| **Flow line — idle** | `opacity 0.32` | `originCol` @ **0.22** | 0.32 |
| **Flow line — active** | `opacity 0.85` + pulse | **0.55** + packet | 0.85 |
| **Flow line weight** | 1px hairline | SCNCylinder r 0.006–0.012 (reads as a tube) | thin to ~0.004–0.006 so it reads as a drawn line, not a rod |
| **Flow arrowheads** | none — plain line + traveling pulse | adds `SCNCone` arrowheads on every edge | the prototype has no arrowheads; drop them (or make tiny) for the clean look |
| **Deck level label** | upright HUD tab `01 · ORCHESTRATOR` at near corner | baked plane laid **flat on the floor** with `mat.transparency = 0.08` → **~invisible** | **bug**: `transparency` 0 = invisible in SceneKit; set opaque (`transparency = 1`/remove). Also billboard it upright instead of flat-on-deck |
| **Glow** | additive sprite @0.16 | removed → bloom | fine, but only works once edges are emissive (above) |

### Net
The scene looks "off" mostly because (1) the void is pure black instead of the blue-black gradient, (2) fog is greying the far planes, (3) **edges/lines are running at ~⅓ the prototype's opacity** so color barely shows, and (4) the level-label `transparency = 0.08` bug hides the plane labels. Fixing those four brings the color/contrast back to the reference; the emissive-edge + bloom pair (B3) then supplies the neon.

---

## D. Round 2 — from the latest build screenshot

The shapes now render as **hollow wireframes with no fills and no info cards**. That is one bug, plus four smaller matches.

### D1 — 🔴 THE bug: `transparency = 0` makes the bodies + faces invisible
In `unlitBody(...)` and `unlitFace(...)` the materials set `m.transparency = 0`. **In SceneKit `transparency` is 0 = fully transparent, 1 = opaque** (the opposite of "alpha 0"). So every solid body wall and every baked info-face panel is being drawn 100% invisible — you only see the `shell` edge lines. This is exactly why the cubes look see-through and the info cards vanished.

**Fix:** set `m.transparency = 1` (or delete the line) in `unlitBody` and `unlitFace`. One line each — restores solid shapes **and** the info faces at once. (Same gotcha as the `deck label transparency = 0.08` in C — sweep the file for every `transparency =` and confirm 1 = opaque intent.)

After that, to match the prototype's "tinted glass" read, keep body walls opaque `#0a1016` and let the **bright info-face panel + accent edges** carry the look (that's what makes the prototype shapes feel solid, not the body alpha).

### D2 — No glow on the human (YOU) octahedron
Once D1 restores its face, raise the beacon: octa edge `emission` → amber ~0.6, the `youHalo` tube `emission` → amber ~0.35, and drop `camera.bloomThreshold` to ~0.5 so amber actually crosses it. Human is the one shape that should clearly bloom.

### D3 — Info card must fit the face (esp. triangle)
Bake the face panel to **each shape's actual front-face rectangle** and inset it ~6% so it sits *inside* the silhouette, never larger than the face:
- Cube: front +Z wall (fine as-is once D1 lands).
- Hex (orchestrator): the +Z wall is wide → card looks contained (reference).
- **Tri (sub-agent): map the card to the single front wall of the prism and match that wall's width/height** — right now it reads oversized. Keep the same visual size ratio as the orchestrator card relative to its face.
- Human octa: put the card on the **single largest front facet**, not spanning two (the two-facet split both distorts text and oversizes it).

### D4 — "+" pads: smaller, floating, no overlap
Currently the disc (`makePlusDisc`, r = 0.32) sits at `plusX` 1.15–1.55 — touching/overlapping the body. Make it **r ≈ 0.2**, push it out by another ~0.4–0.5 world units so there's a clear gap, lift it to mid-height, and give it an `SCNBillboardConstraint` so it always faces the camera (right now it's locked to +X and clips into the shape when you orbit). It should read as a small floating pad beside the shape.

### D5 — App chrome buttons don't match the prototype
The bottom toolbar, mode chips, and rail still use SF Pro and default bezels. Match the prototype tokens (also fixed by B1 fonts):
- Toolbar/pills: bg `rgba(9,13,17,0.82)`, 1px border `rgba(130,150,160,0.16)`, radius 6, **Space Grotesk** labels, letter-spacing ~0.06em.
- Active tab (e.g. Orbit): bg `rgba(255,255,255,0.08)` + border `rgba(150,165,175,0.28)`; inactive = transparent, muted `#9aa7ae` text.
- Primary ("New team"): solid `#eef4f7` bg, dark `#0a0f14` text. "Design flow…" = subtle white-8% fill.
- Match padding/height (34px) and gaps (4–6px) so it reads as one glass bar, not native buttons.

### Round-2 priority
1. **D1** `transparency = 1` — brings back solid shapes + info cards (the big one).
2. D3 face-fits-face (triangle + human facet).
3. D4 floating smaller "+".
4. D2 human glow.
5. D5 chrome tokens (with B1 fonts).

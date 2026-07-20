# Claude fidelity verdict — live Pong (LEFT) vs design (RIGHT)

**Reviewer:** Claude (second-eye) · **Date:** 2026-07-20 · **Findings only — no code changed.**
**Studied:** the side-by-side screenshot pixel-by-pixel, `SWIFT_GUIDE.md`, README tokens, and the live post-v5 tree (`Agent3DMapView.swift`, `PongTheme.swift`, `PanelController.swift`).

## 1. TL;DR — the 5 deltas that make LEFT ≠ RIGHT

The single root cause is **v5's neon pass overshot**: emission was added to almost everything and bloom widened, so the whole scene glows. The design is **calm, dark, matte** with glow reserved for the YOU marker and one or two active links. Ranked:

1. **Everything is emissive → harsh neon.** Active node edges `emission 0.85`, plane rims/grid emissive, links bloom to white/pink lasers. Design: only YOU + active elements glow, softly. *(This is the bloom-blowout risk I flagged when approving P1-C — it materialized.)*
2. **Nodes read as hollow glowing cages**, not soft-filled solids. The body IS opaque now (`#0a1016 @1.0`), but the blazing edges over a near-black body against a near-black bg read as wireframe. Faint edges are what let the solid read.
3. **Plane plates are hot/saturated**, not whisper tint. They're built as a **double-sided `SCNBox`** (6 faces stack the tint) plus emissive rims/brackets — effective opacity ~4× the intended 0.03.
4. **YOU/human is a dim small octa**, not the warm amber beacon floating above the stack with a soft radial halo + "HUMAN OPERATOR."
5. **TRACKING is a text dump + multi-team clutter.** LEFT shows the in-map `refreshTrackingList` text ("SEATS 8 LINKS 10 HUMAN 1") over 3 stacked teams; RIGHT is clean KPI tiles (4/4/1) + aligned list, single team.

Plus a separate **window move/resize lag** cluster (no live-resize pause; v5's `.common` pulse now also runs *during* resize).

## 2. Pixel / visual catalog (ordered by severity)

| # | Delta (LEFT → should be RIGHT) | Severity |
|---|--------------------------------|----------|
| 1 | Active node edges blaze (emissive cages) → very faint thin accent edges | **P0** |
| 2 | Bloom washes edges/links/planes broadly → soft bloom on YOU + active only | **P0** |
| 3 | Node interior reads empty/see-through cage → soft dark solid reads filled | **P0** |
| 4 | Planes hot cyan/magenta/violet plates → barely-there ~0.03 tint | **P0** |
| 5 | Links are bright white/pink lasers → quiet idle 0.28 / soft active | **P0** |
| 6 | YOU octa dim → warm amber beacon w/ soft radial halo, floats above stack | **P1** |
| 7 | TRACKING text list → KPI tiles (SEATS/LINKS/HUMAN) + clean aligned list | **P1** |
| 8 | Multi-team clutter ("3 teams live") → single calm team ("1 TEAM LIVE") | **P1** |
| 9 | Timeline beads read whitish → magenta bead trail (agents accent) | **P1** |
| 10 | Plane rims/corner brackets/grid glow → matte, no emission | **P1** |
| 11 | Floating translucent panels over map (YOU/TASKS/CRON) → docked opaque cards; LEGEND clean swatch panel top-right | **P2** |
| 12 | Info faces hard to read → clear Anduril panel (will improve once edges/bloom drop) | **P2 (verify after 1–5)** |

## 3. Code map — delta → function → current vs target

| Delta | File · function | Current | Target |
|-------|-----------------|---------|--------|
| Edge glow (1,3) | `Agent3DMapView.unlitEdge` | active `diffuse 0.95 + emission 0.85`; idle `diffuse 0.32 emission black` | active `diffuse ~0.55 + emission ~0.10–0.15`; **idle unchanged** (0.32/black is right) |
| Bloom breadth (2) | `Agent3DMapView setupScene` (~650) | `bloomIntensity 0.4`, `bloomThreshold 0.5` | `bloomIntensity ~0.22`, `bloomThreshold ~0.62` (only pixels brighter than the amber/active accents bloom) |
| Plane tint (4) | `buildDotSphere` plate (~850) | **`SCNBox` double-sided**, `diffuse accent@0.045`, `transparency 0.88` | single flat **`SCNPlane`** (one face, not a box), `diffuse accent@0.03`, `emission black`, not double-sided |
| Plane rim/brackets/grid (10) | `buildDotSphere` (~896/948/980) | `emission accent@0.15–0.2`, grid `emission @0.08` | `emission black` (or ≤0.04); keep faint diffuse (rim@0.32, grid@0.45) |
| Links laser (5) | `connect` `lineCol` (~3xxx) | active `0.75` / idle `0.28`, emission black (but bloom washes to white) | active `~0.55` / idle `~0.22`; consider thinner radius; keep emission black; **rely on lower bloom** |
| Packets (5) | `connect` packet `pmat` | `emission pc@0.35` | `emission pc@~0.12` or black |
| Body (3) | `unlitBody` / `mapNodeBody` | opaque `#0a1016 @1.0` | keep opaque (blocks interior — good); design @0.82 is optional. **The body already reads solid once edges/bloom drop** — don't chase alpha, chase edges |
| YOU beacon (6) | human case in `placeBlob` (~3008), `yHuman=17` | octa + amber emissive shell, **no halo** | add a soft amber radial: emissive amber disc (`SCNPlane`/tube, `diffuse amber@~0.10`, r~3) on the plane under the octa so bloom halos it; keep octa emissive; verify "HUMAN OPERATOR" label present |
| Tracking (7) | `Agent3DMapView.refreshTrackingList` (2035) renders text; `PanelController` (~1141) already has "KPI 4-up" | in-map **text overlay** is what's showing | render tracking as the **KPI-tile panel** (PanelController's 4-up already exists) + aligned list w/ square bullets, right-aligned status; hide the text overlay |
| Multi-team (8) | `reload(seats:multiTeam:)` | shows all teams stacked | default single-team focus; multi-team is opt-in (matches "1 TEAM LIVE") |
| Timeline beads (9) | ruler occurrence dots (~1800) | `col = CronSchedule.accent(forOwnerId:)` → resolves light for some owners | ensure owner→role color maps to **magenta** for agents; the design trail is the agents-plane magenta |

**Token check (`PongTheme`):** `mapNodeBody #0a1016@1.0` ✅, `mapGrid #2a3742` ✅, role colors match README (blue `#35d6ff`-ish, magenta `#ff53c8`, violet `#a98bff`, amber `#ffb43a`) ✅. Tokens are correct — the problem is **emission + bloom + plane geometry**, not the palette.

## 4. P0 surgical fix list (style) — exact numbers

1. **`unlitEdge` active:** drop `emission` `0.85 → ~0.12`, `diffuse` `0.95 → ~0.55`. Leave idle as-is. *(Kills the cage/laser look; makes solids read.)*
2. **Bloom:** `bloomIntensity 0.4 → ~0.22`, `bloomThreshold 0.5 → ~0.62`. *(Soft, selective glow.)*
3. **Planes:** replace the double-sided `SCNBox` plate with a single flat `SCNPlane` (rotate −90° X), `diffuse accent@0.03`, `emission black`, single-sided. *(Removes the 4× face-stacking hot plates.)*
4. **Plane rim / brackets / grid:** set `emission = black` (or ≤0.04). Keep the faint diffuse values. *(Stops the plane frame from blooming.)*
5. **Links:** `connect` active `0.75 → ~0.55`, idle `0.28 → ~0.22`; packet `emission 0.35 → ~0.12`. *(Quiet flow, no lasers.)*
6. **Keep faces & bodies non-emissive** (already true) — do NOT add emission to `unlitFace`/`unlitBody`; that's the readability guardrail.

**Ship 1–4 first** — they carry ~80% of the LEFT→RIGHT gap. 5 next. 6 is a "don't regress."

## 5. Lag P0s — window move / resize freezes

**Root cause:** there is **no live-resize handling anywhere** (no `viewWillStartLiveResize`/`inLiveResize` guard — confirmed by grep). During a live window resize/move, all of this runs every tick:
- `SCNView` re-renders the **full HDR + bloom scene** (`isPlaying = true`, MSAA 2X) on every resize step.
- The **v5 `.common`-mode pulse Timer now fires *during* resize** (pre-v5 it was `.default` and paused) — mutating every seat's transform + materials while you drag the window edge.
- `layout()` → `layoutRightHUD()` re-frames the HUD panels every layout pass (continuous during live resize).

**Surgical fixes:**
1. **Pause SceneKit during live resize.** Add:
   ```swift
   override func viewWillStartLiveResize() { super.viewWillStartLiveResize(); isResizing = true; scnView.isPlaying = false }
   override func viewDidEndLiveResize()   { super.viewDidEndLiveResize();   isResizing = false; scnView.isPlaying = true; layoutRightHUD() }
   ```
2. **Skip the pulse during resize.** In the pulse Timer closure, early-out on `guard !self.isResizing, self.window?.inLiveResize != true else { return }`. Keeps v5's orbit animation but stops per-frame mutation while dragging the window. *(This is the key one — it undoes the resize side-effect v5 introduced by moving the timer to `.common`.)*
3. **Debounce HUD relayout.** In `layout()`, when `inLiveResize`, only reposition (the cheap NSRect math is fine) but skip any rebuild; do a single full `layoutRightHUD()` in `viewDidEndLiveResize`.
4. **Optional:** lower `preferredFramesPerSecond` (e.g. 30) while `isResizing`, or drop MSAA to `.none` during resize and restore after.

Order: **fix 2 first** (removes the biggest new cost), then 1, then 3.

## 6. Do-not-regress (verified correct in the current tree — keep)

- Face-on-solid: `regularPrism(frontFace:)` +Z-native facet + UVs; cube SCNBox material[0]; `octahedronWithFrontFace`.
- `.line`-primitive silhouette edges (`lineGeometry` family) — no diagonals.
- `syncPlaneRing`/`planeRings` deck-plane rings (siblings, don't bob).
- `placeBlob` reuse path (x/z + baseY only; pulse owns Y).
- `edgeSignature`/`edgeSigs` diff (keeps packet SCNActions alive).
- `pointCloudGeometry` décor; `faceImageCache` + its content key; `updateBlobMaterial` early-out.
- `openAttachSession` trap/marker-close (no `exec`).
- `Timer .common` pulse (keep for orbit) — just add the `isResizing` early-out.
- `unlitBody` opaque/single-sided/depth-writing (this is what blocks interior — keep it; the cage look is edges, not this).

## 7. Verification checklist for Grok after fixes

- [ ] Screenshot the same scene: node solids read **filled and matte**, edges are faint thin accents (not cages).
- [ ] Only the YOU marker and genuinely-active links/rings glow; idle nodes/links/planes are matte.
- [ ] Planes are a whisper of color (~0.03), no glowing plate/rim; grid dots faint, non-glowing.
- [ ] YOU octa reads as a warm amber beacon with a soft halo, floating above the orchestrator plane, labelled.
- [ ] TRACKING is KPI tiles (SEATS/LINKS/HUMAN) + a clean aligned list; single team by default.
- [ ] Info faces are clearly readable now that edges/bloom dropped.
- [ ] Timeline bead trail reads magenta (agents accent).
- [ ] Drag-resize and drag-move the window: smooth, no freeze (SceneKit paused + pulse skipped during live resize).
- [ ] Regression: faces still square under orbit; attach still self-closes; packets still traverse fully.

---

*Saved to `docs/CLAUDE_FIDELITY_VERDICT.md`. Findings only — no code changed. Scope: Agent-Pong under explicit operator override (not Umbra).*

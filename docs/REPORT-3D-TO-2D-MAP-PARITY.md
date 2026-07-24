# CyberPong — Bringing the 3D map's "windows" & capabilities to the 2D map

**Audience:** the coder implementing 2D↔3D parity.
**Date:** 2026-07-22.
**TL;DR:** The 3D map's "windows" are **not 3D at all** — they're plain AppKit `NSView` panels bound to shared data that merely happen to be parented to `Agent3DMapView`. So the right move is **not** "re-draw the windows in 2D" — it's **lift them onto the shared container so one HUD serves both maps.** Only two things need genuinely new 2D rendering: **animated flow dots** and a **seat glow halo**. Everything else is re-parenting or already exists.

Files referenced (all under `src/`): `Agent3DMapView.swift` (3D, ~240KB), `AgentCanvasView.swift` (2D, ~52KB), `PanelController.swift` (host/swap), `AppAIChatBubble.swift`, `MapCoachMarks.swift`, `SeatActivity.swift`, `FlowGraph.swift`, `TeamArchCanvas.swift` (a 3rd, editor-only 2D canvas).

---

## 1. Assessment — what I think of the 3D "windows"

The overlay windows are: a left HUD column of **TRACKING → YOU (human console) → CRON → TASKS**, plus a top-right **LEGEND**, a floating **hover HUD**, a click **module card**, the **"+" add menu**, a **right-click context menu**, the **Guide sparkle bubble**, and first-run **coach marks**.

**What's good (and load-bearing for the port):**
- **They're pure AppKit, data-driven, and SceneKit-independent.** Every panel reads `snapshot.json` / `pairs.json` (`PairState`) / `FlowGraph` / `CronSchedule` / `SeatActivity` / `HumanConsoleController` / the in-memory `seats` array — never the scene. They're added as subviews *above* the `SCNView`, not owned by it (`Agent3DMapView.swift:284-286`, HUD column `setupLeftHUDScroll` `:1196-1226`).
- **One data build feeds both maps already.** `PanelController.refreshCanvas` builds `[AgentNodeModel]` (2D) and `[Seat3D]` (3D) from the same snapshot loop and calls one or the other (`PanelController.swift:1039, 1236`). The plumbing for a shared HUD is basically already there.
- **The YOU console is real, not a stub** — orch picker, per-team chat via `HumanConsoleController.deliver`, and a genuine ask-decision row (Deny / Accept once / Always) wired to `respondToAsk` (`Agent3DMapView.swift:1275-1464, 1894-1925`). That's the most valuable window and it carries over untouched.
- **`AgentNodeView` is already shared** — the 3D click-to-expand "module card" *is* the 2D canvas's node class (`Agent3DMapView.swift:3130`). Same component, two hosts.

**What's weak / worth fixing while you're in here:**
- **They're 3D-only by accident of hosting, not by design.** Nothing about TRACKING/YOU/CRON/TASKS is threedimensional; they're stranded in the 3D view purely because that's where they were built. This is the core problem to fix.
- **The left HUD is a fixed ~240px column** that permanently eats map width and is always-on (no collapse for the column as a whole, only per-panel). On the 2D canvas that real-estate cost is more noticeable.
- **Coach marks hard-anchor to HUD y-positions** (`MapCoachMarks.swift:8-29, 64-71`) — fragile; any layout change silently mis-points them. If the HUD becomes shared, re-tune these once against the shared layout.
- **Mild duplication:** the hover HUD (`:1133-1163`) and the click module card (`:3120-3202`) show overlapping seat info. On 2D, where the node card is already fully visible, the module card is largely redundant — consider dropping it in 2D and keeping just the hover HUD.

**Verdict:** the windows are well-built and cheap to share. The 3D-only-ness is a hosting artifact, which is exactly why this is a re-parenting job more than a rebuild.

---

## 2. Recommended architecture — share the HUD, don't duplicate it

The 2D canvas (`AgentCanvasView`) and 3D map (`Agent3DMapView`) are **already peer subviews of one container, `canvasPage`**; the mode switch is pure `isHidden` toggling (`PanelController.applyMapMode` `:694-727`). And **two overlays already float over both maps** because they attach to `canvasPage` rather than to a specific map: the **Guide bubble** (`_mapHostForBubble()` → `canvasPage`, `PanelController.swift:105-107`; `AppAIChatBubble.swift:37-48`) and **coach marks** (`MapCoachMarks.swift:38-52`). That's the proven pattern.

**So: extract the HUD panels out of `Agent3DMapView` into a `MapHUDController` mounted on `canvasPage`, visible in both modes.** One implementation, one data feed, both maps benefit. This beats copying ~1,500 lines of panel code into the 2D view and then maintaining two of everything.

```
canvasPage (shared container)
├── canvasScroll → AgentCanvasView   (2D, isHidden when 3D)
├── map3D: Agent3DMapView            (3D, isHidden when 2D)
├── canvasToolbar
├── MapHUDController  ← NEW: TRACKING / YOU / CRON / TASKS / LEGEND / hover   (mode-independent)
├── AppAIChatBubble   (already here)
└── MapCoachMarks     (already here)
```

The map views keep only what's intrinsic to their render space (seat glyphs, edges, flow animation, selection/hit-testing). Everything textual/paneled moves to the shared HUD.

---

## 3. Work classified into three buckets

### Bucket A — Re-parent (cheap; pure AppKit, zero SceneKit dependency)
Move construction of these out of `Agent3DMapView` into `MapHUDController` on `canvasPage`. They already read shared data.

| Window | Build site (3D) | Data source | Notes for 2D |
|---|---|---|---|
| TRACKING | `setupTrackingPanel` `:1236`, `refreshTrackingList` `:2560` | in-memory seats + `SeatActivity` | verbatim |
| YOU · human console | `setupHumanPanel` `:1275`, `sendHumanChat` `:1907`, `humanRespondAsk` `:1894` | `HumanConsoleController`, snapshot | verbatim; the two SceneKit side-effects (`relayoutHumanToLinkedOrch` `:1633`, `pulseHumanOrchLink` `:1925`) become no-ops/2D-equivalents |
| TASKS | `setupTaskPanel` `:1496`, `reloadTaskRecap` `:1676` | `snapshot.json` jobs/workers | verbatim |
| CRON panel | `setupCronPanel` `:1976`, `reloadCronTimeline` `:2504` | `CronSchedule` | verbatim (this is the panel twin of the 3D ruler — see B) |
| LEGEND | `setupLegend` `:1938` | static | update glyph key for 2D shapes |
| Hover HUD | `setupHUD` `:1133`, `showHover` `:2936` | seats | keep; drive from 2D hover (needs Bucket B tracking area) |
| Guide bubble | `AppAIChatBubble` | — | **already shared** — no work |
| Coach marks | `MapCoachMarks` | — | **already shared**; re-tune anchor y's once |

Also already present in 2D (don't rebuild): the **right-click context menu** exists on the 2D canvas (`AgentCanvasView.rightMouseDown` `:734`), and **"+"/subagent add chips** exist (`layoutDockedAddButtons` `:1186`).

### Bucket B — Re-implement for the 2D render space (the real work)
The 2D canvas already draws seat cards and 3-style bezier edges with labels/arrowheads (`AgentCanvasView.draw` `:963-1017`, `drawEdge` `:1053`), selection, drag-to-move with disk persistence, human-amber and live-bright edges. What it lacks:

1. **Animated flow dots ("dots travel only when data flows") — the headline visual.** 3D runs `SCNAction` packets along active edges (`Agent3DMapView.connect` `:4966-4994`). 2D edges are static Core Graphics with no timer. **Add a `CADisplayLink` (or `CAShapeLayer` + `CAKeyframeAnimation` along the existing bezier path) to `AgentCanvasView`, animating 1–2 dots per edge when `SeatActivity.linkHasLiveData(...)` is true.** Reuse the exact same rule the 3D uses (`SeatActivity.swift`) and the 5s linger (`flowLingerSec`) so behavior matches. This is ~the one net-new animation.
2. **Seat glow halo.** 2D has only a small pulsing status dot (`updateWorkingGlow` `:584-607`); 3D pulses a ring + emission halo. Upgrade the dot to a layer-based halo behind the card, gated by the same `SeatActivity.isActivelyWorking`.
3. **Optional — 2D cron timeline.** The 3D cron *ruler* (`rebuildCronRuler` `:2100`) is the spatial twin of the CRON panel. Since the CRON panel (Bucket A) already lists next-runs, a 2D ruler is **optional**; add a simple horizontal strip later only if wanted.
4. **Optional — backdrop.** Decks/grid/atmosphere (`buildDotSphere` `:888`, deck planes) are pure 3D scenery. Drop them; the 2D grid already gives a substrate. Add a subtle 2D backdrop only for aesthetics.

### Bucket C — Drop entirely in 2D
All camera/coordinate logic has no 2D analog and should not be ported: hit-testing via `scnView.hitTest` (`:2723`) → replace with point-in-rect (2D already does this in `mouseDown`); orbit/pan/zoom-toward-pointer (`:712-723, 595-639`); Orbit-vs-Move mode split (`:815-830`); ray→deck-plane drag unproject (`:3036-3094`) → 2D already drags with saved x/y; distance LOD (`:5193-5290`); billboarding + body-yaw; depth/surface-exit edge stops; the render-on-demand SceneKit pulse loop (only the flow-dot timer from B is needed). In the toolbar, **Orbit/Move** stay 3D-only (already hidden in 2D, `PanelController.swift:716-721`).

---

## 4. Gaps to close in the shared model & callbacks

- **Model fields.** The 2D `AgentNodeModel` (`AgentCanvasView.swift:138`) lacks `parentId`, `openJobs`, `flowHint`, `missionRole` that `Seat3D` carries (`PanelController.swift:1039-1045`) and that some panels want. These are **already computed** in `refreshCanvas` — either extend `AgentNodeModel` with them or unify the two models into one seat struct both maps + the HUD read. Unifying is the cleaner end state.
- **Seat callbacks.** The 3D exposes `onHuman` (open YOU console for a seat) and `onAddSub` (add subagent); the 2D exposes neither. Add both to `AgentCanvasView` and wire them in `PanelController` next to the existing `canvas.onFront/onKill/onOptions/onPerms/onFocus/onAddWorker/onRename` (`PanelController.swift:517-534`). The 3D wiring at `PanelController.swift:552-610` is the template.
- **Hover.** `AgentCanvasView` has **no** `NSTrackingArea`/`mouseMoved` today (only static `toolTip`s). To drive the shared hover HUD from 2D, add `updateTrackingAreas`/`mouseMoved` and emit an `onHover(model?)` the HUD listens to.
- **Topology editing.** If you want link-create/bend on the 2D map (3D surfaces this via the 3D-only "Architecture" pill → `openArchitectureSheet` `:835`), **reuse `TeamArchCanvas`** — it already implements 2D link-mode edge creation, bending, and endpoint-drag (`TeamArchCanvas.swift:40, 175, 500-546`). Don't reinvent it in `AgentCanvasView`.

---

## 5. Suggested sequencing for the coder

1. **Phase 0 — Shared HUD (biggest win).** Extract TRACKING/YOU/CRON/TASKS/LEGEND/hover into `MapHUDController` on `canvasPage`, driven by `refreshCanvas`. Make it visible in both modes. Result: the 2D map instantly gains every text window, including the full human console. Verify the YOU send/ask-accept flow works in 2D mode.
2. **Phase 1 — Flow dots + glow (Bucket B1/B2).** Add the `CADisplayLink` packet animation and the glow halo to `AgentCanvasView`, both gated by the existing `SeatActivity` rules. This closes the "feels alive" gap.
3. **Phase 2 — Interaction parity.** Add `onHuman` + `onAddSub` callbacks and the hover tracking area; wire per `PanelController` templates.
4. **Phase 3 — Model unification.** Fold `AgentNodeModel` and `Seat3D` into one seat model (adds `parentId/openJobs/flowHint/missionRole` to 2D). Removes the last duplication.
5. **Phase 4 — Optional.** 2D cron ruler; 2D topology editing via `TeamArchCanvas`; backdrop polish.

**Risks / decisions to make up front:**
- Phase 0 touches a lot of `Agent3DMapView` (moving ~8 panel builders out). Do it as a mechanical extract with the 3D map calling into the shared controller, so the 3D view keeps working throughout.
- Decide the **module card** question: on 2D the node card is already visible, so the click-to-expand module card (`:3120`) is probably redundant — keep hover HUD, drop module card in 2D.
- After the HUD moves, **re-tune coach-mark anchors** once (`MapCoachMarks.swift:64-71`) against the shared layout.

**Net:** most of the "windows" are a re-parent (Phase 0). The only real new 2D code is the flow-dot animation and the glow halo (Phase 1). Everything camera/3D can be dropped.

---

## 6. Implementation status (2026-07-23)

| Phase | Status | Notes |
|-------|--------|--------|
| **0 Shared HUD** | **Done (pragmatic)** | `Agent3DMapView.promoteSharedHUD(to: canvasPage)` re-parents `leftHUDScroll` + `legendPanel` onto `canvasPage`. Visible in **both** 2D and 3D. |
| **1 Flow dots + glow** | **Done** | 2D edges: bezier packets when `SeatActivity` + linger; card halo + status pulse when working. |
| **2 Callbacks** | **Done** | `onHuman` / `onAddSub` on 2D cards (You / +sub buttons); model fields extended. |
| **3 Model unify** | Partial | `AgentNodeModel` now carries `parentId/openJobs/flowHint/missionRole`; full Seat3D merge still optional. |
| **4 Optional** | Not started | 2D cron ruler; TeamArchCanvas on flat map; coach-mark re-tune. |

**Code touchpoints:** `Agent3DMapView.promoteSharedHUD`, `AgentCanvasView` flow timer + packets, `PanelController` wiring.

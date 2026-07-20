# Claude audit (pass 2) — Agent-Pong map after Grok v4

**Auditor:** Claude (second-eye) · **Date:** 2026-07-20 · **Findings only — no code changed.**
**Read:** `docs/CLAUDE_AUDIT_HANDOFF.md`, `docs/design-handoff-agent-map/SWIFT_GUIDE.md`, and the v4 diffs in `Agent3DMapView.swift` / `MenuBarApp.swift` / `CronSchedule.swift`.
**Verdict:** the five original P0s are genuinely fixed and correct — don't regress them. The remaining "doesn't look the same / still laggy / slow to react" reduces to **three** concrete causes, all surgical.

---

## TL;DR

| Symptom | Root cause | Fix size |
|---------|-----------|----------|
| **Slow to *react*** (stutters/freezes while orbiting, panning, scrolling) | Pulse is a `Timer.scheduledTimer` (`startPulse`, ~3818) running in **`.default` run-loop mode**. During gesture/scroll the run loop is in `.eventTracking`, so the timer **stops firing** → bob/yaw/packets freeze mid-interaction. `scnView.delegate = self` is set and the class conforms to `SCNSceneRendererDelegate`, but **no `renderer(_:updateAtTime:)` exists** — the render loop the guide wants is wired up but unused. | small |
| **Laggy / periodic hitch / slow to load** | `updateBlobMaterial` (~3300) **re-renders the 256×200 face `NSImage` and reallocates all materials on every call** — called for every seat on the **2.5 s poll**, and a **second time at creation** (double-bake at load). No content dirty-check. | small |
| **Doesn't look the same** (flat/matte, not neon) | Bloom is enabled but **too weak to trigger** (`bloomIntensity = 0.12`, `bloomThreshold = 0.85`, ~649) while **every material has `emission = .black`** under `.constant` lighting. Nothing crosses the threshold, so there's no glow. Guide wants **emissive edges + bloom** (SWIFT_GUIDE lines 16/31/32/85). | small |
| Face double-bake at load | `placeBlob` bakes `cubeFaceImage` at 2971, then calls `updateBlobMaterial` at 3062 which bakes it **again**. | trivial (folds into fix #2) |
| Human face may distort | `octahedronWithFrontFace` splits the image across two angled facets — text can bend at the seam. | verify only |

---

## What Grok got right (do NOT regress)

These are all correct and match the design — leave them alone:

1. **Face on the solid (P0-1) — fixed properly.** `regularPrism(sides:radius:height:frontFace:bodyColor:)` (~3275) now orients vertices so **wall 0's outward normal is +Z natively** (`aa = i/sides*2π + π/2 − π/sides`) with **no body yaw**, and maps the face image with clean UVs `(0,0)(1,0)(1,1)(0,1)` as material index 0. The double-offset (child-of-yawed-body) is gone. Cube uses SCNBox front material; both read square under the `atan2+0.34` billboard.
2. **Bob (P0-2) — fixed.** `placeBlob` reuse path updates only `position.x/z` and `baseY`; "pulse owns position.y" (2947–2952). No more y-stomp on reload.
3. **Ground rings — correct.** `syncPlaneRing`/`planeRings` (~3072) put rings on the **deck plane as siblings** of the seat, so they don't bob with the solid — matches SWIFT_GUIDE line 47.
4. **Flow packets (P0-3) — fixed.** `edgeSignature`/`edgeSigs` diff (2884–2907) leaves unchanged edges **and their running packet `SCNAction`s intact** ("leave running packet SCNActions alone"), removing only disappeared/changed edges. Packets now traverse fully instead of restarting every 2.5 s.
5. **Décor point cloud (P0-4) — done.** 13×13 dots per plane are **one** `pointCloudGeometry` `.point` element (~873), replacing ~507 `SCNSphere` nodes. True `.line`-primitive silhouette edges (`lineGeometry`, `prismEdgeLines`, `boxEdgeLines`) — no more triangle-diagonal "cages."
6. **Cheap wins landed:** MSAA `4X → 2X` (609); pulse `24 → 20 fps` (3818); `camMoved` epsilon gate skips the yaw write when the camera is still; pulse body gated on `isPlaying && !isHidden`; `setMapPlaying(false)` on Mission/Setup.
7. **Terminal zombie (P0-5) — fixed exactly right.** `openAttachSession` (~1626) now uses `trap close_self EXIT`, **no `exec`**, and closes **only windows whose name contains the unique `PONGATTACH:` marker** (re-asserting the marker after tmux retitles). Covers detach, kill, and fail paths; never closes "front window." This is the correct implementation — keep it.

---

## Remaining fixes

### P0-A — Move per-frame motion off `Timer` onto the render loop  *(fixes "slow to react")*

**Where:** `startPulse` (~3814–end); `scnView.delegate = self` already at 610.

**Why:** `Timer.scheduledTimer` only fires in `.default`. SceneKit camera gestures + scroll run the main loop in `.eventTracking`, so the timer pauses → motion freezes exactly while the user is interacting, then jumps on release. That *is* the "slow to react" report.

**Direction (pick one):**
- **Preferred (design-correct):** implement `func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval)` and move the pulse body into it (drive `pulsePhase` from the passed `time` delta instead of a fixed `+= 0.085`). SceneKit calls this every rendered frame **including during interaction**, and you already conform to the protocol + set the delegate. Delete the `Timer`. This is what SWIFT_GUIDE line 35 specifies.
- **Minimal (if you don't want to touch the loop body):** keep the `Timer` but register it in common modes:
  ```swift
  let t = Timer(timeInterval: 1.0/20.0, repeats: true) { [weak self] _ in ... }
  RunLoop.main.add(t, forMode: .common)
  ```
  `.common` includes `.eventTracking`, so it keeps firing during gestures.

Either removes the freeze. Prefer the render-loop version — it also lets you stop `scnView.isPlaying = true` continuous render and only redraw when something moves.

---

### P0-B — Dirty-flag the face image / material rebuild  *(fixes periodic hitch + slow load)*

**Where:** `updateBlobMaterial` (~3300), called from `placeBlob` reuse path (2953) every 2.5 s poll and again at creation (3062); `cubeFaceImage` (256×200 Core Graphics) is the cost.

**Why:** every poll re-renders N face images and allocates fresh `SCNMaterial`s for every seat even when nothing changed — a visible hitch every 2.5 s and N image bakes at load (doubled, since `placeBlob` bakes once at 2971 then `updateBlobMaterial` bakes again).

**Direction:**
1. **Cache the face image by content key.** Compute `key = "\(role)|\(status)|\(title)|\(resolvedMission?.title ?? "")|\(active)"`; store the last key + `NSImage` per `globalId` (KVC or a `[String:(String,NSImage)]`). In `cubeFaceImage`, return the cached image when the key is unchanged. This makes the second creation bake and every unchanged poll free.
2. **Early-out `updateBlobMaterial`** when the key hasn't changed *and* active/color haven't changed — skip the material reassignments entirely (they re-upload textures otherwise).
3. **Don't rebake at creation:** in `placeBlob`, drop the trailing `updateBlobMaterial(root, seat: s)` for a freshly built node (its materials are already set from the builder), or rely on the cache so it's a no-op.

Net: face-texture work goes from `O(seats)` every 2.5 s to `O(changed seats)`, and load halves.

---

### P1-C — Make it read as neon (bloom actually firing)  *(fixes "doesn't look the same")*

**Where:** camera bloom (~648–650); `unlitEdge`/`unlitBody`/`unlitFace`/ring materials (all set `emission = .black`).

**Why:** SWIFT_GUIDE is explicit — glow is **camera bloom** (lines 16, 32, 85) and edge lines are **emissive** (line 31). Right now bloom is on but starved: `bloomThreshold = 0.85` with `.constant` lighting and `emission = .black` means output = diffuse color; role blues/violets/magentas rarely exceed 0.85 luma, so **almost nothing blooms** → flat matte, not the neon reference.
*(Note: my pass-1 audit treated `emission = .black` as acceptable while chasing the 5 functional P0s; re-reading the guide, the intended look genuinely requires emissive + bloom. Calling that out now.)*

**Direction (small, reversible):**
- Give the **edge line** material an `emission` in the role color (e.g. `full.withAlphaComponent(active ? 0.9 : 0.4)`) so silhouettes are the bright neon input bloom needs. Optionally the active ground ring too.
- Lower `bloomThreshold` to ~**0.5** and raise `bloomIntensity` to ~**0.3–0.5**; keep `wantsHDR = true`. Tune against the reference screenshot.
- Keep face panels and bodies non-emissive (they should stay crisp/readable, not glow). This matches "glow from bloom on the edges, faces stay exact."

This is the single biggest lever on "looks the same." No sprites (guide forbids them) — bloom only.

---

### P2 — verify (not confirmed bugs)

- **Human face distortion:** `octahedronWithFrontFace` (~3216) spans the info image across "upper + lower front" facets; check the name/text doesn't visibly kink at the facet seam. If it does, shrink the panel to the single largest front facet or flatten those two tris toward coplanar.
- **Ruler cost:** `reloadCronTimeline` / `rebuildCronRuler` are gated by `rulerDirty` (good). Confirm the pulse loop and `addJobForOwner`/`plusMenuAddCron` don't set `rulerDirty` every frame (would rebuild ruler geometry continuously). A quick log on `rulerDirty = true` frequency confirms it.
- **`+ Add cron job`:** `plusMenuAddCron` → `CronSchedule.addJobForOwner` (~287) is menu-driven (one-shot), so no per-frame cost — fine; just verify the sheet reload calls `reload()` once, not in a loop.

---

## Prioritized order

1. **P0-A** render-loop / `.common`-mode pulse — kills the interaction freeze (biggest "react" win).
2. **P0-B** face-image dirty-flag + no double-bake — kills the 2.5 s hitch and speeds load.
3. **P1-C** emissive edges + bloom tuning — restores the neon look.
4. **P2** human-face + ruler verifications.

---

## Verification checklist

- [ ] Orbit / pan / scroll the map continuously: bob, yaw, and link packets keep moving **during** the gesture (no freeze-then-jump).
- [ ] Idle for 30 s with a full team: no periodic hitch every ~2.5 s (face images no longer rebuilt each poll).
- [ ] Cold load of a large team feels faster; Instruments Time Profiler shows `cubeFaceImage` called ~once per seat, not 2×+.
- [ ] Active edges glow (emissive) and read as neon against the dark planes; faces stay crisp/readable (not bloomed).
- [ ] Bloom visibly present on edges/rings but not blowing out the whole scene (threshold/intensity tuned to the reference).
- [ ] Faces square on all four shapes under orbit (already true post-v4 — regression check).
- [ ] Detach a seat (`Ctrl-b d`) and kill a seat: attach window self-closes, no "[Process completed]", no unrelated window closed (already true post-v4 — regression check).

---

*Saved to `docs/CLAUDE_AUDIT_FINDINGS.md` (overwrote pass 1). Findings only — no code changed.*

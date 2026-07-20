# Claude review verdict — Grok v4, before v5

**Reviewer:** Claude (second-eye) · **Date:** 2026-07-20 · **Review only — no code changed.**
**Verified against live tree:** `Agent3DMapView.swift`, `MenuBarApp.swift`, `CronSchedule.swift`, cross-checked with `SWIFT_GUIDE.md` and my pass-2 (`CLAUDE_AUDIT_FINDINGS.md`).

## 1. TL;DR

**Ship v5 — no v4 rework required.** Grok's v4 is correct across A–H with **no regressions found**; every original P0 fix holds up in the live code. Since my pass-2, Grok also landed a real `faceImageCache` (with a complete content key), so **P0-B is now ~half done** — the expensive 256×200 re-bake is cached; only a cheap per-poll *material-reassignment* early-out remains. One amendment to the v5 plan: for **P0-A, do the `Timer .common` fix first, not `renderer(_:updateAtTime:)`** — the render-loop version introduces a real main-vs-render-thread data race against the existing `seatNodes`/`edgeSigs` mutation, so it's a follow-up, not the first move. P0-A → P0-B → P1-C order stands.

## 2. v4 scorecard (A–I)

| Item | Verdict | Note |
|------|---------|------|
| **A. Faces on solid** | ✅ Correct | `regularPrism(frontFace:)` orients wall 0 normal to **+Z natively** (`aa = i/sides·2π + π/2 − π/sides`), maps face as materials[0] with clean UVs `(0,0)(1,0)(1,1)(0,1)`, **no body yaw**. Cube = SCNBox material[0]. Double-offset gone. |
| **B. Silhouette edges** | ✅ Correct | `lineGeometry` + `boxEdgeLines`/`prismEdgeLines`/`octahedronEdgeLines` use true `.line` primitives — no triangle diagonals, no `fillMode=.lines` cages. |
| **C. Plane rings** | ✅ Correct | `syncPlaneRing`/`planeRings` parent ring to `rootNode` at deck Y; pulse updates XZ + opacity only, solid owns bob Y. Matches SWIFT_GUIDE line 47. |
| **D. Bob / activity** | ✅ Correct | Reuse path updates only `position.x/z` + `baseY` (2947–2952); `isSeatActive` unified for bob + ring + link-active. |
| **E. Flow packets survive poll** | ✅ Correct | `edgeSignature`/`edgeSigs` (2884–2907) skip `connect` when sig unchanged and "leave running packet SCNActions alone"; `removeEdgeNodes` only for gone/changed edges. |
| **F. Subtle ruler** | ✅ Correct | `buildCronRulerBase` (1707) = invisible hit strip (`colorBufferWriteMask = []`, clear, no depth write) + faint spine, no plate/rim box. |
| **G. + → cron** | ✅ Works | `plusMenuAddCron` → `CronSchedule.addJobForOwner` (287) → `show` + deferred `appendAndEdit`. Menu-driven, no per-frame cost. **Minor:** `appendAndEdit` `persist()`s a "New job / every 1h" stub **before** the edit alert is confirmed — cancel leaves a stub. Non-blocking. |
| **H. Terminal zombies** | ✅ Correct | `openAttachSession` (1626): no `exec`, `trap close_self EXIT`, closes only windows whose name contains `PONGATTACH:<marker>` (re-asserted after tmux retitles). Covers detach/kill/fail; never "front window." |
| **I. Perf (partial)** | 🟡 Partial | Point-cloud dots ✅, `.line` edges ✅, MSAA 2X ✅, `setMapPlaying` ✅. **`faceImageCache` ✅ NEW** — keyed `globalId\|role\|status\|title\|mission\|active\|openJobs\|flowHint\|size` (complete, no stale-face risk), capped 64. **Still open:** (a) pulse is `Timer` in `.default` → freezes during interaction (P0-A); (b) `updateBlobMaterial` reallocates ~6 `SCNMaterial`s per seat every poll even when nothing changed (P0-B residual). |

**Regressions:** none. Faces, bob, packets, hit-testing, and attach are all equal-or-better than pre-v4.

## 3. Must-fix before v5

**None is a hard blocker.** v4 is correct and can be treated as shippable progress. Two optional pre-v5 tidies (do only if convenient):
- **Ring leak check (verify):** confirm `removePlaneRing(gid)` is called when a seat **disappears from the team**, not only on shape-change in `placeBlob`. If `layoutSeats` drops a seat without removing its `planeRings[gid]`, the ring orphans on `rootNode`. 5-min check.
- **Cron stub (G):** move `persist()` to *after* the edit alert is confirmed so a cancelled "Add cron job" doesn't leave a stub.

Neither blocks the P0-A/B/C work.

## 4. Approved v5 plan (with amendments)

### P0-A — kill the interaction freeze — **APPROVED, approach amended**
- **Do first: `Timer` in `.common` modes.** Replace `Timer.scheduledTimer(...)` (3818) with `let t = Timer(timeInterval: 1/20, repeats:true){…}; RunLoop.main.add(t, forMode: .common)`. `.common` includes `.eventTracking`, so the pulse keeps firing during orbit/pan/scroll. **Zero threading risk** — stays on main.
- **Do NOT lead with `renderer(_:updateAtTime:)`.** SceneKit calls it on the **render thread**, which would iterate `seatNodes`/`planeRings`/`edgeSigs` concurrently with the main-thread `layoutSeats`/`edgeSigs` mutation (every 2.5 s) → data race / intermittent crash. It's the "more correct" long-term form, but only after those shared collections are synchronized. Defer it; the `.common` timer fully fixes the reported "slow to react."

### P0-B — stop per-poll material churn — **APPROVED, scope reduced (cache already done)**
- Image cache is done and correct; keep it. Remaining: **early-out `updateBlobMaterial`.** Store a per-seat `lastFaceKey` (the same content key) via KVC; at the top of `updateBlobMaterial`, if `key == lastFaceKey && active/color unchanged`, `return` before reassigning any materials. Eliminates ~6 `SCNMaterial` allocations × seats every poll.
- Double-*bake* at create is already neutralized by the cache (2nd `cubeFaceImage` call hits cache); the early-out also makes the trailing `updateBlobMaterial(root, seat:)` in `placeBlob` a no-op for fresh nodes.

### P1-C — neon look via bloom — **APPROVED as written**
- Make **edge-line** material (and optionally the active ring) **emissive in the role color** (`emission ≈ full.withAlpha(active ? 0.9 : 0.4)`). Keep **faces and bodies `emission = .black`** — this is the readability guardrail; an emissive face blooms the white text into mush.
- Lower `bloomThreshold` 0.85 → **~0.5**, raise `bloomIntensity` 0.12 → **~0.3–0.5**, keep `wantsHDR = true`. Tune incrementally against the reference screenshot; watch for whole-scene blowout at high intensity.

### Ship order
**A → B → C**, unchanged. A and B both touch the pulse/update path — bundle them; do C last as a pure look pass.

## 5. Do-not-touch (v4 got these right — don't regress)

- `regularPrism(frontFace:)` +Z-native facet + UVs; cube SCNBox material[0] face; `octahedronWithFrontFace`.
- `.line`-primitive edge shells (`lineGeometry` family).
- `syncPlaneRing`/`planeRings` deck-plane rings (siblings, don't bob).
- `placeBlob` reuse path (x/z + baseY only; pulse owns Y).
- `edgeSignature`/`edgeSigs` diff (keeps packet `SCNAction`s alive).
- `pointCloudGeometry` décor; MSAA 2X.
- `faceImageCache` + its content key.
- `openAttachSession` trap/marker-close (no `exec`).
- `buildCronRulerBase` subtle ruler.

## 6. Verification checklist for Grok after v5

- [ ] Orbit / pan / scroll continuously: bob, yaw, and packets keep moving **during** the gesture (no freeze-then-jump) — proves P0-A.
- [ ] Idle 30 s with a full team: no hitch every ~2.5 s; Time Profiler shows `updateBlobMaterial` early-outs (near-zero `SCNMaterial` allocs when nothing changed) — proves P0-B.
- [ ] Cold-load a large team: `cubeFaceImage` bakes ~once per seat (cache hits after) — regression check on the cache.
- [ ] Active edges/rings read as neon against the dark planes; **face text stays crisp/readable** (not bloomed) — proves P1-C without blowout.
- [ ] Faces square on all four shapes under orbit; detach/kill a seat → attach window self-closes, no "[Process completed]", no unrelated window closed — regression checks on A/H.
- [ ] Remove a seat from the team: its plane ring disappears (no orphan ring) — ring-leak check.

---

*Saved to `docs/CLAUDE_REVIEW_VERDICT.md`. Review only — no code changed. Scope: Agent-Pong, under explicit operator override (not Umbra).*

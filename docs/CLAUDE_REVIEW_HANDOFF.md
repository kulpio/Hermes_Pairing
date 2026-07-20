# Claude review handoff — verify Grok’s v4 before v5

**Date:** 2026-07-20  
**Repo:** `/Users/dylandemnard/src/Agent-Pong` (**NOT Umbra** — explicit scope override)  
**Ask:** **Review only.** Do **not** implement. Grok will act only after your review.

Write review to:

```
docs/CLAUDE_REVIEW_VERDICT.md
```

When done, print a short TL;DR in chat.

---

## Context

1. Your **pass-1 audit** → Grok implemented P0s.  
2. User still unhappy → Grok shipped **shapeKey v4** (faces on solid, line edges, plane rings, subtle ruler, + cron, perf cuts).  
3. Your **pass-2 audit** (`docs/CLAUDE_AUDIT_FINDINGS.md`) says: v4 fixed the five original P0s; remaining work is **P0-A** (render-loop pulse), **P0-B** (dirty-flag faces), **P1-C** (emissive + bloom).  
4. User now: **“have claude review what you've done before acting on it.”**

So: re-read the **current tree** and judge whether Grok’s v4 is correct / complete / risky, and whether your pass-2 plan for v5 is still right. Approve, amend, or block items.

---

## What Grok claims is done (verify against code)

### A. Faces on solid (was floating / double-offset)
- `placeBlob` shapeKey `hex-v4` / `tri-v4` / `octa-v4` / `cube-v4` (~2937)
- Prism: `regularPrism(..., frontFace:bodyColor:)` — wall 0 UV face material, no body yaw
- Human: `octahedronWithFrontFace` — dual front facets with UVs
- Cube: SCNBox material[0] = face
- **No** separate floating `SCNPlane` face child

### B. Silhouette edges only (no diagonals)
- `lineGeometry` + `boxEdgeLines` / `prismEdgeLines` / `octahedronEdgeLines`
- Shells use true `.line` primitives, not `fillMode=.lines` on triangles

### C. Active ring on plane (not bobbing with solid)
- `planeRings` dict; `syncPlaneRing` parents ring to `rootNode` at deck Y
- Pulse updates ring XZ + opacity only; solid owns bob Y

### D. Bob / activity
- Reuse path: only `position.x/z` + `baseY` (not full `position = pos`)
- Unified `isSeatActive` for bob / ring / link active

### E. Flow packets survive poll
- `edgeSigs` + `edgeSignature`; skip `connect` when sig unchanged
- `removeEdgeNodes` only for gone/changed edges

### F. Ruler subtle
- `buildCronRulerBase`: invisible hit + spine, no solid plate/rim box

### G. + → cron
- `showPlusMenu` → “Add cron job…” → `plusMenuAddCron` → `CronManagerSheet.addJobForOwner`

### H. Terminal zombies
- `openAttachSession`: no `exec`, `trap close_self EXIT`, close by `PONGATTACH:` marker

### I. Perf (partial)
- Point-cloud plane dots + atmosphere
- `faceImageCache` in `cubeFaceImage` (but pass-2 says `updateBlobMaterial` still double-bakes / no early-out)
- MSAA 2X, ~20 fps Timer pulse, `setMapPlaying` on Mission/Setup

---

## What Grok has **not** done yet (pass-2 v5 plan)

| ID | Plan | Status |
|----|------|--------|
| P0-A | Pulse via `renderer(_:updateAtTime:)` or Timer `.common` | **Not done** — still `Timer.scheduledTimer` in `startPulse` |
| P0-B | Dirty-flag `updateBlobMaterial` + avoid double-bake at create | **Partial** — image cache exists; material rebuild every poll still? |
| P1-C | Emissive edges + bloom threshold/intensity | **Not done** — bloom 0.12 / 0.85, emission black |

**Do not implement these.** Only say: approve as-is, change approach, or drop.

---

## Review checklist (please answer each)

1. **Correctness of v4 fixes** — For each of A–H: OK / bug / incomplete. Cite function + issue if not OK.  
2. **Regressions** — Anything worse than pre-v4 (faces, bob, packets, attach, hit testing)?  
3. **P0-A approach** — Prefer `updateAtTime` vs Timer `.common`? Any SceneKit gotcha on AppKit?  
4. **P0-B approach** — Is content-key cache enough, or must materials skip reassignment? Confirm double-bake at `placeBlob`→`updateBlobMaterial`.  
5. **P1-C approach** — Safe emission values so faces stay readable? Risk of bloom blowout?  
6. **Ship order** — Still A → B → C? Anything else before neon?  
7. **Blockers** — Anything Grok must fix in v4 *before* starting v5?  
8. **Human dual-face** — Accept for now, or must flatten before neon pass?

---

## Key files

| File | Focus |
|------|--------|
| `src/Agent3DMapView.swift` | `placeBlob`, `syncPlaneRing`, `layoutSeats` edge diff, `startPulse`, edge/face helpers, `updateBlobMaterial`, `cubeFaceImage`, ruler base |
| `src/MenuBarApp.swift` | `openAttachSession` (~1626–1665) |
| `src/CronSchedule.swift` | `addJobForOwner` |
| `docs/CLAUDE_AUDIT_FINDINGS.md` | Your pass-2 plan |
| `docs/design-handoff-agent-map/SWIFT_GUIDE.md` | Design truth |

---

## Output format for `docs/CLAUDE_REVIEW_VERDICT.md`

1. **TL;DR** — one paragraph: ship v5 / fix v4 first / amend plan.  
2. **v4 scorecard** — table: item A–I · verdict · note.  
3. **Must-fix before v5** (if any) — surgical.  
4. **Approved v5 plan** — P0-A / P0-B / P1-C with any amendments.  
5. **Do-not-touch** — list from pass-2 “got right.”  
6. **Verification checklist** for Grok after v5.

Findings/review only — **no code changes**.

Thanks.

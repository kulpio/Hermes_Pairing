# Claude audit handoff v2 — Agent-Pong map (from Grok)

**Date:** 2026-07-20 (second pass)  
**Repo:** `/Users/dylandemnard/src/Agent-Pong` (NOT Umbra — explicit scope for this task)  
**Stack:** Native **Swift + AppKit + SceneKit** only. Design: `docs/design-handoff-agent-map/SWIFT_GUIDE.md` + `README.md`.

**Scope override:** This audit is for **Agent-Pong**, not Umbra. Please proceed on this repo. Read-only audit + write findings file only — do **not** implement code changes unless asked later.

Write findings to:

```
docs/CLAUDE_AUDIT_FINDINGS.md
```

(Overwrite the previous findings with this second-pass audit.) When done, print a short TL;DR in chat so Grok can poll.

---

## Where we are

### First audit (you) → Grok implemented
Your first pass (`CLAUDE_AUDIT_FINDINGS.md` P0-1..5) was largely applied:

| P0 | Status after Grok |
|----|-------------------|
| Faces double-offset on prism body | Re-parented then **rewrote** to material-on-solid (v4) |
| Bob / activity mismatch | Unified `isSeatActive`; reuse path no longer stomps `position.y` |
| Flow packets reset every 2.5s | Edge **diff** by signature (`edgeSigs`); packets keep SCNActions |
| Perf | Point-cloud plane dots + atmosphere; face image cache; MSAA 2X; ~20fps pulse; single-sided then true line edges |
| Zombie PONGATTACH | `.command` drops `exec`, `trap EXIT`, close by marker title |

### Second user pass (just shipped, shapeKey **v4**)
User still said “does not look exactly the same” and asked for:

1. **Ruler more subtle** — lines only, no outline of the ruler  
   → Removed solid surface + rim box; invisible hit strip + faint spine + ticks.
2. **`+` create cron from agent**  
   → Menu item “Add cron job…” → `CronManagerSheet.addJobForOwner`.
3. **No see-through diagonal cages** — outside lines only, no diagonals  
   → Shells are true `.line` edge geometry (`boxEdgeLines` / `prismEdgeLines` / `octahedronEdgeLines`), not `fillMode=.lines` on triangle meshes.
4. **Info cards on faces, better fit**  
   - Cube: SCNBox front material (unchanged idea)  
   - Prism: multi-material front wall UV (`regularPrism(..., frontFace:)`)  
   - Human: **two upper + two lower** +Z facets with shared UV panel (`octahedronWithFrontFace`) — no floating `SCNPlane`  
5. **Active ring on plane, not bobbing with solid**  
   → `planeRings[gid]` parented to `rootNode` at deck Y; pulse only XZ + opacity.
6. **Still laggy / slow to load and react**  
   → Atmosphere → point cloud; less frequent cron HUD refresh; prior caches kept. User still unhappy.

App installed via `scripts/install.sh` after build.

---

## Known issues / what to re-audit (user still unhappy)

Treat as **P0 verification**, not “Grok said fixed”:

### A. Visual fidelity vs design + screenshot
- Open current `placeBlob` (search `hex-v4` / `cube-v4` / `octa-v4`).
- Compare silhouettes, edge treatment, face hierarchy (spine/glyph/status/eyebrow/name), plane colors, ruler, ground rings to `SWIFT_GUIDE.md`.
- **Human face:** dual-front UV may warp text; confirm whether “two faces” is correct vs a flatter panel on the solid.
- **Prism front:** geometry reoriented for flat +Z (body yaw removed) — does billboard +0.34 still read correctly? Any double-offset leftover?

### B. Active ring / bob
- Ring must stay on **layer plane** while solid bobs. Verify `syncPlaneRing` + pulse loop don’t re-parent or set ring Y from bobbed position incorrectly.
- Confirm LIVE seats still bob and idle stay still (`isSeatActive` vocab).

### C. Flow packets
- Edge diff path: only rebuild when signature changes. Confirm packets actually travel full length with multi-team + 2.5s poll.
- Active = `isSeatActive(from) || isSeatActive(to)` — too wide or too narrow?

### D. Performance / load / react
- Still “a bit laggy” and “takes time to load and react.”
- Profile remaining hotspots: `layoutSeats` every 2.5s, face cache invalidation, ruler rebuild (`rulerDirty`), SCNAction packets, MSAA, fog, tracking/YOU/cron HUD string churn, first-load décor.
- Propose **surgical** next cuts (do not rewrite the map).

### E. Ruler subtlety
- Is there still any solid plate / outline left? Hit geometry, spine, job connector cylinders — too loud vs design?

### F. + → cron
- Does `addJobForOwner` race with sheet show? Owner id vs seat title? Any missing reload of 3D ruler after save?

### G. Terminal attach (regression check)
- Re-read `openAttachSession` trap/marker close. Any remaining zombie path?

---

## What is left to do (from Grok’s view)

1. Claude second-pass audit (this handoff) → prioritized surgical fix list.  
2. Grok implements only what you confirm is still broken.  
3. Fidelity pass vs SWIFT_GUIDE checklist (bloom, fonts, exact face layout) if still off after structural fixes.  
4. Optional: cron ruler job connectors quieter; human UV flatten; further décor cull.

---

## Key files

| Area | File |
|------|------|
| Map, seats, faces, edges, rings, pulse, ruler, + menu | `src/Agent3DMapView.swift` |
| Cron model + manager + `addJobForOwner` | `src/CronSchedule.swift` |
| Terminal attach | `src/MenuBarApp.swift` (`Pairing.openAttachSession`) |
| Poll / canvas play | `src/PanelController.swift` |
| Theme tokens | `src/PongTheme.swift` |
| Design | `docs/design-handoff-agent-map/SWIFT_GUIDE.md` |
| Prior findings (historical) | previous content of `docs/CLAUDE_AUDIT_FINDINGS.md` |

---

## Method

1. Read `placeBlob`, `startPulse`, `layoutSeats` edge-diff, `connect`, `syncPlaneRing`, `buildCronRulerBase`/`rebuildCronRuler`, `showPlusMenu`/`plusMenuAddCron`, `openAttachSession`.  
2. Cross-check SWIFT_GUIDE must-haves.  
3. Write **`docs/CLAUDE_AUDIT_FINDINGS.md`** with:
   - TL;DR table (symptom · root cause · fix size)  
   - Prioritized P0/P1/P2 surgical fixes with **function names + concrete code direction**  
   - What Grok got right (so we don’t regress)  
   - Verification checklist  
4. **No code changes** in this pass — findings only.  
5. Print short summary when the file is saved.

---

## User quotes (latest)

- “it does not look exactly the same”  
- “the ruler should a bit more subtle, just the lines, no outline of the ruler”  
- “the + buttons should allow to create a cron job from an agent”  
- “remove those extra see through lines of the shapes, but we should see the outside lines (but no diagonals)”  
- “info cards on them better fit (for the Human, it should take over two face so it is not too small, but the writing should be on the face, not an extra shape floating through it)”  
- “the glowing circle on active agents should be on the plane, not bobbing with the object/shape”  
- “It still a bit laggy too and takes time to loads and react”

Thanks — surgical second eye only.

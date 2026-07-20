# 3D constellation map

**Inspiration:** Anduril Lattice (mesh tracks, black chrome, sparse labels) + Palantir map/plotlines (named paths, tracking list, directional flow).

## Spatial model

| Layer | Y | Seats |
|-------|---|--------|
| ORCH | high | Conductor |
| AGENTS | mid | Workers without `parent_id` |
| SUB | low | Workers with `parent_id` |

Background: **dotted sphere shell** (no ground plane). Camera orbits freely.

## Plotlines (named flows)

Each edge is a **directed plotline**:

| Kind | Meaning | Label examples |
|------|---------|----------------|
| DELEGATE | Conductor → worker | `DELEGATE · BUILD`, `JOB ×2`, task preview |
| PEER | Worker → worker | `PEER · HANDOFF` |
| SUB | Parent → subagent | `SUB · TASK` / `SUB · LINK` |
| HUMAN | Needs human | `NEEDS YOU` (amber) |

Active jobs: brighter beam + moving packet. Idle: faint white line + arrowhead.

## Interaction

1. **Hover** — lightweight HUD  
2. **Click orb** — floating **module card** (2D Open / Focus / Policy / Kill)  
3. **Open** on card — front terminal  
4. **TRACKING** panel (left) — seats + live links (ops list)  
5. **Legend** (right) — link / seat color key  

## Data sources

- Seats: `pairs.json` + `pong snapshot`  
- Flow labels: open job `task_preview` / status_hint / open_jobs  
- Sub layer: `workers[].parent_id`  

## Not yet

- Drag-to-reposition orbs in 3D  
- Temporal scrub of historical plotlines  
- Multi-hop claim arrows worker → conductor  

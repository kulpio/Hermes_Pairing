# Handoff: Agent Map (Pong) — 3D Orchestration Map + Mission/Setup

## Overview
A redesign of "Pong", an agent-orchestration tool with an Anduril/Lattice-inspired defense aesthetic. The centerpiece is a **3D map** that shows an agent team as three stacked hierarchy planes — **Orchestrator → Agents → Sub-agents** — with a floating human operator above. It also includes two supporting screens (**Mission** control-plane dashboard, **Setup**) reached from a left icon rail, and a **cron schedule timeline** delivered in two variants.

## About the Design Files
The files in this bundle are **design references created in HTML** (a streaming "Design Component" prototype using three.js r128 for the 3D scene). They are **prototypes showing the intended look and behavior — not production code to copy directly.**

**The target app is Swift (SwiftUI, 3D via SceneKit).** Do **not** wrap the HTML in a `WKWebView` and do **not** port three.js line-by-line — rebuild natively. **Read `SWIFT_GUIDE.md` first**: it maps every three.js concept to SceneKit/SwiftUI and lists the must-haves the first attempt likely missed (real SceneKit scene, yaw-billboard-with-offset, baked image faces, bob/ring motion rules, bloom-based glow). Keep the exact visual language (colors, typography, geometry, motion) documented below; implement the mechanics idiomatically in Swift.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, geometry, and interactions are specified. Recreate pixel- and motion-faithfully.

---

## Screens / Views

### 1. Command (the 3D map) — default view
**Purpose:** see and steer the live agent team in 3D; open agents, add agents/flows, inspect cron schedule.

**3D scene layout**
- Three horizontal square "planes" (level floors), stacked on the vertical (Y) axis, size **24×24 units**, gap **10 units**:
  - `y=+10` **ORCHESTRATOR** (accent cyan)
  - `y=0` **AGENTS** (accent magenta)
  - `y=-10` **SUB-AGENTS** (accent violet)
- Each plane renders: faint tinted fill (opacity 0.03), a **dotted grid** (13×13 points, neutral `#2a3742`, ~2.2px, opacity 0.55), center cross-hair (accent, opacity 0.1), rim frame (accent, opacity 0.32), 4 corner brackets (accent, opacity 0.55), and a faint range ring r=7.5 (accent, opacity 0.07).
- Plane label (HTML overlay, projected at the near-right corner): `NN` index (accent) · 24px rule · TITLE, e.g. `01 · ORCHESTRATOR`.
- Camera: perspective FOV 42, start position `(27,19,35)`, target `(0,0.5,0)`, OrbitControls with damping 0.08, distance 16–90, polar 0.18–1.46 (never below the floor). `autoOrbit` optional.

**Node markers (shapes carry meaning — silhouette = level)**
- **Orchestrator** = hexagonal prism (CylinderGeometry r1.4, h2.0, 6 sides).
- **Agent** = cube (1.9³).
- **Sub-agent** = triangular prism (CylinderGeometry r1.25, h1.5, 3 sides).
- **Human ("YOU")** = octahedron (r1.1), floats above the orchestrator at `y=17`, slow yaw spin + gentle bob; amber.
- Each node: dark body (`#0a1016`, opacity 0.82) + glowing accent **edge lines** (EdgesGeometry) + a soft additive glow sprite (opacity 0.16) + a short drop line to its plane.

**Info face (baked canvas texture on the +Z face, yaw-billboarded to the viewer)**
- The node group yaws each frame to face the camera **+ 0.34 rad offset** so the volume still reads as 3D (never fully flat-on). Rotation is yaw only (grounded; no pitch/roll).
- Face layout (Anduril hierarchy), 256×200 canvas, left-aligned:
  - Left **accent spine** (4px, node color) down the panel edge.
  - **Glyph marker** top-left (see Role glyphs).
  - **Status** indicator top-right: small dot + `LIVE`/`ACTIVE`/`IDLE` (dot+text muted `#6f7d85` when idle, else node color / `#e6eef3`).
  - Divider rule at y≈86 (`rgba(130,150,160,0.2)`).
  - **Role eyebrow**: tracked-out uppercase mono (letter-spacing 2.5px, node color), e.g. `ORCHESTRATOR`.
  - **Name**: prominent Space Grotesk 700, auto-fit ≤210px, `#f2f6f8`.

**Role glyphs** (drawn as geometric canvas strokes, white `#eef4f7`, lineWidth 4, centered ~(46,48)):
- ORCHESTRATOR: two concentric circles (r15 / r7).
- CODER: `{ }` braces (700 42px mono).
- RESEARCHER: magnifier (circle r11 + handle line).
- DELEGATE: branch — filled dot → two diverging strokes → two filled end dots.
- AUDITOR: check mark inside a circle (r14).
- HUMAN: figure — head circle (r5.5) + shoulders quadratic curve.

**Links** (lines between node centers): orchestrator→agents cyan, agent→sub magenta, human→orchestrator amber; idle opacity 0.32, active 0.85 with a traveling pulse sphere. 

**"Working" cues** (status `LIVE` or `ACTIVE`): the node **bobs** vertically (`baseY + sin(t·1.7 + phase)·0.32`) AND a **pulsing ground ring** (RingGeometry 2.1–2.32, node color) sits on its plane (`opacity 0.35 + 0.35·sin(t·2.4 + phase)`). Idle nodes have neither.

**Add-ports ("+")**: exactly **one** neutral `+` disc per node (21px, `rgba(9,13,17,0.72)`, border `rgba(160,175,185,0.35)`, `+` stroke `#c3ced4`; hover → opacity 1 + soft white glow), anchored in 3D to the node's side face and projected to screen each frame. **Click opens a small menu** with two items: **Add agent** (square glyph) and **Add flow link** (two-arrow glyph). Menu is `rgba(12,16,20,0.96)`, blur, 1px `rgba(150,165,175,0.28)` border, radius 7; closes on outside click.

**Chrome (HTML overlays)**
- Left rail (64px, z30): three nav icons — grid (Command), target (Mission), sliders (Setup); active item gets `rgba(255,255,255,0.08)` bg + `rgba(150,165,175,0.28)` border.
- Top bar (60px): diamond logo + `Pong` (Space Grotesk 700 18px), `Umbra v0.1` selector, `1 TEAM LIVE` pill (blinking cyan dot), `Aa`, refresh.
- **TRACKING** panel (top-left, 264px): title + 3-up stat grid (SEATS 4 / LINKS 4 / HUMAN 1) + roster rows. **Fully monochrome** — dots `#c3ced4` (active) / `#4f5c64` (idle), status `#e6eef3` / `#6f7d85`; no accent colors here.
- **YOU · HUMAN** panel (left): model selector, "No open asks", recent messages (cyan left rule), message input + cyan `Send`.
- **LEGEND** (top-right): idle link, active/job (dashed), You (amber), Orchestrator (cyan), Agent (magenta), Sub-agent (violet).
- Bottom mode toolbar: Orbit(active)/Move/Flow/Flip/Design flow… . Bottom controls toolbar: 2D / − / + / Fit / Terminals / New team (white). `Fit` resets camera, `±` dolly, `2D` toggles a top-down camera.
- Hint line: `ORBIT · ZOOM · HOVER · CLICK MARK → CARD · OPEN → TERMINAL`.

### 2. Mission (control plane dashboard)
Full-screen page (below top bar, right of rail; opaque `#06090d`).
- Title `Mission` + `CONTROL PLANE · OFFLINE`, divider.
- "What's happening" banner (cyan left rule): "Queues clear. Conductor can assign the next job."
- **KPI row (4 cards):** Open jobs `0` / In flight · Accept rate `85%` / 28 rounds · Seats `5` / 2 teams · Reject streak `0` / Current (subtle amber top border).
- **Data-viz row 1:** *Job throughput* (LAST 24H) — area+line chart, cyan; *Jobs by status* — horizontal bars (done 14, notified 9, claimed 7, dispatched 5, created 4).
- **Data-viz row 2:** *Accept rate trend* (28 rounds) — neutral line; *Seat utilization* — vertical bars C1 90 / W1 20 / W2 75 / W3 40 / W4 12.
- **ACTIVITY** log — mono rows: `job.status`/`job.claim`/`job.dispatch`/`job.created` + id + state.

### 3. Setup
Full-screen page. Title `Setup` + subtitle, divider, then cards: **New team** (lime border, `Build team` lime button), **Link terminals** (`Link…` outline-lime), **Saved teams** (`Manage`), **Control plane** (info: `pong snapshot · pong job create · pong check`). Lime accent `#c7f24d`.

### 4. Cron schedule timeline — TWO VARIANTS
Jobs (name · cadence · owner): Perimeter sweep · every 15m · ORCH C1 (cyan); Snapshot · every 30m · C1 (cyan); Telemetry sync · every 1h · AGT W2 (magenta); Log audit · every 6h · SUB Grok Audit (violet); Model warmup · daily 04:00 · AGT W1 (magenta). Each is tied to the node that fires it (matching accent).

- **Variant A — side panel** (`Agent Map.dc.html`): a delicate vertical timeline panel on the right, spine + node dots, time / cadence / owner tag per row, "NEXT" chip on the upcoming job.
- **Variant B — flat 3D ruler** (`Agent Map — Ruler.dc.html`): a thin long plane (`x=15.5`, length 36 along Z, width 2.8) lying **alongside the agents plane** like a ruler. Hour/6h/day tick marks, day date labels (`JUL 20`), a cyan **NOW** tick, cron occurrence dots along the axis, and a faint connector line from each job's next run to its owner node. **Scrollable, not zoomable**: drag anywhere on the ruler (ground-plane raycast) to pan through time while the camera stays fixed; next-run labels stack in per-job lanes (17px) to avoid overlap.

---

## Interactions & Behavior
- **Nav:** left-rail icons switch Command / Mission / Setup (view state). Mission/Setup are opaque overlays; the 3D scene pauses rendering while hidden and resizes on return.
- **Orbit/zoom/pan** via OrbitControls (Command). `Fit` → home camera; `± ` → dolly; `2D` → top-down.
- **Add-port click** → agent/flow menu; outside-click closes.
- **Ruler drag** → scroll time (disables OrbitControls only while dragging over the ruler).
- **Animations:** node yaw-billboard (per frame, +0.34 rad), working-node bob (sin, amp 0.32, speed 1.7), ground-ring pulse (sin, speed 2.4), active-link pulse sphere (lerp along link, speed 0.32), human spin+bob, `1 TEAM LIVE` dot blink (2.4s).

## State Management
- `view`: `'command' | 'mission' | 'setup'`.
- Props/tweaks: `autoOrbit` (bool), `showPlanes` (bool), `showConnectors` (bool).
- Runtime scene state: camera/controls, node groups (billboard list with baseY/active/phase), ring list, link pulses, add-ports (grp + face offset), cron ruler offset (`rulerOffsetH`) + dirty flag.
- Data the real app supplies: team roster (id, name, role, status, layer, owner links), link graph, cron definitions (name, interval, phase, owner id).

## Design Tokens
**Color**
- Background: `#05080b`; scene radial `#0b131b → #06090d`; page overlay `#06090d`.
- Panel bg `rgba(9,13,17,0.74)` (blur); card bg `rgba(10,14,18,0.6)`; input/button bg `rgba(14,19,25,0.9)`.
- Border `rgba(130,150,160,0.16)`; subtle divider `rgba(130,150,160,0.12)`.
- Text: primary `#f2f6f8` / `#eef4f7`; body `#dfe8ee` / `#c3ced4`; muted `#8b98a0` / `#7a8890` / `#6f7d85`; faint `#4f5c64`–`#5f6d75`.
- Accents: **cyan (orchestrator)** `#35d6ff` (bright `#7ee6ff`); **magenta (agent)** `#ff53c8`; **violet (sub-agent)** `#a98bff`; **amber (human/you)** `#ffb43a`; **lime (setup actions)** `#c7f24d`. Neutral grid `#2a3742`.
- Node glyphs/name white `#eef4f7`/`#f2f6f8`.

**Typography**
- Display/UI: **Space Grotesk** (400–700). Data/mono/HUD: **IBM Plex Mono** (400–600).
- Scales seen: page title 40/700; card value 40/700; section head 13/600; label eyebrow 10–13 mono tracked (0.06–0.24em); body 11–14 mono.

**Radius:** 4px (buttons/inputs/rail), 5–7px (panels/cards), 8–9px (Setup cards). **Blur:** 8–12px on glass panels.

## Assets
- three.js **r128** (`cdnjs`) + **OrbitControls r128** (`jsdelivr` examples/js) — classic global scripts. In production, use the codebase's own three.js (a current version + module OrbitControls) — the r128 pin is only to keep the prototype's global-script loading simple; expect the benign "Multiple instances of Three.js" console warning with the prototype.
- Google Fonts: Space Grotesk, IBM Plex Mono.
- All icons and role glyphs are hand-drawn SVG/canvas primitives (no image assets, no emoji).

## Files
- `SWIFT_GUIDE.md` — **read first** — native Swift (SwiftUI + SceneKit) implementation guide and three.js→SceneKit mapping.
- `Agent Map.dc.html` — full app; timeline as the **right-side panel** variant.
- `Agent Map — Ruler.dc.html` — full app; timeline as the **flat 3D ruler** variant.
- `support.js` — the prototype's Design-Component runtime (reference only; not needed in the target app).

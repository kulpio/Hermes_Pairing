# Swift Implementation Guide — Agent Map

This design was prototyped in HTML + three.js, but the **target app is Swift**. Do **not** embed the HTML in a `WKWebView` and do **not** translate three.js line-by-line. Rebuild it natively. This guide maps every concept to Swift so you can hit fidelity.

## Recommended stack
- **3D map:** `SceneKit` (`SCNView`) — closest match to the three.js scene, easy camera control, bloom for the neon glow. (RealityKit works too but is heavier for this HUD-style scene.)
- **Chrome, panels, pages:** `SwiftUI`, layered in a `ZStack` over the SceneKit view (wrap `SCNView` in a `UIViewRepresentable`/`NSViewRepresentable`).
- **Charts (Mission):** `Swift Charts`.
- **Projected HUD labels / add-ports:** SwiftUI views positioned from `SCNView.projectPoint(_:)`, updated every frame via a `CADisplayLink` (or `SCNSceneRendererDelegate.renderer(_:updateAtTime:)`) feeding an `ObservableObject`.

## Why the first pass likely failed (must-haves)
1. The 3D map **must be a real 3D scene** (SceneKit), not a screenshot, WebView, or 2D fake. Three stacked planes + 3D nodes + orbit.
2. **Yaw-billboard with offset:** each node rotates about the **vertical axis only** to face the camera **plus a fixed ~0.34 rad offset** (so it never goes flat-on and still reads as a solid). Do this manually per frame, not with a plain billboard constraint.
3. **Baked info faces:** the text/glyph panel is an **image rendered once** (Core Graphics / `ImageRenderer`) applied as a material on the node's front face — not SwiftUI text floating in space.
4. **Motion rules:** only `LIVE`/`ACTIVE` nodes **bob** and get a **pulsing ground ring**; idle nodes are still. Links have a traveling pulse.
5. **Glow** comes from **camera bloom**, not from drawing blurred sprites.

## three.js → SceneKit mapping
| Prototype (three.js) | SceneKit |
|---|---|
| `Scene` | `SCNScene` |
| `PerspectiveCamera(fov 42)` | `SCNCamera`, `fieldOfView = 42`, node at `(27,19,35)` looking at `(0,0.5,0)` |
| `OrbitControls` (damping, dist 16–90, polar 0.18–1.46) | `scnView.allowsCameraControl = true` with `defaultCameraController` limits, **or** a custom orbit controller for exact clamps; damping via `cameraController.maximumVerticalAngle`/inertia |
| `PlaneGeometry` (plane floor) | `SCNPlane`, node rotated `-90°` about X |
| `GridHelper` / dotted grid | `SCNGeometry` with `.point` primitive (point cloud) + `pointSize`; or thin `SCNPlane`s |
| rim / brackets / crosshair (`Line`) | `SCNGeometry` from `SCNGeometryElement(primitiveType: .line)` |
| `BoxGeometry` (agent cube) | `SCNBox(1.9³, chamfer 0)` |
| hex prism (orchestrator) | `SCNShape` from a **hexagon** `UIBezierPath`, `extrusionDepth = 2.0`, node rotated `-90°` X to stand vertical (r≈1.4) |
| tri prism (sub-agent) | `SCNShape` from a **triangle** `UIBezierPath`, `extrusionDepth = 1.5` (r≈1.25) |
| octahedron (human) | custom `SCNGeometry` (6 verts / 8 tri faces) or two `SCNPyramid` base-to-base (r≈1.1) |
| edge lines (EdgesGeometry) | line-primitive `SCNGeometry` of the shape's edges, **emissive** material |
| additive glow sprite | delete — use `camera.bloomIntensity`/`wantsHDR` instead |
| canvas info-face texture | `UIImage`/`NSImage` from Core Graphics, set as `material.diffuse.contents` on a front `SCNPlane` |
| `RingGeometry` ground ring | `SCNTorus`/flat ring `SCNGeometry`, emissive, opacity animated |
| render loop `requestAnimationFrame` | `SCNSceneRendererDelegate.renderer(_:updateAtTime:)` |
| `projectPoint` for HUD | `SCNView.projectPoint(_:)` → CGPoint for SwiftUI overlay |
| ground-plane raycast (ruler drag) | `scnView.unprojectPoint` at two depths → ray → intersect plane y=0 |

## Node build (per team member)
```
struct NodeSpec { let id, name, role: String; let status: Status; let layer: Layer; let x, z: Float; let color: UIColor }
```
- Position: `y = layerY + shapeHeight/2 + 0.08`. Layer Y: orchestrator +10, agents 0, sub −10.
- Group node holds: body (dark `#0A1016`, opacity 0.82), emissive edge lines (node color), front info-face plane at local +Z (offset ≈ half-depth + 0.05), drop line.
- **Billboard (every frame):** `node.eulerAngles.y = atan2(camX - node.x, camZ - node.z) + 0.34`.
- **Bob (LIVE/ACTIVE only):** `node.position.y = baseY + sin(t*1.7 + phase)*0.32`.
- **Ground ring (LIVE/ACTIVE only):** on the node's plane at (x,z); `opacity = 0.35 + 0.35*sin(t*2.4 + phase)`.

## Info face (Core Graphics, 256×200, left-aligned — Anduril hierarchy)
Draw once per node into an image:
1. bg `#070B0F` @0.92; 4px **accent spine** down the left edge (node color).
2. **glyph** top-left (~46,48), white `#EEF4F7`, 4px stroke (see glyph specs in README).
3. **status** top-right: dot + `LIVE/ACTIVE/IDLE` (idle muted `#6F7D85`, else node color).
4. divider rule y≈86 (`#82969A` @0.2).
5. **role eyebrow** — uppercase IBM Plex Mono, tracked, node color.
6. **name** — Space Grotesk 700, auto-shrink to fit ~210px, `#F2F6F8`.
Apply as unlit material (`material.lightingModel = .constant`) so colors stay exact.

## Add-ports & menu
- One 21px circular `+` per node, anchored to the node's **side face** in 3D; project to screen and render as a SwiftUI button in the overlay. Hover/press → glow.
- Tap → SwiftUI popover/menu with **Add agent** and **Add flow link**.

## Cron ruler (Variant B) — scroll, no zoom
- Thin `SCNPlane` ruler at `x≈15.5`, length 36 along Z, alongside the agents plane.
- Hour/6h/day tick lines + `NOW` tick; occurrence dots; connector line from each next-run to its owner node.
- **Drag to scroll:** `DragGesture`/pan → ray-cast to ground plane, convert Δz to Δhours, shift `rulerOffsetHours`, rebuild ticks/labels. **Disable camera control only while dragging the ruler.** No pinch-zoom.
- Date labels (`JUL 20`) and next-run labels are SwiftUI overlay text projected from 3D; stack next-run labels in per-job lanes (~17px) to avoid overlap.

## SwiftUI screen breakdown
- `RootView`: `ZStack { SceneView; OverlayHUD; if view == .mission { MissionView }; if view == .setup { SetupView } }` + `LeftRail` + `TopBar`. `@State var view: AppView`.
- `MissionView`: KPI cards (LazyVGrid), Swift Charts for throughput (AreaMark+LineMark), jobs-by-status (BarMark), accept trend (LineMark), seat utilization (BarMark), activity list.
- `SetupView`: cards with lime `#C7F24D` actions.
- Pause SceneKit rendering (`scnView.isPlaying = false`) when Mission/Setup is shown; resume + resize on return.

## Fonts & color
- Bundle & register **Space Grotesk** and **IBM Plex Mono**; use `Font.custom`. Do not substitute SF Pro — the technical mono is core to the look.
- Add a `Color(hex:)`/`UIColor(hex:)` helper; all tokens are in `README.md` → Design Tokens.

## Fidelity checklist
- [ ] Three stacked planes with dotted grids, rims, corner brackets, level labels.
- [ ] Correct silhouettes: hex prism / cube / tri prism / octahedron (human).
- [ ] Faces baked as images with spine + glyph + status + role eyebrow + name.
- [ ] Yaw-only billboard **with 0.34 rad offset**.
- [ ] Bob + pulsing ground ring on working nodes only; link pulses.
- [ ] Bloom-based glow; exact hex palette; monochrome TRACKING panel.
- [ ] One `+` per node → agent/flow menu.
- [ ] Mission charts + Setup cards; rail navigation.
- [ ] Ruler variant scrolls (drag), never zooms.

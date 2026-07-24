import AppKit

/// Canvas-style team architecture + flow editor (wizard + Design flow sheet).
/// ORCH / AGENTS / SUB bands · drag seats · + to staff · link existing seats ·
/// dotted endpoints you can reassign · click edges for kind · delete seats.
final class TeamArchCanvas: NSView {
    struct Node {
        var id: String
        var title: String
        var role: String      // conductor | worker | subagent
        var mission: String   // MissionRole raw
        var origin: CGPoint
        var parentId: String?
        var modelId: String
    }
    struct Edge {
        var id: String
        var from: String
        var to: String
        var kind: String
        var label: String
        /// Optional curve handle offset from straight midpoint (stays after drag).
        var midOffset: CGPoint = .zero
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var linkFrom: String?
    var onChanged: (() -> Void)?
    /// Optional: persist removing a live worker (Architecture sheet). Return true if OK.
    var onDeleteSeat: ((String) -> Bool)?
    var defaultModelId: String = "claude"
    /// When false (live Design flow), hide band + / node + add (topology only).
    var allowAddSeats: Bool = true
    /// Selected edge for “what they do” chrome.
    private(set) var selectedEdgeId: String?
    /// Selected seat (for link-from / highlight).
    private(set) var selectedNodeId: String?
    /// Two-click link mode: first click = from, second = to (no ⌘ required).
    private var linkMode = false

    private let bandH: CGFloat = 140
    private let nodeSize = NSSize(width: 120, height: 56)
    private let endpointR: CGFloat = 7

    /// Which end of an edge is being dragged.
    private enum Endpoint { case from, to }
    private var endpointDrag: (edgeId: String, end: Endpoint)?
    private var endpointDragPoint: NSPoint?
    private var hoverEndpoint: (edgeId: String, end: Endpoint)?
    /// Dragging the middle of a link to bend it (persisted midOffset).
    private var midDragEdgeId: String?
    private var midDragStart: NSPoint?
    private var midDragBase: CGPoint = .zero
    /// Session key for persisting seat positions on the Architecture canvas.
    var persistSession: String?

    /// Simple language so anyone can build a full architecture.
    static let kindChoices: [(id: String, title: String, short: String)] = [
        ("delegate", "Gives work (boss → agent)", "GIVES WORK"),
        ("claim", "Sends result back", "SENDS RESULT"),
        ("review", "Asks for a check", "CHECK"),
        ("peer", "Teammate handoff", "TEAMMATE"),
        ("sub", "Helper under an agent", "HELPER"),
    ]

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseDown(event)
    }

    // MARK: - Load

    func load(plan: TeamWizardPlan) {
        nodes = []
        edges = []
        let cx: CGFloat = 40
        nodes.append(Node(
            id: "c1", title: plan.conductorLabel, role: "conductor",
            mission: "orchestrator",
            origin: CGPoint(x: max(40, bounds.midX - 60), y: 36), parentId: nil,
            modelId: plan.conductor.id
        ))
        for (i, w) in plan.workers.enumerated() {
            let id = "w\(i + 1)"
            let isSub = w.parentId != nil
            let x = cx + CGFloat(i) * 150
            let y = isSub ? bandH * 2 + 40 : bandH + 40
            nodes.append(Node(
                id: id, title: w.label,
                role: isSub ? "subagent" : "worker",
                mission: w.role.rawValue,
                origin: CGPoint(x: x, y: y),
                parentId: w.parentId,
                modelId: w.type.id
            ))
        }
        if !plan.flowEdges.isEmpty {
            edges = plan.flowEdges.map {
                Edge(id: $0.id, from: $0.from, to: $0.to, kind: $0.kind, label: $0.label)
            }
        } else {
            for n in nodes where n.role != "conductor" {
                if let p = n.parentId {
                    edges.append(Edge(id: "\(p)>\(n.id)", from: p, to: n.id, kind: "sub", label: "HELPER"))
                } else {
                    edges.append(Edge(id: "c1>\(n.id)", from: "c1", to: n.id, kind: "delegate", label: "GIVES WORK"))
                }
            }
        }
        needsDisplay = true
        onChanged?()
    }

    /// Live Design flow: seats from the map + persisted flow_graph.
    func load(seats: [Seat3D], flowEdges: [FlowGraph.Edge], session: String? = nil) {
        nodes = []
        edges = []
        allowAddSeats = false
        if let session { persistSession = session }
        let savedPos = loadArchPositions()
        var agentI = 0, subI = 0
        for s in seats where s.role != "human" && s.role != "add" {
            let role = s.role == "conductor" ? "conductor"
                : (s.role == "subagent" ? "subagent" : "worker")
            let x: CGFloat
            let y: CGFloat
            if let p = savedPos[s.id] {
                x = p.x; y = p.y
            } else if role == "conductor" {
                x = max(40, bounds.midX - 60)
                y = 36
            } else if role == "subagent" {
                x = 40 + CGFloat(subI) * 150
                y = bandH * 2 + 40
                subI += 1
            } else {
                x = 40 + CGFloat(agentI) * 150
                y = bandH + 40
                agentI += 1
            }
            nodes.append(Node(
                id: s.id, title: s.title, role: role,
                mission: s.resolvedMission.rawValue,
                origin: CGPoint(x: x, y: y),
                parentId: s.parentId,
                modelId: "claude"
            ))
        }
        let mids = loadEdgeMids()
        edges = flowEdges.map { fe in
            var e = Edge(id: fe.id, from: fe.from, to: fe.to, kind: fe.kind, label: fe.label)
            if let m = mids[fe.id] { e.midOffset = m }
            if let short = Self.kindChoices.first(where: { $0.id == fe.kind })?.short {
                e.label = short
            }
            return e
        }
        needsDisplay = true
        onChanged?()
    }

    func exportEdges() -> [FlowGraph.Edge] {
        // Persist midpoints + positions when exporting
        saveArchPositions()
        saveEdgeMids()
        return edges.map {
            FlowGraph.Edge(id: $0.id, from: $0.from, to: $0.to,
                           dir: "forward", kind: $0.kind, label: $0.label)
        }
    }

    private func loadArchPositions() -> [String: CGPoint] {
        guard let session = persistSession else { return [:] }
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let raw = entry["arch_positions"] as? [String: [String: Any]] ?? [:]
        var out: [String: CGPoint] = [:]
        for (k, v) in raw {
            let x = CGFloat((v["x"] as? Double) ?? Double(v["x"] as? Int ?? 0))
            let y = CGFloat((v["y"] as? Double) ?? Double(v["y"] as? Int ?? 0))
            out[k] = CGPoint(x: x, y: y)
        }
        return out
    }

    private func saveArchPositions() {
        guard let session = persistSession else { return }
        var map: [String: [String: Any]] = [:]
        for n in nodes {
            map[n.id] = ["x": Double(n.origin.x), "y": Double(n.origin.y)]
        }
        PairState.mutate(session) { $0["arch_positions"] = map }
    }

    private func loadEdgeMids() -> [String: CGPoint] {
        guard let session = persistSession else { return [:] }
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let raw = entry["arch_edge_mids"] as? [String: [String: Any]] ?? [:]
        var out: [String: CGPoint] = [:]
        for (k, v) in raw {
            let x = CGFloat((v["x"] as? Double) ?? 0)
            let y = CGFloat((v["y"] as? Double) ?? 0)
            out[k] = CGPoint(x: x, y: y)
        }
        return out
    }

    private func saveEdgeMids() {
        guard let session = persistSession else { return }
        var map: [String: [String: Any]] = [:]
        for e in edges where e.midOffset != .zero {
            map[e.id] = ["x": Double(e.midOffset.x), "y": Double(e.midOffset.y)]
        }
        PairState.mutate(session) { $0["arch_edge_mids"] = map }
    }

    func exportWorkers() -> [(id: String, title: String, mission: String, parentId: String?, modelId: String)] {
        nodes.filter { $0.role != "conductor" }.map {
            ($0.id, $0.title, $0.mission, $0.parentId, $0.modelId)
        }
    }

    // MARK: - Geometry helpers

    private func nodeCenter(_ n: Node) -> NSPoint {
        NSPoint(x: n.origin.x + nodeSize.width / 2, y: n.origin.y + nodeSize.height / 2)
    }

    /// Surface point of the node toward the other end (so endpoints sit on the border).
    private func surfacePoint(of n: Node, toward other: NSPoint) -> NSPoint {
        let c = nodeCenter(n)
        let dx = other.x - c.x, dy = other.y - c.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        // Approximate rect half-extents along the ray
        let hw = nodeSize.width / 2, hh = nodeSize.height / 2
        let tx = abs(ux) > 1e-6 ? hw / abs(ux) : .greatestFiniteMagnitude
        let ty = abs(uy) > 1e-6 ? hh / abs(uy) : .greatestFiniteMagnitude
        let t = min(tx, ty)
        return NSPoint(x: c.x + ux * t, y: c.y + uy * t)
    }

    private func edgeEndpoints(_ e: Edge) -> (from: NSPoint, to: NSPoint)? {
        guard let a = nodes.first(where: { $0.id == e.from }),
              let b = nodes.first(where: { $0.id == e.to }) else { return nil }
        let ca = nodeCenter(a), cb = nodeCenter(b)
        return (surfacePoint(of: a, toward: cb), surfacePoint(of: b, toward: ca))
    }

    private func endpointRect(at p: NSPoint) -> NSRect {
        NSRect(x: p.x - endpointR, y: p.y - endpointR, width: endpointR * 2, height: endpointR * 2)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        bounds.fill()

        let ink = NSColor.white
        let bands: [(String, CGFloat)] = [
            ("BOSS", 12),
            ("AGENTS", bandH + 12),
            ("HELPERS", bandH * 2 + 12),
        ]
        for (idx, band) in bands.enumerated() {
            let (name, y) = band
            let r = NSRect(x: 16, y: CGFloat(y), width: bounds.width - 32, height: bandH - 24)
            NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            ink.withAlphaComponent(0.28).setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            p.lineWidth = 1
            p.stroke()
            ink.withAlphaComponent(0.12).setFill()
            var dx = r.minX + 12
            while dx < r.maxX - 8 {
                var dy = r.minY + 28
                while dy < r.maxY - 8 {
                    NSBezierPath(ovalIn: NSRect(x: dx, y: dy, width: 2, height: 2)).fill()
                    dy += 14
                }
                dx += 14
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.labelFont(10),
                .foregroundColor: ink.withAlphaComponent(0.65),
            ]
            (name as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 6), withAttributes: attrs)

            if allowAddSeats, idx > 0 {
                let plusBand = NSRect(x: r.maxX - 28, y: r.minY + 6, width: 18, height: 18)
                ink.withAlphaComponent(0.55).setStroke()
                NSBezierPath(ovalIn: plusBand).stroke()
                ("+" as NSString).draw(at: NSPoint(x: plusBand.minX + 4, y: plusBand.minY + 1), withAttributes: [
                    .font: PongTheme.font(12, weight: .bold), .foregroundColor: ink.withAlphaComponent(0.85),
                ])
            }
        }

        // Edges + dotted endpoints (curves stick via midOffset)
        for e in edges {
            guard var ends = edgeEndpoints(e) else { continue }
            if let drag = endpointDrag, drag.edgeId == e.id, let pt = endpointDragPoint {
                if drag.end == .from { ends.from = pt } else { ends.to = pt }
            }
            let p0 = ends.from, p1 = ends.to
            let midBase = NSPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            let mid = NSPoint(x: midBase.x + e.midOffset.x, y: midBase.y + e.midOffset.y)
            let path = NSBezierPath()
            path.move(to: p0)
            path.curve(to: p1, controlPoint1: mid, controlPoint2: mid)
            let sel = e.id == selectedEdgeId || midDragEdgeId == e.id
            path.lineWidth = sel ? 2.5 : (e.kind == "peer" ? 1.25 : 1.5)
            let col: NSColor = {
                switch e.kind {
                case "peer": return PongTheme.magenta.withAlphaComponent(sel ? 0.95 : 0.55)
                case "sub": return PongTheme.violet.withAlphaComponent(sel ? 0.95 : 0.55)
                case "claim", "review": return PongTheme.amber.withAlphaComponent(sel ? 0.95 : 0.55)
                default: return ink.withAlphaComponent(sel ? 0.95 : 0.55)
                }
            }()
            col.setStroke()
            path.stroke()

            let dx = p1.x - mid.x, dy = p1.y - mid.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let tip = NSPoint(x: p1.x - ux * 10, y: p1.y - uy * 10)
            let left = NSPoint(x: tip.x - ux * 8 + uy * 5, y: tip.y - uy * 8 - ux * 5)
            let right = NSPoint(x: tip.x - ux * 8 - uy * 5, y: tip.y - uy * 8 + ux * 5)
            let arr = NSBezierPath()
            arr.move(to: tip); arr.line(to: left); arr.line(to: right); arr.close()
            col.setFill(); arr.fill()

            let short = Self.kindChoices.first(where: { $0.id == e.kind })?.short ?? e.label
            let lab = short as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.mono(9, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.95),
                .backgroundColor: NSColor.black.withAlphaComponent(0.85),
            ]
            let sz = lab.size(withAttributes: attrs)
            lab.draw(at: NSPoint(x: mid.x - sz.width / 2, y: mid.y - sz.height / 2), withAttributes: attrs)

            // Mid handle — drag to bend; position sticks
            drawEndpointDot(at: mid, color: col.withAlphaComponent(0.9), hot: midDragEdgeId == e.id)
            drawEndpointDot(at: p0, color: col, hot: isHotEndpoint(e.id, .from))
            drawEndpointDot(at: p1, color: col, hot: isHotEndpoint(e.id, .to))
        }

        // Nodes
        for n in nodes {
            let r = NSRect(origin: n.origin, size: nodeSize)
            NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let edge: NSColor = {
                switch n.role {
                case "conductor": return PongTheme.blue
                case "subagent": return PongTheme.violet
                default: return PongTheme.magenta
                }
            }()
            edge.withAlphaComponent(0.7).setStroke()
            let bp = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            bp.lineWidth = 1.25
            bp.stroke()
            edge.withAlphaComponent(0.55).setFill()
            NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()

            let tAttrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.font(11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            (n.title as NSString).draw(in: NSRect(x: r.minX + 10, y: r.minY + 8, width: r.width - 36, height: 16), withAttributes: tAttrs)
            let modelLabel = n.role == "conductor" ? "orch" : WorkerType.resolved(n.modelId).label
            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.labelFont(9),
                .foregroundColor: PongTheme.textSecondary,
            ]
            ("\(n.id) · \(modelLabel)" as NSString).draw(
                in: NSRect(x: r.minX + 10, y: r.minY + 28, width: r.width - 36, height: 14),
                withAttributes: sAttrs)

            // Delete × (not on orchestrator)
            if n.role != "conductor" {
                let del = deleteRect(for: n)
                let hot = selectedNodeId == n.id
                NSColor(calibratedWhite: 1, alpha: hot ? 0.22 : 0.12).setFill()
                NSBezierPath(ovalIn: del).fill()
                let xAttrs: [NSAttributedString.Key: Any] = [
                    .font: PongTheme.font(10, weight: .bold),
                    .foregroundColor: ink.withAlphaComponent(0.85),
                ]
                ("×" as NSString).draw(at: NSPoint(x: del.minX + 3.5, y: del.minY + 0.5), withAttributes: xAttrs)
            }

            if allowAddSeats {
                let plus = plusRect(for: n)
                ink.withAlphaComponent(0.7).setStroke()
                NSBezierPath(ovalIn: plus).stroke()
                ("+" as NSString).draw(at: NSPoint(x: plus.minX + 3, y: plus.minY + 1), withAttributes: [
                    .font: PongTheme.font(11, weight: .bold), .foregroundColor: ink,
                ])
            }
        }

        // Selection / link-from ring
        for n in nodes {
            let highlight = n.id == selectedNodeId || n.id == linkFrom
            if highlight {
                let r = NSRect(origin: n.origin, size: nodeSize)
                let col = linkFrom == n.id ? PongTheme.blue : PongTheme.limeAction
                col.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
                p.lineWidth = 2.5
                p.stroke()
            }
        }

        // Link mode badge
        if linkMode || linkFrom != nil {
            let msg = linkFrom == nil
                ? "LINK · click source seat"
                : "LINK · click destination seat  (esc cancel)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.mono(10, weight: .semibold),
                .foregroundColor: PongTheme.blue,
                .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            ]
            (msg as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 18), withAttributes: attrs)
        } else if endpointDrag != nil {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.mono(10, weight: .semibold),
                .foregroundColor: PongTheme.amber,
                .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            ]
            ("DRAG END · drop on a seat to reassign" as NSString)
                .draw(at: NSPoint(x: 24, y: bounds.height - 18), withAttributes: attrs)
        }
    }

    private func isHotEndpoint(_ edgeId: String, _ end: Endpoint) -> Bool {
        if let h = hoverEndpoint, h.edgeId == edgeId, h.end == end { return true }
        if let d = endpointDrag, d.edgeId == edgeId, d.end == end { return true }
        return false
    }

    private func drawEndpointDot(at p: NSPoint, color: NSColor, hot: Bool) {
        let r = endpointRect(at: p)
        // Hollow dotted ring
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = hot ? 2.0 : 1.4
        let dash: [CGFloat] = [2.5, 2.0]
        ring.setLineDash(dash, count: 2, phase: 0)
        color.withAlphaComponent(hot ? 1 : 0.85).setStroke()
        ring.stroke()
        // Soft fill so it reads on black
        color.withAlphaComponent(hot ? 0.35 : 0.18).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
    }

    private func plusRect(for n: Node) -> NSRect {
        let r = NSRect(origin: n.origin, size: nodeSize)
        return NSRect(x: r.maxX - 22, y: r.minY + 6, width: 16, height: 16)
    }

    private func deleteRect(for n: Node) -> NSRect {
        let r = NSRect(origin: n.origin, size: nodeSize)
        // Bottom-right when + is present; top-right otherwise
        if allowAddSeats {
            return NSRect(x: r.maxX - 22, y: r.maxY - 22, width: 16, height: 16)
        }
        return NSRect(x: r.maxX - 22, y: r.minY + 6, width: 16, height: 16)
    }

    // MARK: - Hit testing

    private func nodeAt(_ p: NSPoint) -> Node? {
        for n in nodes.reversed() {
            let r = NSRect(origin: n.origin, size: nodeSize)
            if r.contains(p) { return n }
        }
        return nil
    }

    private func endpointHit(at p: NSPoint) -> (edgeId: String, end: Endpoint)? {
        var best: (String, Endpoint, CGFloat)?
        for e in edges {
            guard let ends = edgeEndpoints(e) else { continue }
            let dFrom = hypot(p.x - ends.from.x, p.y - ends.from.y)
            let dTo = hypot(p.x - ends.to.x, p.y - ends.to.y)
            if dFrom <= endpointR + 4, best == nil || dFrom < best!.2 {
                best = (e.id, .from, dFrom)
            }
            if dTo <= endpointR + 4, best == nil || dTo < best!.2 {
                best = (e.id, .to, dTo)
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func edgeHit(at p: NSPoint, threshold: CGFloat = 6) -> String? {
        if nodeAt(p) != nil { return nil }
        if endpointHit(at: p) != nil { return nil }
        var best: (String, CGFloat)?
        for e in edges {
            guard let ends = edgeEndpoints(e) else { continue }
            let p0 = ends.from, p1 = ends.to
            if hypot(p.x - p0.x, p.y - p0.y) < 20 { continue }
            if hypot(p.x - p1.x, p.y - p1.y) < 20 { continue }
            let d = distancePointToSegment(p, p0, p1)
            if d < threshold, best == nil || d < best!.1 {
                best = (e.id, d)
            }
        }
        return best?.0
    }

    private func distancePointToSegment(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let apx = p.x - a.x, apy = p.y - a.y
        let ab2 = abx * abx + aby * aby
        if ab2 < 1e-6 { return hypot(apx, apy) }
        var t = (apx * abx + apy * aby) / ab2
        t = max(0, min(1, t))
        let cx = a.x + t * abx, cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    // MARK: - Interaction

    private var dragId: String?
    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var didDrag = false

    private func handleMouseDown(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false
        endpointDrag = nil
        endpointDragPoint = nil

        // Band-level +
        if allowAddSeats {
            let bands: [(CGFloat, String)] = [(bandH + 12, "worker"), (bandH * 2 + 12, "subagent")]
            for (by, kind) in bands {
                let r = NSRect(x: 16, y: by, width: bounds.width - 32, height: bandH - 24)
                let plusBand = NSRect(x: r.maxX - 28, y: r.minY + 6, width: 18, height: 18)
                if plusBand.contains(p) {
                    addSeat(kind: kind, parentId: kind == "subagent" ? pickParentForSub() : nil, near: nil)
                    return
                }
            }
        }

        // Bend handle (mid of link) — drag so the curve sticks
        if let midHit = midHit(at: p) {
            midDragEdgeId = midHit
            midDragStart = p
            if let e = edges.first(where: { $0.id == midHit }) {
                midDragBase = e.midOffset
            }
            selectedEdgeId = midHit
            selectedNodeId = nil
            needsDisplay = true
            return
        }

        // Endpoint handles — reassign links by dragging dots
        if let hit = endpointHit(at: p) {
            endpointDrag = hit
            endpointDragPoint = p
            selectedEdgeId = hit.edgeId
            selectedNodeId = nil
            needsDisplay = true
            return
        }

        // Seats
        if let n = nodeAt(p) {
            // Delete ×
            if n.role != "conductor", deleteRect(for: n).contains(p) {
                deleteSeat(id: n.id)
                return
            }
            // + add / link menu
            if allowAddSeats, plusRect(for: n).contains(p) {
                handlePlus(on: n)
                return
            }

            // Two-click link mode (or ⌘-click): from → destination (existing seats only)
            let wantLink = linkMode || event.modifierFlags.contains(.command)
            if wantLink {
                completeOrStartLink(to: n)
                return
            }

            // Double-click: model (CLI) for non-boss when adding seats
            if event.clickCount == 2, allowAddSeats, n.role != "conductor" {
                changeModel(for: n.id)
                return
            }

            selectedNodeId = n.id
            selectedEdgeId = nil
            dragId = n.id
            dragStart = p
            originStart = n.origin
            needsDisplay = true
            return
        }

        // Mid-edge edit
        if let eid = edgeHit(at: p) {
            selectedEdgeId = eid
            selectedNodeId = nil
            needsDisplay = true
            editEdgeKind(id: eid)
            return
        }

        if event.clickCount == 1 {
            linkFrom = nil
            selectedEdgeId = nil
            selectedNodeId = nil
        }
        needsDisplay = true
    }

    private func handlePlus(on n: Node) {
        if n.role == "conductor" {
            addSeat(kind: "worker", parentId: nil, near: n, linkFromId: "c1", linkKind: "delegate")
            return
        }
        if n.role == "worker" {
            guard let choice = pickAttachMode(for: n) else { return }
            switch choice {
            case .linkExisting:
                // Start link from this seat — user clicks destination (no new agent)
                linkMode = true
                linkFrom = n.id
                selectedNodeId = n.id
                needsDisplay = true
            case .peerAgent:
                addSeat(kind: "worker", parentId: nil, near: n,
                        linkFromId: n.id, linkKind: "peer")
            case .subAgent:
                addSeat(kind: "subagent", parentId: n.id, near: n,
                        linkFromId: n.id, linkKind: "sub")
            }
            return
        }
        // Sub-agent +
        guard let choice = pickSubPlusMode(for: n) else { return }
        switch choice {
        case .linkExisting:
            linkMode = true
            linkFrom = n.id
            selectedNodeId = n.id
            needsDisplay = true
        case .newSub:
            let parent = n.parentId ?? n.id
            addSeat(kind: "subagent", parentId: parent, near: n,
                    linkFromId: parent, linkKind: "sub")
        }
    }

    /// Start or finish a directed link between two **existing** seats.
    private func completeOrStartLink(to n: Node) {
        if linkFrom == nil {
            linkFrom = n.id
            selectedNodeId = n.id
            needsDisplay = true
            return
        }
        if linkFrom == n.id {
            linkFrom = nil
            needsDisplay = true
            return
        }
        let from = linkFrom!
        let fromRole = nodes.first(where: { $0.id == from })?.role ?? ""
        let defaultKind: String = {
            if n.role == "subagent" || fromRole == "subagent" { return "sub" }
            if fromRole == "worker" && n.role == "worker" { return "peer" }
            return "delegate"
        }()
        guard let kind = pickKind(defaultId: defaultKind) else {
            linkFrom = nil
            needsDisplay = true
            return
        }
        let short = Self.kindChoices.first(where: { $0.id == kind })?.short ?? kind.uppercased()
        var edge = Edge(
            id: "\(from)>\(n.id):\(kind)", from: from, to: n.id,
            kind: kind, label: short
        )
        // Claim/review point up; delegate/sub point down — flip endpoints if needed
        edge = orientCanvasEdge(edge)
        edges.removeAll { $0.from == edge.from && $0.to == edge.to && $0.kind == edge.kind }
        edges.removeAll { $0.from == from && $0.to == n.id } // drop undirected pair we just replaced
        edges.append(edge)
        if edge.kind == "sub", let i = nodes.firstIndex(where: { $0.id == edge.to }) {
            nodes[i].parentId = edge.from
            nodes[i].role = "subagent"
            nodes[i].origin.y = bandH * 2 + 40
        }
        if edge.kind == "peer", !edges.contains(where: { $0.from == "c1" && $0.to == edge.to }) {
            edges.append(Edge(id: "c1>\(edge.to):delegate", from: "c1", to: edge.to, kind: "delegate", label: "GIVES WORK"))
        }
        linkFrom = nil
        linkMode = false
        selectedNodeId = n.id
        onChanged?()
        needsDisplay = true
    }

    func setLinkMode(_ on: Bool) {
        linkMode = on
        if !on { linkFrom = nil }
        needsDisplay = true
    }

    var isLinkMode: Bool { linkMode || linkFrom != nil }

    override func keyDown(with event: NSEvent) {
        // Esc
        if event.keyCode == 53 {
            linkFrom = nil
            linkMode = false
            endpointDrag = nil
            endpointDragPoint = nil
            selectedEdgeId = nil
            needsDisplay = true
            return
        }
        // Delete / Forward Delete
        if event.keyCode == 51 || event.keyCode == 117 {
            if let eid = selectedEdgeId {
                edges.removeAll { $0.id == eid }
                selectedEdgeId = nil
                onChanged?()
                needsDisplay = true
                return
            }
            if let nid = selectedNodeId, nid != "c1",
               nodes.first(where: { $0.id == nid })?.role != "conductor" {
                deleteSeat(id: nid)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func pickParentForSub() -> String? {
        nodes.first(where: { $0.role == "worker" })?.id
            ?? nodes.first(where: { $0.role == "conductor" })?.id
    }

    private enum AttachMode { case linkExisting, peerAgent, subAgent }
    private enum SubPlusMode { case linkExisting, newSub }

    private func pickAttachMode(for n: Node) -> AttachMode? {
        let a = NSAlert()
        a.messageText = "“\(n.title)”"
        a.informativeText =
            "Simple choices:\n\n" +
            "• Connect to someone already here\n" +
            "• New teammate (same row)\n" +
            "• New helper under this agent"
        a.addButton(withTitle: "Connect…")
        a.addButton(withTitle: "New teammate")
        a.addButton(withTitle: "New helper")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn: return .linkExisting
        case .alertSecondButtonReturn: return .peerAgent
        case .alertThirdButtonReturn: return .subAgent
        default: return nil
        }
    }

    private func pickSubPlusMode(for n: Node) -> SubPlusMode? {
        let a = NSAlert()
        a.messageText = "“\(n.title)”"
        a.informativeText = "Link this seat to another existing agent, or add a new sub under it."
        a.addButton(withTitle: "Link to existing…")
        a.addButton(withTitle: "New sub-agent")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn: return .linkExisting
        case .alertSecondButtonReturn: return .newSub
        default: return nil
        }
    }

    private func pickModel() -> String? {
        let a = NSAlert()
        a.messageText = "Choose model"
        a.informativeText = "Which CLI should this seat run?"
        let types = WorkerType.all.filter { $0.id != "custom" }
        for t in types { a.addButton(withTitle: t.label) }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        guard idx >= 0, idx < types.count else { return nil }
        return types[idx].id
    }

    private func pickKind(defaultId: String) -> String? {
        let a = NSAlert()
        a.messageText = "What does this connection do?"
        a.informativeText = "Who talks to whom — and how. (Pick destination seat after source — no new agent is created.)"
        for k in Self.kindChoices {
            a.addButton(withTitle: k.title)
        }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        guard idx >= 0, idx < Self.kindChoices.count else { return nil }
        return Self.kindChoices[idx].id
    }

    /// Apply semantic orientation (claim↑, delegate↓) using seat roles.
    private func orientCanvasEdge(_ e: Edge) -> Edge {
        let roleOf: (String) -> String = { id in
            self.nodes.first(where: { $0.id == id })?.role ?? "worker"
        }
        let ends = FlowGraph.orientEndpoints(from: e.from, to: e.to, kind: e.kind, roleOf: roleOf)
        var out = e
        out.from = ends.from
        out.to = ends.to
        out.id = "\(out.from)>\(out.to):\(out.kind)"
        return out
    }

    private func flipCanvasEdge(at i: Int) {
        guard edges.indices.contains(i) else { return }
        var e = edges[i]
        let tmp = e.from
        e.from = e.to
        e.to = tmp
        e.id = "\(e.from)>\(e.to):\(e.kind)"
        edges[i] = e
        selectedEdgeId = e.id
        onChanged?()
        needsDisplay = true
    }

    private func editEdgeKind(id: String) {
        guard let i = edges.firstIndex(where: { $0.id == id }) else { return }
        let cur = edges[i]
        let a = NSAlert()
        a.messageText = "Connection: \(cur.from) → \(cur.to)"
        a.informativeText =
            "What should happen on this link?\n" +
            "Claim / Review auto-point upward (agent → orch). Delegate / Sub point downward.\n" +
            "Flip reverses the arrow. Drag dotted ends to reassign seats."
        for k in Self.kindChoices {
            a.addButton(withTitle: k.title)
        }
        a.addButton(withTitle: "Flip direction")
        a.addButton(withTitle: "Delete link")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        if idx >= 0, idx < Self.kindChoices.count {
            let k = Self.kindChoices[idx]
            edges[i].kind = k.id
            edges[i].label = k.short
            edges[i] = orientCanvasEdge(edges[i])
            selectedEdgeId = edges[i].id
            if edges[i].kind == "sub", let ti = nodes.firstIndex(where: { $0.id == edges[i].to }) {
                nodes[ti].parentId = edges[i].from
                nodes[ti].role = "subagent"
            }
            onChanged?()
        } else if idx == Self.kindChoices.count {
            // Flip direction
            flipCanvasEdge(at: i)
            return
        } else if idx == Self.kindChoices.count + 1 {
            edges.remove(at: i)
            selectedEdgeId = nil
            onChanged?()
        }
        needsDisplay = true
    }

    private func changeModel(for nodeId: String) {
        guard let mid = pickModel(),
              let i = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        nodes[i].modelId = mid
        let t = WorkerType.resolved(mid)
        if nodes[i].title.hasPrefix("Agent ") || nodes[i].title.hasPrefix("Sub ") {
            nodes[i].title = t.label
        }
        needsDisplay = true
        onChanged?()
    }

    /// Remove a non-orchestrator seat and its edges.
    func deleteSeat(id: String) {
        guard id != "c1",
              let n = nodes.first(where: { $0.id == id }),
              n.role != "conductor" else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(n.title)”?"
        a.informativeText = allowAddSeats
            ? "Deletes this agent and every link touching it from the team design."
            : "Removes this seat from the team and its architecture links."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        if let external = onDeleteSeat {
            guard external(id) else { return }
        }
        // Reparent kids that pointed here
        for i in nodes.indices where nodes[i].parentId == id {
            nodes[i].parentId = nil
            if nodes[i].role == "subagent" {
                nodes[i].role = "worker"
                nodes[i].origin.y = bandH + 40
            }
        }
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
        if selectedNodeId == id { selectedNodeId = nil }
        onChanged?()
        needsDisplay = true
    }

    private func addSeat(kind: String, parentId: String?, near: Node?,
                         linkFromId: String? = nil, linkKind: String? = nil) {
        guard let modelId = pickModel() else { return }
        let t = WorkerType.resolved(modelId)
        let nWorkers = nodes.filter { $0.role != "conductor" }.count
        let id = "w\(nWorkers + 1)"
        let isSub = kind == "subagent"
        let yBase: CGFloat = isSub ? bandH * 2 + 40 : bandH + 40
        let x: CGFloat
        if let near {
            x = min(bounds.width - 140, near.origin.x + (isSub ? 20 : 140))
        } else {
            x = 40 + CGFloat(nWorkers) * 40
        }
        let title = isSub ? "Sub · \(t.label)" : t.label
        nodes.append(Node(
            id: id, title: title,
            role: isSub ? "subagent" : "worker",
            mission: isSub ? "researcher" : "coder",
            origin: CGPoint(x: max(20, x), y: yBase),
            parentId: isSub ? parentId : nil,
            modelId: modelId
        ))
        if let from = linkFromId, let kindEdge = linkKind {
            let short = Self.kindChoices.first(where: { $0.id == kindEdge })?.short ?? kindEdge.uppercased()
            edges.append(Edge(id: "\(from)>\(id):\(kindEdge)", from: from, to: id, kind: kindEdge, label: short))
            if kindEdge == "peer" {
                edges.append(Edge(id: "c1>\(id):delegate", from: "c1", to: id, kind: "delegate", label: "GIVES WORK"))
            }
        } else if isSub, let p = parentId {
            edges.append(Edge(id: "\(p)>\(id):sub", from: p, to: id, kind: "sub", label: "HELPER"))
        } else {
            edges.append(Edge(id: "c1>\(id):delegate", from: "c1", to: id, kind: "delegate", label: "GIVES WORK"))
        }
        needsDisplay = true
        onChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if let eid = midDragEdgeId, let start = midDragStart,
           let ei = edges.firstIndex(where: { $0.id == eid }) {
            let dx = p.x - start.x, dy = p.y - start.y
            edges[ei].midOffset = CGPoint(x: midDragBase.x + dx, y: midDragBase.y + dy)
            didDrag = true
            needsDisplay = true
            return
        }

        // Reassign edge endpoint
        if let drag = endpointDrag {
            endpointDragPoint = p
            hoverEndpoint = drag
            didDrag = true
            needsDisplay = true
            return
        }

        guard let dragId, let dragStart, let originStart,
              let i = nodes.firstIndex(where: { $0.id == dragId }) else { return }
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if hypot(dx, dy) > 3 { didDrag = true }
        var o = CGPoint(x: originStart.x + dx, y: originStart.y + dy)
        o.x = max(20, min(bounds.width - nodeSize.width - 20, o.x))
        o.y = max(20, min(bounds.height - nodeSize.height - 20, o.y))
        nodes[i].origin = o
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if midDragEdgeId != nil {
            midDragEdgeId = nil
            midDragStart = nil
            saveEdgeMids()
            onChanged?()
            needsDisplay = true
            return
        }

        // Finish endpoint reassignment
        if let drag = endpointDrag {
            if let target = nodeAt(p),
               let ei = edges.firstIndex(where: { $0.id == drag.edgeId }) {
                let otherId = drag.end == .from ? edges[ei].to : edges[ei].from
                if target.id != otherId {
                    if drag.end == .from {
                        edges[ei].from = target.id
                    } else {
                        edges[ei].to = target.id
                    }
                    let k = edges[ei].kind
                    edges[ei].id = "\(edges[ei].from)>\(edges[ei].to):\(k)"
                    // Nesting: if sub edge, update parent
                    if k == "sub", let ti = nodes.firstIndex(where: { $0.id == edges[ei].to }) {
                        nodes[ti].parentId = edges[ei].from
                        nodes[ti].role = "subagent"
                        nodes[ti].origin.y = bandH * 2 + 40
                    }
                    onChanged?()
                }
            }
            endpointDrag = nil
            endpointDragPoint = nil
            hoverEndpoint = nil
            needsDisplay = true
            return
        }

        // Click (no drag) → edit name + purpose + link (one place for the wizard flow)
        if let dragId, !didDrag {
            editSeat(id: dragId)
            self.dragId = nil
            dragStart = nil
            originStart = nil
            return
        }

        // Snap Y to band only. Preserve peer/custom edges — never force c1-only on move.
        if let dragId, let i = nodes.firstIndex(where: { $0.id == dragId }),
           nodes[i].role != "conductor" {
            let y = nodes[i].origin.y
            let midSub = bandH * 2 + bandH / 2
            let wasRole = nodes[i].role

            if y >= midSub - 30 {
                nodes[i].origin.y = bandH * 2 + 40
                if wasRole != "subagent" {
                    nodes[i].role = "subagent"
                    let inbound = edges.first(where: {
                        $0.to == dragId && ($0.kind == "peer" || $0.kind == "sub") && $0.from != "c1"
                    })
                    nodes[i].parentId = inbound?.from ?? pickParentForSub()
                    if let p = nodes[i].parentId {
                        edges.removeAll { $0.to == dragId && ($0.kind == "delegate" || $0.kind == "sub") }
                        if !edges.contains(where: { $0.from == p && $0.to == dragId }) {
                            edges.append(Edge(id: "\(p)>\(dragId):sub", from: p, to: dragId,
                                              kind: "sub", label: "HELPER"))
                        } else if let ei = edges.firstIndex(where: { $0.from == p && $0.to == dragId }) {
                            edges[ei].kind = "sub"
                            edges[ei].label = "HELPER"
                        }
                    }
                }
            } else {
                nodes[i].origin.y = bandH + 40
                if wasRole == "subagent" {
                    nodes[i].role = "worker"
                    nodes[i].parentId = nil
                    edges.removeAll { $0.to == dragId && $0.kind == "sub" }
                    if !edges.contains(where: { $0.from == "c1" && $0.to == dragId }) {
                        edges.append(Edge(id: "c1>\(dragId):delegate", from: "c1", to: dragId,
                                          kind: "delegate", label: "GIVES WORK"))
                    }
                }
            }
            needsDisplay = true
            saveArchPositions()
        }
        dragId = nil
        dragStart = nil
        originStart = nil
        onChanged?()
    }

    private func midHit(at p: NSPoint) -> String? {
        for e in edges {
            guard let ends = edgeEndpoints(e) else { continue }
            let midBase = NSPoint(
                x: (ends.from.x + ends.to.x) / 2,
                y: (ends.from.y + ends.to.y) / 2
            )
            let mid = NSPoint(x: midBase.x + e.midOffset.x, y: midBase.y + e.midOffset.y)
            if hypot(p.x - mid.x, p.y - mid.y) <= endpointR + 4 {
                return e.id
            }
        }
        return nil
    }

    /// Click a seat → name + purpose (what they do) + start a link. One place, no second wizard page required.
    private func editSeat(id: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let n = nodes[i]
        let a = NSAlert()
        a.messageText = n.role == "conductor" ? "Boss (orchestrator)" : "Agent · \(n.id)"
        a.informativeText = n.role == "conductor"
            ? "Name the boss. They plan and give work — they don’t code while BRIDGE_ON."
            : "Name them · pick what they do · then connect with Link if you want."

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: n.role == "conductor" ? 40 : 78))
        let name = NSTextField(string: n.title)
        name.placeholderString = "Display name"
        name.frame = NSRect(x: 0, y: n.role == "conductor" ? 8 : 46, width: 300, height: 26)
        box.addSubview(name)

        var purposePop: NSPopUpButton?
        if n.role != "conductor" {
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 8, width: 300, height: 26), pullsDown: false)
            for r in MissionRole.allCases where r != .orchestrator {
                pop.addItem(withTitle: "\(r.title) — \(r.blurb)")
                pop.lastItem?.representedObject = r.rawValue
            }
            if let mr = MissionRole.parse(n.mission),
               let idx = MissionRole.allCases.filter({ $0 != .orchestrator }).firstIndex(of: mr) {
                pop.selectItem(at: idx)
            }
            box.addSubview(pop)
            purposePop = pop
        }
        a.accessoryView = box
        a.addButton(withTitle: "Save")
        if n.role != "conductor" {
            a.addButton(withTitle: "Save + Link…")
        }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        // Cancel is last button
        let cancelIdx = n.role == "conductor" ? 1 : 2
        if idx < 0 || idx >= cancelIdx { return }

        let t = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { nodes[i].title = t }
        if let pop = purposePop,
           let raw = pop.selectedItem?.representedObject as? String,
           let mr = MissionRole.parse(raw) {
            nodes[i].mission = mr.rawValue
        }
        selectedNodeId = id
        onChanged?()
        needsDisplay = true

        // Save + Link (second button on non-boss)
        if n.role != "conductor", idx == 1 {
            linkFrom = id
            linkMode = true
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = endpointHit(at: p)
        if hit?.edgeId != hoverEndpoint?.edgeId || hit?.end != hoverEndpoint?.end {
            hoverEndpoint = hit
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }
}

import AppKit

/// Canvas-style team architecture + flow editor (wizard + Design flow sheet).
/// ORCH / AGENTS / SUB bands · drag seats · + to staff · click edges to set “what they do”.
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
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var linkFrom: String?
    var onChanged: (() -> Void)?
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

    static let kindChoices: [(id: String, title: String, short: String)] = [
        ("delegate", "Delegate — assigns jobs", "DELEGATE"),
        ("claim", "Claim — reports done", "CLAIM"),
        ("review", "Review — asks review", "REVIEW"),
        ("peer", "Peer handoff — agent → agent", "PEER"),
        ("sub", "Sub-link — agent → sub", "SUB · LINK"),
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
        // Prefer saved flow edges when present
        if !plan.flowEdges.isEmpty {
            edges = plan.flowEdges.map {
                Edge(id: $0.id, from: $0.from, to: $0.to, kind: $0.kind, label: $0.label)
            }
        } else {
            for n in nodes where n.role != "conductor" {
                if let p = n.parentId {
                    edges.append(Edge(id: "\(p)>\(n.id)", from: p, to: n.id, kind: "sub", label: "SUB · LINK"))
                } else {
                    edges.append(Edge(id: "c1>\(n.id)", from: "c1", to: n.id, kind: "delegate", label: "DELEGATE"))
                }
            }
        }
        needsDisplay = true
        onChanged?()
    }

    /// Live Design flow: seats from the map + persisted flow_graph.
    func load(seats: [Seat3D], flowEdges: [FlowGraph.Edge]) {
        nodes = []
        edges = []
        allowAddSeats = false
        var agentI = 0, subI = 0
        for s in seats where s.role != "human" && s.role != "add" {
            let role = s.role == "conductor" ? "conductor"
                : (s.role == "subagent" ? "subagent" : "worker")
            let x: CGFloat
            let y: CGFloat
            if role == "conductor" {
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
        edges = flowEdges.map {
            Edge(id: $0.id, from: $0.from, to: $0.to, kind: $0.kind, label: $0.label)
        }
        needsDisplay = true
        onChanged?()
    }

    func exportEdges() -> [FlowGraph.Edge] {
        edges.map {
            FlowGraph.Edge(id: $0.id, from: $0.from, to: $0.to,
                           dir: "forward", kind: $0.kind, label: $0.label)
        }
    }

    func exportWorkers() -> [(id: String, title: String, mission: String, parentId: String?, modelId: String)] {
        nodes.filter { $0.role != "conductor" }.map {
            ($0.id, $0.title, $0.mission, $0.parentId, $0.modelId)
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        bounds.fill()

        let ink = NSColor.white
        let bands: [(String, CGFloat)] = [
            ("ORCH", 12),
            ("AGENTS", bandH + 12),
            ("SUB", bandH * 2 + 12),
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

        // Edges
        for e in edges {
            guard let a = nodes.first(where: { $0.id == e.from }),
                  let b = nodes.first(where: { $0.id == e.to }) else { continue }
            let p0 = NSPoint(x: a.origin.x + nodeSize.width / 2, y: a.origin.y + nodeSize.height / 2)
            let p1 = NSPoint(x: b.origin.x + nodeSize.width / 2, y: b.origin.y + nodeSize.height / 2)
            let path = NSBezierPath()
            path.move(to: p0)
            path.line(to: p1)
            let sel = e.id == selectedEdgeId
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
            // Arrow tip
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let tip = NSPoint(x: p1.x - ux * 8, y: p1.y - uy * 8)
            let left = NSPoint(x: tip.x - ux * 8 + uy * 5, y: tip.y - uy * 8 - ux * 5)
            let right = NSPoint(x: tip.x - ux * 8 - uy * 5, y: tip.y - uy * 8 + ux * 5)
            let arr = NSBezierPath()
            arr.move(to: tip); arr.line(to: left); arr.line(to: right); arr.close()
            col.setFill(); arr.fill()

            let mid = NSPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            let short = Self.kindChoices.first(where: { $0.id == e.kind })?.short ?? e.label
            let lab = short as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.mono(9, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.95),
                .backgroundColor: NSColor.black.withAlphaComponent(0.85),
            ]
            let sz = lab.size(withAttributes: attrs)
            lab.draw(at: NSPoint(x: mid.x - sz.width / 2, y: mid.y - sz.height / 2), withAttributes: attrs)
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
            (n.title as NSString).draw(in: NSRect(x: r.minX + 10, y: r.minY + 8, width: r.width - 28, height: 16), withAttributes: tAttrs)
            let modelLabel = n.role == "conductor" ? "orch" : WorkerType.resolved(n.modelId).label
            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.labelFont(9),
                .foregroundColor: PongTheme.textSecondary,
            ]
            ("\(n.id) · \(modelLabel)" as NSString).draw(
                in: NSRect(x: r.minX + 10, y: r.minY + 28, width: r.width - 28, height: 14),
                withAttributes: sAttrs)

            if allowAddSeats {
                let plus = NSRect(x: r.maxX - 22, y: r.minY + 6, width: 16, height: 16)
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
                ? "LINK MODE · click source seat"
                : "LINK MODE · click target seat  (esc cancel)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: PongTheme.mono(10, weight: .semibold),
                .foregroundColor: PongTheme.blue,
                .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            ]
            (msg as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 18), withAttributes: attrs)
        }
    }

    // MARK: - Hit testing

    private func nodeAt(_ p: NSPoint) -> Node? {
        // Topmost: reverse so last-drawn wins
        for n in nodes.reversed() {
            let r = NSRect(origin: n.origin, size: nodeSize)
            if r.contains(p) { return n }
        }
        return nil
    }

    private func edgeHit(at p: NSPoint, threshold: CGFloat = 6) -> String? {
        // Never steal clicks that land on a seat
        if nodeAt(p) != nil { return nil }
        var best: (String, CGFloat)?
        for e in edges {
            guard let a = nodes.first(where: { $0.id == e.from }),
                  let b = nodes.first(where: { $0.id == e.to }) else { continue }
            let p0 = NSPoint(x: a.origin.x + nodeSize.width / 2, y: a.origin.y + nodeSize.height / 2)
            let p1 = NSPoint(x: b.origin.x + nodeSize.width / 2, y: b.origin.y + nodeSize.height / 2)
            // Ignore hits near endpoints (those belong to seats)
            if hypot(p.x - p0.x, p.y - p0.y) < 36 { continue }
            if hypot(p.x - p1.x, p.y - p1.y) < 36 { continue }
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

        // Seats first — edges used to steal almost every click along orch→agent lines
        if let n = nodeAt(p) {
            let r = NSRect(origin: n.origin, size: nodeSize)
            if allowAddSeats {
                let plus = NSRect(x: r.maxX - 22, y: r.minY + 6, width: 16, height: 16)
                if plus.contains(p) {
                    if n.role == "conductor" {
                        addSeat(kind: "worker", parentId: nil, near: n, linkFromId: "c1", linkKind: "delegate")
                    } else if n.role == "worker" {
                        guard let choice = pickAttachMode(for: n) else { return }
                        switch choice {
                        case .peerAgent:
                            addSeat(kind: "worker", parentId: nil, near: n,
                                    linkFromId: n.id, linkKind: "peer")
                        case .subAgent:
                            addSeat(kind: "subagent", parentId: n.id, near: n,
                                    linkFromId: n.id, linkKind: "sub")
                        }
                    } else {
                        let parent = n.parentId ?? n.id
                        addSeat(kind: "subagent", parentId: parent, near: n,
                                linkFromId: parent, linkKind: "sub")
                    }
                    return
                }
            }

            // Two-click link mode (or ⌘-click): from → to
            let wantLink = linkMode || event.modifierFlags.contains(.command)
            if wantLink {
                completeOrStartLink(to: n)
                return
            }

            if event.clickCount == 2, allowAddSeats, n.role != "conductor" {
                changeModel(for: n.id)
                return
            }

            // Select + prepare drag
            selectedNodeId = n.id
            selectedEdgeId = nil
            dragId = n.id
            dragStart = p
            originStart = n.origin
            needsDisplay = true
            return
        }

        // Edges only in empty space (mid-segment)
        if let eid = edgeHit(at: p) {
            selectedEdgeId = eid
            selectedNodeId = nil
            needsDisplay = true
            editEdgeKind(id: eid)
            return
        }

        // Empty canvas: cancel link mode selection
        if event.clickCount == 1 {
            linkFrom = nil
            selectedEdgeId = nil
            // Don't clear selectedNodeId on empty click if we want multi-select — clear for clarity
            selectedNodeId = nil
        }
        needsDisplay = true
    }

    /// Start or finish a directed link between two seats.
    private func completeOrStartLink(to n: Node) {
        if linkFrom == nil {
            linkFrom = n.id
            selectedNodeId = n.id
            needsDisplay = true
            return
        }
        if linkFrom == n.id {
            // Click same seat = cancel
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
        edges.removeAll { $0.from == from && $0.to == n.id }
        let short = Self.kindChoices.first(where: { $0.id == kind })?.short ?? kind.uppercased()
        edges.append(Edge(
            id: "\(from)>\(n.id)", from: from, to: n.id,
            kind: kind, label: short
        ))
        if kind == "sub", let i = nodes.firstIndex(where: { $0.id == n.id }) {
            nodes[i].parentId = from
            nodes[i].role = "subagent"
            nodes[i].origin.y = bandH * 2 + 40
        }
        // Keep orch delegate for peers
        if kind == "peer", !edges.contains(where: { $0.from == "c1" && $0.to == n.id }) {
            edges.append(Edge(id: "c1>\(n.id)", from: "c1", to: n.id, kind: "delegate", label: "DELEGATE"))
        }
        linkFrom = nil
        linkMode = false
        selectedNodeId = n.id
        onChanged?()
        needsDisplay = true
    }

    /// Public: toggle two-click link mode from wizard chrome.
    func setLinkMode(_ on: Bool) {
        linkMode = on
        if !on { linkFrom = nil }
        needsDisplay = true
    }

    var isLinkMode: Bool { linkMode || linkFrom != nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            linkFrom = nil
            linkMode = false
            selectedEdgeId = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    private func pickParentForSub() -> String? {
        nodes.first(where: { $0.role == "worker" })?.id
            ?? nodes.first(where: { $0.role == "conductor" })?.id
    }

    private enum AttachMode { case peerAgent, subAgent }

    private func pickAttachMode(for n: Node) -> AttachMode? {
        let a = NSAlert()
        a.messageText = "Add next to “\(n.title)”"
        a.informativeText =
            "How should the new seat relate to this agent?\n\n" +
            "• Connected agent — same AGENTS plane, linked from “\(n.title)”\n" +
            "• Sub-agent — sits on the SUB plane under “\(n.title)”"
        a.addButton(withTitle: "Connected agent")
        a.addButton(withTitle: "Sub-agent")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn: return .peerAgent
        case .alertSecondButtonReturn: return .subAgent
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
        a.informativeText = "Who talks to whom — and how."
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

    private func editEdgeKind(id: String) {
        guard let i = edges.firstIndex(where: { $0.id == id }) else { return }
        let cur = edges[i]
        let a = NSAlert()
        a.messageText = "Connection: \(cur.from) → \(cur.to)"
        a.informativeText = "What should happen on this link?"
        for k in Self.kindChoices {
            a.addButton(withTitle: k.title)
        }
        a.addButton(withTitle: "Delete link")
        a.addButton(withTitle: "Cancel")
        // Pre-select is not supported on NSAlert buttons; order matches kindChoices
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        if idx >= 0, idx < Self.kindChoices.count {
            let k = Self.kindChoices[idx]
            edges[i].kind = k.id
            edges[i].label = k.short
            edges[i].id = "\(edges[i].from)>\(edges[i].to)"
            // Sub kind: nest target
            if k.id == "sub", let ti = nodes.firstIndex(where: { $0.id == edges[i].to }) {
                nodes[ti].parentId = edges[i].from
                nodes[ti].role = "subagent"
            }
            onChanged?()
        } else if idx == Self.kindChoices.count {
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
            edges.append(Edge(id: "\(from)>\(id)", from: from, to: id, kind: kindEdge, label: short))
            // Peer agents also keep an orch delegate so the team graph stays valid
            if kindEdge == "peer" {
                edges.append(Edge(id: "c1>\(id)", from: "c1", to: id, kind: "delegate", label: "DELEGATE"))
            }
        } else if isSub, let p = parentId {
            edges.append(Edge(id: "\(p)>\(id)", from: p, to: id, kind: "sub", label: "SUB · LINK"))
        } else {
            edges.append(Edge(id: "c1>\(id)", from: "c1", to: id, kind: "delegate", label: "DELEGATE"))
        }
        needsDisplay = true
        onChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragId, let dragStart, let originStart,
              let i = nodes.firstIndex(where: { $0.id == dragId }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if hypot(dx, dy) > 3 { didDrag = true }
        var o = CGPoint(x: originStart.x + dx, y: originStart.y + dy)
        o.x = max(20, min(bounds.width - nodeSize.width - 20, o.x))
        o.y = max(20, min(bounds.height - nodeSize.height - 20, o.y))
        nodes[i].origin = o
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Snap Y to band only. Preserve peer/custom edges — never force c1-only on move.
        if let dragId, let i = nodes.firstIndex(where: { $0.id == dragId }),
           nodes[i].role != "conductor" {
            let y = nodes[i].origin.y
            let midSub = bandH * 2 + bandH / 2
            let wasRole = nodes[i].role

            if y >= midSub - 30 {
                // → SUB band
                nodes[i].origin.y = bandH * 2 + 40
                if wasRole != "subagent" {
                    nodes[i].role = "subagent"
                    // Prefer existing peer/sub parent as parent; else first worker
                    let inbound = edges.first(where: {
                        $0.to == dragId && ($0.kind == "peer" || $0.kind == "sub") && $0.from != "c1"
                    })
                    nodes[i].parentId = inbound?.from ?? pickParentForSub()
                    if let p = nodes[i].parentId {
                        // Replace only the primary routing edge; keep others if any
                        edges.removeAll { $0.to == dragId && ($0.kind == "delegate" || $0.kind == "sub") }
                        if !edges.contains(where: { $0.from == p && $0.to == dragId }) {
                            edges.append(Edge(id: "\(p)>\(dragId)", from: p, to: dragId,
                                              kind: "sub", label: "SUB · LINK"))
                        } else if let ei = edges.firstIndex(where: { $0.from == p && $0.to == dragId }) {
                            edges[ei].kind = "sub"
                            edges[ei].label = "SUB · LINK"
                        }
                    }
                }
            } else {
                // → AGENTS band (default for anything above SUB threshold)
                nodes[i].origin.y = bandH + 40
                if wasRole == "subagent" {
                    // Promote: clear parent, ensure orch delegate, keep peer links
                    nodes[i].role = "worker"
                    nodes[i].parentId = nil
                    edges.removeAll { $0.to == dragId && $0.kind == "sub" }
                    if !edges.contains(where: { $0.from == "c1" && $0.to == dragId }) {
                        edges.append(Edge(id: "c1>\(dragId)", from: "c1", to: dragId,
                                          kind: "delegate", label: "DELEGATE"))
                    }
                }
                // Already a worker: snap Y only — do NOT wipe peer edges
            }
            needsDisplay = true
        }
        dragId = nil
        dragStart = nil
        originStart = nil
        onChanged?()
    }
}

import Foundation
import AppKit

/// Editable team topology (routing intent). Jobs remain source of truth.
/// Stored on pair as `flow_graph` — additive; missing graph ⇒ default conductor→workers.
enum FlowGraph {
    struct Edge: Equatable {
        var id: String
        var from: String
        var to: String
        /// Legacy field; always "forward". Direction is from→to only.
        var dir: String
        /// delegate | peer | sub | review | claim
        var kind: String
        var label: String

        func asDict() -> [String: Any] {
            ["id": id, "from": from, "to": to, "dir": dir, "kind": kind, "label": label]
        }

        static func from(_ d: [String: Any]) -> Edge? {
            guard let from = d["from"] as? String, let to = d["to"] as? String else { return nil }
            let kind = (d["kind"] as? String) ?? "delegate"
            // Prefer stored id; migrate bare "a>b" ids so multi-link loops stay unique
            let stored = d["id"] as? String
            let id: String = {
                if let stored, stored.contains(":") || stored.contains("·") { return stored }
                return makeId(from: from, to: to, kind: kind)
            }()
            // Direction is fully encoded by from→to. Legacy "reverse" flipped geometry a
            // second time in the map while color used from — normalize away.
            return Edge(
                id: id,
                from: from, to: to,
                dir: "forward",
                kind: kind,
                label: (d["label"] as? String) ?? defaultLabel(kind: kind)
            )
        }

        static func defaultLabel(kind: String) -> String {
            switch kind {
            case "peer": return "PEER · HANDOFF"
            case "sub": return "SUB · LINK"
            case "review": return "REVIEW"
            case "claim": return "CLAIM · DONE"
            case "reply": return "REPLY"
            default: return "DELEGATE"
            }
        }
    }

    /// Stable unique id: allows A→B:delegate and B→A:claim at once (loops).
    static func makeId(from: String, to: String, kind: String, suffix: String = "") -> String {
        let base = "\(from)>\(to):\(kind)"
        return suffix.isEmpty ? base : "\(base)·\(suffix)"
    }

    /// Suggested kind when drawing A → B in the map.
    static func suggestedKind(fromRole: String, toRole: String) -> String {
        let f = fromRole.lowercased()
        let t = toRole.lowercased()
        if f == "conductor" || f == "orchestrator" { return "delegate" }
        if t == "conductor" || t == "orchestrator" { return "claim" }
        if t == "subagent" || f == "subagent" { return "sub" }
        return "peer"
    }

    static func load(from entry: [String: Any]) -> [Edge] {
        guard let raw = entry["flow_graph"] as? [String: Any],
              let arr = raw["edges"] as? [[String: Any]] else {
            return defaultEdges(entry: entry)
        }
        let edges = arr.compactMap { Edge.from($0) }
        return edges.isEmpty ? defaultEdges(entry: entry) : edges
    }

    static func defaultEdges(entry: [String: Any]) -> [Edge] {
        let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
        let workers = Workers.list(from: entry)
        var edges: [Edge] = []
        for w in workers {
            let wid = (w["id"] as? String) ?? "w1"
            if let parent = w["parent_id"] as? String, !parent.isEmpty {
                // Parent → sub, and sub → parent (report back)
                edges.append(Edge(
                    id: makeId(from: parent, to: wid, kind: "sub"),
                    from: parent, to: wid,
                    dir: "forward", kind: "sub", label: Edge.defaultLabel(kind: "sub")
                ))
                edges.append(Edge(
                    id: makeId(from: wid, to: parent, kind: "claim"),
                    from: wid, to: parent,
                    dir: "forward", kind: "claim", label: Edge.defaultLabel(kind: "claim")
                ))
            } else {
                // Classic loop: orch assigns → agent works → agent claims back
                edges.append(Edge(
                    id: makeId(from: condId, to: wid, kind: "delegate"),
                    from: condId, to: wid,
                    dir: "forward", kind: "delegate", label: Edge.defaultLabel(kind: "delegate")
                ))
                edges.append(Edge(
                    id: makeId(from: wid, to: condId, kind: "claim"),
                    from: wid, to: condId,
                    dir: "forward", kind: "claim", label: Edge.defaultLabel(kind: "claim")
                ))
            }
        }
        // Optional peer handoff among top-level workers (one-way chain)
        let tops = workers.filter {
            let p = ($0["parent_id"] as? String) ?? ""
            return p.isEmpty
        }
        for i in 0..<max(0, tops.count - 1) {
            let a = (tops[i]["id"] as? String) ?? "w\(i+1)"
            let b = (tops[i + 1]["id"] as? String) ?? "w\(i+2)"
            edges.append(Edge(
                id: makeId(from: a, to: b, kind: "peer"),
                from: a, to: b,
                dir: "forward", kind: "peer", label: Edge.defaultLabel(kind: "peer")
            ))
        }
        return edges
    }

    static func save(pair: String, edges: [Edge]) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["flow_graph"] = [
            "edges": edges.map { $0.asDict() },
            "updated": Date().timeIntervalSince1970,
        ]
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
    }

    /// Reverse arrow: swap endpoints only. Do not toggle `dir` — from→to is the sole
    /// direction signal (map color + arrow both follow the visual originator).
    static func flip(_ edge: Edge) -> Edge {
        var e = edge
        swap(&e.from, &e.to)
        e.id = makeId(from: e.from, to: e.to, kind: e.kind)
        e.dir = "forward"
        return e
    }

    /// Band rank for orientation: orch (0) above agents (1) above subs (2).
    static func bandRank(role: String) -> Int {
        switch role.lowercased() {
        case "conductor", "orchestrator": return 0
        case "subagent": return 2
        default: return 1
        }
    }

    /// Reorder endpoints so the arrow matches the kind’s natural direction:
    /// - **claim / review** → upward (agent/sub → orch / parent)
    /// - **delegate / sub** → downward (orch / parent → agent/sub)
    /// - **peer** → leave as drawn
    static func orientEndpoints(
        from: String, to: String, kind: String,
        roleOf: (String) -> String
    ) -> (from: String, to: String) {
        let fr = roleOf(from), tr = roleOf(to)
        let fa = bandRank(role: fr), ta = bandRank(role: tr)
        switch kind.lowercased() {
        case "claim", "review":
            // Prefer lower band → higher band (up the canvas toward ORCH)
            if fa < ta { return (to, from) }
            if fr == "conductor" && tr != "conductor" { return (to, from) }
            return (from, to)
        case "delegate", "sub":
            // Prefer higher band → lower (down the canvas)
            if fa > ta { return (to, from) }
            if fr != "conductor" && tr == "conductor" { return (to, from) }
            return (from, to)
        default:
            return (from, to)
        }
    }

    /// Apply `orientEndpoints` and rebuild id/label.
    static func orient(_ edge: Edge, roleOf: (String) -> String) -> Edge {
        let ends = orientEndpoints(from: edge.from, to: edge.to, kind: edge.kind, roleOf: roleOf)
        var e = edge
        e.from = ends.from
        e.to = ends.to
        e.id = makeId(from: e.from, to: e.to, kind: e.kind)
        e.dir = "forward"
        return e
    }

    /// Add a directed link. Does **not** remove the reverse edge — loops are first-class.
    /// Only replaces an existing edge with the same from + to + kind.
    /// **Team isolation:** both seats must exist on this pair; refuse foreign ids.
    @discardableResult
    static func addEdge(pair: String, from: String, to: String, kind: String, label: String? = nil) -> Bool {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let seatIds = Self.seatIds(in: entry)
        guard seatIds.contains(from), seatIds.contains(to) else {
            // Never write a cross-team or unknown-seat edge into this pair's graph.
            return false
        }
        var edges = load(from: entry)
        let id = makeId(from: from, to: to, kind: kind)
        edges.removeAll {
            $0.id == id
                || ($0.from == from && $0.to == to && $0.kind == kind)
        }
        edges.append(Edge(
            id: id, from: from, to: to, dir: "forward",
            kind: kind, label: label ?? Edge.defaultLabel(kind: kind)
        ))
        save(pair: pair, edges: edges)
        return true
    }

    /// Conductor + worker ids that belong to this pair only.
    static func seatIds(in entry: [String: Any]) -> Set<String> {
        var ids = Set<String>()
        if let c = (entry["conductor"] as? [String: Any])?["id"] as? String, !c.isEmpty {
            ids.insert(c)
        }
        for w in Workers.list(from: entry) {
            if let id = w["id"] as? String, !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    /// Add the reverse of an edge (other direction) without deleting the original.
    @discardableResult
    static func addReverse(pair: String, id: String, kind: String? = nil) -> Bool {
        var edges = load(from: PairState.loadPairsDb()[pair] as? [String: Any] ?? [:])
        guard let e = edges.first(where: { $0.id == id }) else { return false }
        let k = kind ?? {
            // Smart default for the return path
            switch e.kind {
            case "delegate": return "claim"
            case "claim": return "delegate"
            case "sub": return "claim"
            default: return e.kind
            }
        }()
        let rid = makeId(from: e.to, to: e.from, kind: k)
        if edges.contains(where: { $0.id == rid || ($0.from == e.to && $0.to == e.from && $0.kind == k) }) {
            return false // already have that reverse
        }
        edges.append(Edge(
            id: rid, from: e.to, to: e.from, dir: "forward",
            kind: k, label: Edge.defaultLabel(kind: k)
        ))
        save(pair: pair, edges: edges)
        return true
    }

    static func removeEdge(pair: String, id: String) {
        var edges = load(from: PairState.loadPairsDb()[pair] as? [String: Any] ?? [:])
        edges.removeAll { $0.id == id }
        save(pair: pair, edges: edges)
    }

    static func flipEdge(pair: String, id: String) {
        var edges = load(from: PairState.loadPairsDb()[pair] as? [String: Any] ?? [:])
        if let i = edges.firstIndex(where: { $0.id == id }) {
            let flipped = flip(edges[i])
            // If reverse already exists as a separate link, don't collapse — just update this one
            edges[i] = flipped
            // Resolve id collision with a sibling of same from/to/kind
            var n = 2
            while edges.enumerated().contains(where: { $0.offset != i && $0.element.id == edges[i].id }) {
                edges[i].id = makeId(from: edges[i].from, to: edges[i].to, kind: edges[i].kind, suffix: "\(n)")
                n += 1
            }
            save(pair: pair, edges: edges)
        }
    }

    static func updateEdge(pair: String, id: String, mutate: (inout Edge) -> Void) {
        var edges = load(from: PairState.loadPairsDb()[pair] as? [String: Any] ?? [:])
        guard let i = edges.firstIndex(where: { $0.id == id }) else { return }
        mutate(&edges[i])
        if edges[i].label.isEmpty {
            edges[i].label = Edge.defaultLabel(kind: edges[i].kind)
        }
        // Unique id from endpoints + kind (multi-link safe)
        edges[i].id = makeId(from: edges[i].from, to: edges[i].to, kind: edges[i].kind)
        var n = 2
        while edges.enumerated().contains(where: { $0.offset != i && $0.element.id == edges[i].id }) {
            edges[i].id = makeId(from: edges[i].from, to: edges[i].to, kind: edges[i].kind, suffix: "\(n)")
            n += 1
        }
        save(pair: pair, edges: edges)
    }
}

// MARK: - 3D seat positions on deck (x,z; y from role)

enum Map3DLayout {
    static func save(session: String, nodeId: String, x: Float, z: Float) {
        var db = PairState.loadPairsDb()
        var entry = db[session] as? [String: Any] ?? [:]
        var map = entry["map3d_positions"] as? [String: [String: Any]] ?? [:]
        map[nodeId] = ["x": Double(x), "z": Double(z)]
        map["\(session)::\(nodeId)"] = ["x": Double(x), "z": Double(z)]
        entry["map3d_positions"] = map
        entry["updated"] = Date().timeIntervalSince1970
        db[session] = entry
        Pong.writeJSON(PairState.pairsPath, db)
    }

    static func load(session: String, nodeId: String) -> (x: Float, z: Float)? {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let map = entry["map3d_positions"] as? [String: [String: Any]] ?? [:]
        let raw = map["\(session)::\(nodeId)"] ?? map[nodeId]
        guard let raw else { return nil }
        let x = Float((raw["x"] as? Double) ?? Double(raw["x"] as? Int ?? 0))
        let z = Float((raw["z"] as? Double) ?? Double(raw["z"] as? Int ?? 0))
        return (x, z)
    }
}

// MARK: - Window recovery

enum WindowRecovery {
    /// Re-bind missing/stale Terminal window ids from live titles.
    /// Only match strict `attach-session -t <viewToken>` — never loose “claude/worker”
    /// strings (those mis-wired seats and blocked reopen).
    @discardableResult
    static func recover(session: String) -> Int {
        var db = PairState.loadPairsDb()
        guard var entry = db[session] as? [String: Any] else { return 0 }
        var fixed = 0

        var cond = entry["conductor"] as? [String: Any] ?? [:]
        let condWid = "\(cond["window_id"] ?? entry["hermes_window_id"] ?? "")"
        let hToken = TerminalTheme.viewToken(pair: session, role: "hermes")
        // V5: exact-token recovery only (pong.<session>.c1 or attach -t view)
        let condLive = TerminalTheme.resolvePairWindow(
            stored: Int(condWid) != nil ? condWid : nil,
            viewToken: hToken,
            pair: session,
            seat: "c1")
        if let condLive, condLive != condWid {
            cond["window_id"] = condLive
            entry["conductor"] = cond
            entry["hermes_window_id"] = condLive
            entry["conductor_window_id"] = condLive
            fixed += 1
        }

        var ws = Workers.list(from: entry)
        for i in ws.indices {
            let id = (ws[i]["id"] as? String) ?? "w\(i+1)"
            let wid = "\(ws[i]["window_id"] ?? "")"
            let token = TerminalTheme.viewToken(pair: session, role: id)
            let live = TerminalTheme.resolvePairWindow(
                stored: Int(wid) != nil ? wid : nil,
                viewToken: token,
                pair: session,
                seat: id)
            if let live, live != wid {
                ws[i]["window_id"] = live
                fixed += 1
            }
        }
        if fixed > 0 {
            entry["workers"] = ws
            if let first = ws.first?["window_id"] {
                entry["claude_window_id"] = first
                entry["worker_window_id"] = first
            }
            entry["updated"] = Date().timeIntervalSince1970
            db[session] = entry
            Pong.writeJSON(PairState.pairsPath, db)
            Pong.log("window recovery \(session) fixed=\(fixed)")
        }
        return fixed
    }

    static func recoverAll() {
        for s in PairState.listPairs() { _ = recover(session: s) }
    }
}

// MARK: - Design flow (same visual language as wizard Architecture)

/// Architecture-style canvas for live teams: ORCH / AGENTS / SUB bands,
/// team picker, drag seats, Link seats… for source→target, click arrows for kind.
final class FlowDesignSheetController: NSObject {
    static let shared = FlowDesignSheetController()

    private var window: NSWindow?
    private var session = ""
    /// All map seats (multi-team); filtered per selected session.
    private var allSeats: [Seat3D] = []
    private var seats: [Seat3D] = []
    private var onDone: (() -> Void)?
    private var canvas: TeamArchCanvas!
    private var hintLabel: NSTextField!
    private var teamPop: NSPopUpButton!
    private var titleLabel: NSTextField!

    /// - preferredSession: team to open first (map selection or first seat).
    /// - seats: full map seat list (all teams); we filter by session.
    func show(session preferredSession: String, seats: [Seat3D], onDone: @escaping () -> Void) {
        self.allSeats = seats.filter { $0.role != "add" && $0.role != "human" }
        self.onDone = onDone
        // Prefer requested session if it still has seats; else first available team
        let sessions = availableSessions()
        if sessions.contains(preferredSession) {
            self.session = preferredSession
        } else {
            self.session = sessions.first ?? preferredSession
        }
        self.seats = allSeats.filter { $0.session == self.session }
        if window == nil { build() }
        rebuildTeamMenu()
        reloadCanvas()
        window?.title = "Architecture · \(teamDisplayName(session))"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func availableSessions() -> [String] {
        var seen: [String] = []
        for s in allSeats {
            if !seen.contains(s.session) { seen.append(s.session) }
        }
        // Also include live pairs that might have no seats yet on map
        for p in PairState.listPairs() where !seen.contains(p) {
            seen.append(p)
        }
        return seen
    }

    private func teamDisplayName(_ sess: String) -> String {
        let entry = PairState.loadPairsDb()[sess] as? [String: Any] ?? [:]
        let name = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        if let orch = allSeats.first(where: { $0.session == sess && $0.role == "conductor" }) {
            return orch.title
        }
        return sess
    }

    private func build() {
        let w: CGFloat = 720
        let h: CGFloat = 580
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Architecture"
        win.center()
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bg
        win.minSize = NSSize(width: 560, height: 440)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        win.contentView = root

        titleLabel = NSTextField(labelWithString: "Architecture")
        titleLabel.font = PongTheme.font(18, weight: .semibold)
        titleLabel.textColor = PongTheme.textPrimary
        titleLabel.frame = NSRect(x: 24, y: h - 42, width: 200, height: 26)
        titleLabel.autoresizingMask = [.minYMargin]
        root.addSubview(titleLabel)

        let teamL = NSTextField(labelWithString: "Team")
        teamL.font = PongTheme.mono(10, weight: .medium)
        teamL.textColor = PongTheme.textTertiary
        teamL.frame = NSRect(x: w - 280, y: h - 40, width: 40, height: 14)
        teamL.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(teamL)

        teamPop = NSPopUpButton(frame: NSRect(x: w - 236, y: h - 48, width: 212, height: 28), pullsDown: false)
        teamPop.font = PongTheme.font(12)
        teamPop.target = self
        teamPop.action = #selector(teamChanged(_:))
        teamPop.autoresizingMask = [.minXMargin, .minYMargin]
        teamPop.toolTip = "Which live team to edit"
        root.addSubview(teamPop)

        hintLabel = NSTextField(wrappingLabelWithString:
            "Pick a team. Link seats… → source then destination (existing only). " +
            "Drag dotted ends to rewire. × or Delete removes an agent. Mid-arrow sets kind.")
        hintLabel.font = PongTheme.font(11)
        hintLabel.textColor = PongTheme.textSecondary
        hintLabel.frame = NSRect(x: 24, y: h - 96, width: w - 180, height: 40)
        hintLabel.autoresizingMask = [.width, .minYMargin]
        root.addSubview(hintLabel)

        let linkBtn = NSButton(title: "Link seats…", target: self, action: #selector(toggleLinkMode))
        linkBtn.bezelStyle = .rounded
        linkBtn.frame = NSRect(x: w - 140, y: h - 90, width: 116, height: 28)
        linkBtn.autoresizingMask = [.minXMargin, .minYMargin]
        linkBtn.toolTip = "Click source seat, then destination — does not create a new agent"
        root.addSubview(linkBtn)

        canvas = TeamArchCanvas(frame: NSRect(x: 16, y: 52, width: w - 32, height: h - 160))
        canvas.autoresizingMask = [.width, .height]
        canvas.allowAddSeats = false
        canvas.onChanged = { [weak self] in
            self?.persistFromCanvas()
        }
        canvas.onDeleteSeat = { [weak self] id in
            guard let self, !self.session.isEmpty else { return false }
            return Workers.removeWorker(pair: self.session, workerId: id)
        }
        root.addSubview(canvas)

        let done = NSButton(title: "Done", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: w - 108, y: 14, width: 84, height: 28)
        done.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(done)

        let tip = NSTextField(labelWithString: "Jobs on disk stay source of truth — this designs who talks to whom.")
        tip.font = PongTheme.mono(10)
        tip.textColor = PongTheme.textTertiary
        tip.frame = NSRect(x: 24, y: 18, width: w - 150, height: 16)
        tip.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(tip)

        window = win
    }

    private func rebuildTeamMenu() {
        teamPop.removeAllItems()
        let sessions = availableSessions()
        if sessions.isEmpty {
            teamPop.addItem(withTitle: "(no live teams)")
            teamPop.isEnabled = false
            return
        }
        teamPop.isEnabled = true
        for s in sessions {
            let title = "\(teamDisplayName(s))  ·  \(s)"
            teamPop.addItem(withTitle: title)
            teamPop.lastItem?.representedObject = s
            if s == session {
                teamPop.select(teamPop.lastItem)
            }
        }
        // Ensure selection matches session
        if let ix = sessions.firstIndex(of: session) {
            teamPop.selectItem(at: ix)
        }
    }

    @objc private func teamChanged(_ sender: NSPopUpButton) {
        guard let next = sender.selectedItem?.representedObject as? String,
              !next.isEmpty, next != session else { return }
        // Save current team graph before switching
        persistFromCanvas()
        session = next
        seats = allSeats.filter { $0.session == session }
        // If map has no seats for this pair yet, synthesize minimal from pairs.json
        if seats.isEmpty {
            seats = syntheticSeats(for: session)
        }
        window?.title = "Architecture · \(teamDisplayName(session))"
        titleLabel.stringValue = "Architecture"
        reloadCanvas()
        window?.makeFirstResponder(canvas)
    }

    /// Fallback when map hasn't materialised seats for a pair yet.
    private func syntheticSeats(for sess: String) -> [Seat3D] {
        let entry = PairState.loadPairsDb()[sess] as? [String: Any] ?? [:]
        var out: [Seat3D] = []
        let cond = entry["conductor"] as? [String: Any] ?? [:]
        let cId = (cond["id"] as? String) ?? "c1"
        let cLab = (cond["label"] as? String) ?? teamDisplayName(sess)
        out.append(Seat3D(
            session: sess, id: cId, role: "conductor",
            title: cLab, subtitle: "orchestrator", detail: "",
            status: "idle", parentId: nil, openJobs: 0,
            flowHint: "", missionRole: "orchestrator"
        ))
        for (i, w) in Workers.list(from: entry).enumerated() {
            let id = (w["id"] as? String) ?? "w\(i + 1)"
            let lab = (w["label"] as? String) ?? id
            let parent = (w["parent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let role = parent != nil ? "subagent" : "worker"
            out.append(Seat3D(
                session: sess, id: id, role: role,
                title: lab, subtitle: (w["type"] as? String) ?? "agent", detail: "",
                status: "idle", parentId: parent, openJobs: 0,
                flowHint: "",
                missionRole: role == "subagent" ? "researcher" : "coder"
            ))
        }
        return out
    }

    private func reloadCanvas() {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        var edges = FlowGraph.load(from: entry)
        if edges.isEmpty {
            edges = FlowGraph.defaultEdges(entry: entry)
        }
        if let win = window, let content = win.contentView {
            let w = content.bounds.width
            let h = content.bounds.height
            canvas.frame = NSRect(x: 16, y: 52, width: max(400, w - 32), height: max(280, h - 160))
        }
        let teamSeats = seats.isEmpty ? syntheticSeats(for: session) : seats
        canvas.load(seats: teamSeats, flowEdges: edges)
    }

    private func persistFromCanvas() {
        guard !session.isEmpty else { return }
        FlowGraph.save(pair: session, edges: canvas.exportEdges())
    }

    @objc private func toggleLinkMode() {
        canvas.setLinkMode(!canvas.isLinkMode)
        window?.makeFirstResponder(canvas)
    }

    @objc private func donePressed() {
        persistFromCanvas()
        window?.orderOut(nil)
        onDone?()
    }
}

// MARK: - Single-link editor (click a flow line on the map)

/// Edit direction, kind (“what they do”), and label for one connection.
final class FlowLinkEditSheet: NSObject {
    static let shared = FlowLinkEditSheet()

    private var window: NSWindow?
    private var session = ""
    private var edge: FlowGraph.Edge!
    private var seats: [Seat3D] = []
    private var onDone: (() -> Void)?

    private var fromPop: NSPopUpButton!
    private var toPop: NSPopUpButton!
    private var kindPop: NSPopUpButton!
    private var labelField: NSTextField!
    private var dirLabel: NSTextField!

    private let kinds: [(id: String, title: String)] = [
        ("delegate", "Delegate — orch assigns jobs"),
        ("claim", "Claim — agent reports done"),
        ("review", "Review — request review"),
        ("peer", "Peer handoff — agent → agent"),
        ("sub", "Sub-link — agent → subagent"),
    ]

    func show(session: String, edge: FlowGraph.Edge, seats: [Seat3D], onDone: @escaping () -> Void) {
        self.session = session
        self.edge = edge
        self.seats = seats.filter { $0.role != "human" }
        self.onDone = onDone
        if window == nil { build() }
        populate()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w: CGFloat = 440
        let h: CGFloat = 340
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Edit connection"
        win.isReleasedWhenClosed = false
        win.center()
        win.backgroundColor = PongTheme.bg

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        win.contentView = root

        var y = h - 40
        let title = NSTextField(labelWithString: "How does work move?")
        title.font = PongTheme.font(15, weight: .semibold)
        title.textColor = PongTheme.textPrimary
        title.frame = NSRect(x: 20, y: y, width: w - 40, height: 22)
        root.addSubview(title)
        y -= 28

        let hint = NSTextField(wrappingLabelWithString:
            "Loops need two links: e.g. orch → agent (delegate) and agent → orch (claim). " +
            "Add return path keeps this arrow and creates the reverse.")
        hint.font = PongTheme.font(11)
        hint.textColor = PongTheme.textSecondary
        hint.frame = NSRect(x: 20, y: y - 28, width: w - 40, height: 44)
        root.addSubview(hint)
        y -= 58

        root.addSubview(lab("From", x: 20, y: y))
        fromPop = NSPopUpButton(frame: NSRect(x: 100, y: y - 4, width: 280, height: 26), pullsDown: false)
        root.addSubview(fromPop)
        y -= 36

        root.addSubview(lab("Does", x: 20, y: y))
        kindPop = NSPopUpButton(frame: NSRect(x: 100, y: y - 4, width: 280, height: 26), pullsDown: false)
        for k in kinds {
            kindPop.addItem(withTitle: k.title)
            kindPop.lastItem?.representedObject = k.id
        }
        kindPop.target = self
        kindPop.action = #selector(kindChanged)
        root.addSubview(kindPop)
        y -= 36

        root.addSubview(lab("To", x: 20, y: y))
        toPop = NSPopUpButton(frame: NSRect(x: 100, y: y - 4, width: 280, height: 26), pullsDown: false)
        root.addSubview(toPop)
        y -= 36

        root.addSubview(lab("Label", x: 20, y: y))
        labelField = NSTextField(frame: NSRect(x: 100, y: y - 4, width: 280, height: 24))
        labelField.placeholderString = "e.g. DELEGATE · AUTH"
        root.addSubview(labelField)
        y -= 36

        dirLabel = NSTextField(labelWithString: "→")
        dirLabel.font = PongTheme.font(12, weight: .medium)
        dirLabel.textColor = PongTheme.textSecondary
        dirLabel.frame = NSRect(x: 20, y: y, width: w - 40, height: 18)
        root.addSubview(dirLabel)

        let flip = NSButton(title: "Flip this", target: self, action: #selector(flipPressed))
        flip.bezelStyle = .rounded
        flip.toolTip = "Reverse only this arrow (keeps other links)"
        flip.frame = NSRect(x: 20, y: 16, width: 88, height: 28)
        root.addSubview(flip)

        let rev = NSButton(title: "+ Return path", target: self, action: #selector(addReversePressed))
        rev.bezelStyle = .rounded
        rev.toolTip = "Keep this link and add the opposite direction (claim/reply loop)"
        rev.frame = NSRect(x: 116, y: 16, width: 120, height: 28)
        root.addSubview(rev)

        let del = NSButton(title: "Delete", target: self, action: #selector(deletePressed))
        del.bezelStyle = .rounded
        del.frame = NSRect(x: 244, y: 16, width: 72, height: 28)
        root.addSubview(del)

        let save = NSButton(title: "Save", target: self, action: #selector(savePressed))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 100, y: 16, width: 80, height: 28)
        root.addSubview(save)

        window = win
    }

    private func lab(_ t: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = PongTheme.font(11, weight: .medium)
        l.textColor = PongTheme.textTertiary
        l.frame = NSRect(x: x, y: y, width: 70, height: 18)
        return l
    }

    private func populate() {
        fromPop.removeAllItems()
        toPop.removeAllItems()
        let choices = seats.map { ($0.id, "\($0.title) · \($0.id)") }
        for c in choices {
            fromPop.addItem(withTitle: c.1)
            fromPop.lastItem?.representedObject = c.0
            if c.0 == edge.from { fromPop.select(fromPop.lastItem) }
            toPop.addItem(withTitle: c.1)
            toPop.lastItem?.representedObject = c.0
            if c.0 == edge.to { toPop.select(toPop.lastItem) }
        }
        if let i = kinds.firstIndex(where: { $0.id == edge.kind }) {
            kindPop.selectItem(at: i)
        }
        labelField.stringValue = edge.label
        refreshDir()
    }

    private func refreshDir() {
        let a = (fromPop.selectedItem?.representedObject as? String) ?? edge.from
        let b = (toPop.selectedItem?.representedObject as? String) ?? edge.to
        let an = seats.first(where: { $0.id == a })?.title ?? a
        let bn = seats.first(where: { $0.id == b })?.title ?? b
        let k = (kindPop.selectedItem?.representedObject as? String) ?? edge.kind
        let hint: String = {
            switch k {
            case "claim", "review": return "  ·  upward report"
            case "delegate", "sub": return "  ·  downward assign"
            default: return ""
            }
        }()
        dirLabel.stringValue = "\(an)  →  \(bn)\(hint)"
    }

    private func selectSeatPop(_ pop: NSPopUpButton, id: String) {
        for item in pop.itemArray {
            if (item.representedObject as? String) == id {
                pop.select(item)
                return
            }
        }
    }

    /// When kind changes, auto-orient from→to (claim points up toward orch).
    @objc private func kindChanged() {
        guard let k = kindPop.selectedItem?.representedObject as? String else { return }
        let a = (fromPop.selectedItem?.representedObject as? String) ?? edge.from
        let b = (toPop.selectedItem?.representedObject as? String) ?? edge.to
        let roleOf: (String) -> String = { id in
            self.seats.first(where: { $0.id == id })?.role ?? "worker"
        }
        let ends = FlowGraph.orientEndpoints(from: a, to: b, kind: k, roleOf: roleOf)
        selectSeatPop(fromPop, id: ends.from)
        selectSeatPop(toPop, id: ends.to)
        // Suggest default label for the new kind if still a stock phrase
        let stock = kinds.map { FlowGraph.Edge.defaultLabel(kind: $0.id) }
            + Self.stockLabels
        if stock.contains(labelField.stringValue) || labelField.stringValue.isEmpty {
            labelField.stringValue = FlowGraph.Edge.defaultLabel(kind: k)
        }
        refreshDir()
    }

    private static let stockLabels = [
        "DELEGATE", "CLAIM", "REVIEW", "PEER", "SUB · LINK",
        "DELEGATE · AUTH", "CLAIM · DONE", "PEER · HANDOFF",
    ]

    @objc private func flipPressed() {
        let a = fromPop.indexOfSelectedItem
        let b = toPop.indexOfSelectedItem
        fromPop.selectItem(at: b)
        toPop.selectItem(at: a)
        // Flip kind smartly for loops (delegate ↔ claim) only when both ends are orch↔agent
        if let k = kindPop.selectedItem?.representedObject as? String {
            let alt: String? = {
                switch k {
                case "delegate": return "claim"
                case "claim": return "delegate"
                default: return nil
                }
            }()
            if let alt, let idx = kinds.firstIndex(where: { $0.id == alt }) {
                kindPop.selectItem(at: idx)
                labelField.stringValue = FlowGraph.Edge.defaultLabel(kind: alt)
            }
        }
        refreshDir()
    }

    @objc private func addReversePressed() {
        // Save current edits first, then add opposite path
        commitSave(keepOpen: true)
        let ok = FlowGraph.addReverse(pair: session, id: edge.id)
        window?.orderOut(nil)
        onDone?()
        if !ok {
            Pong.log("flow reverse already present or missing id=\(edge.id)")
        }
    }

    @objc private func deletePressed() {
        FlowGraph.removeEdge(pair: session, id: edge.id)
        window?.orderOut(nil)
        onDone?()
    }

    @objc private func savePressed() {
        commitSave(keepOpen: false)
    }

    private func commitSave(keepOpen: Bool) {
        let from = (fromPop.selectedItem?.representedObject as? String) ?? edge.from
        let to = (toPop.selectedItem?.representedObject as? String) ?? edge.to
        let kind = (kindPop.selectedItem?.representedObject as? String) ?? edge.kind
        var label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = FlowGraph.Edge.defaultLabel(kind: kind) }
        let oldId = edge.id
        FlowGraph.updateEdge(pair: session, id: oldId) { e in
            e.from = from
            e.to = to
            e.kind = kind
            e.label = label
            e.dir = "forward"
        }
        let edges = FlowGraph.load(from: PairState.loadPairsDb()[session] as? [String: Any] ?? [:])
        if let updated = edges.first(where: {
            $0.from == from && $0.to == to && $0.kind == kind
        }) {
            edge = updated
        }
        if !keepOpen {
            window?.orderOut(nil)
            onDone?()
        }
    }
}

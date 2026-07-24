import AppKit
import QuartzCore

// MARK: - Positions
//
// Invariants:
// 1. Multi-team resolution always prefers `session::seatId`.
// 2. Single-team may still use bare `seatId` inside that pair's entry.
// 3. `canvas-all.json` stores **scoped keys only** (no bare `w1`) to avoid
//    two teams both writing bare `w1` and stealing each other's layout.
// 4. Pair entry still dual-writes bare + scoped for single-team fallback.
// 5. TeamSanitizer deletes both key forms on seat remove.

enum CanvasLayout {
    /// Uniform design-grid step (matches canvas dots).
    static let gridStep: CGFloat = 20

    static func key(session: String, nodeId: String, multi: Bool) -> String {
        multi ? "\(session)::\(nodeId)" : nodeId
    }

    static func scopedKey(session: String, nodeId: String) -> String {
        "\(session)::\(nodeId)"
    }

    /// Snap origin to the dotted grid (top-left of module).
    static func snap(_ p: CGPoint) -> CGPoint {
        let s = gridStep
        let x = (p.x / s).rounded() * s
        let y = (p.y / s).rounded() * s
        return CGPoint(x: max(s, x), y: max(s, y))
    }

    static func positions(for session: String?) -> [String: CGPoint] {
        // Global map is scoped-only (`session::seatId`). Bare keys pollute multi view.
        var out = loadMap(from: Pong.loadJSON(Pong.stateDir + "/canvas-all.json"))
        let bareGlobal = out.keys.filter { !$0.contains("::") }
        if !bareGlobal.isEmpty {
            for k in bareGlobal { out.removeValue(forKey: k) }
            scrubCanvasAllBareKeys()
        }
        if let session {
            let local = loadMap(from: PairState.loadPairsDb()[session] as? [String: Any] ?? [:])
            for (k, v) in local {
                if k.contains("::") {
                    out[k] = v
                } else {
                    // Pair-local bare → also store under scoped so multi-safe if merged later
                    out[scopedKey(session: session, nodeId: k)] = v
                    out[k] = v // single-team origin may still read bare
                }
            }
        }
        return out
    }

    /// Drop bare seat ids from canvas-all.json (multi-team collision source).
    static func scrubCanvasAllBareKeys() {
        PairWriteLock.withLock {
            var all = Pong.loadJSON(Pong.stateDir + "/canvas-all.json")
            var raw = all["canvas_positions"] as? [String: [String: Any]] ?? [:]
            let before = raw.count
            raw = raw.filter { $0.key.contains("::") }
            guard raw.count != before else { return }
            all["canvas_positions"] = raw
            all["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(Pong.stateDir + "/canvas-all.json", all)
            Pong.log("canvas-all scrubbed bare keys \(before - raw.count)")
        }
    }

    /// Resolve a seat position from map (session-scoped key first; bare only in single-team).
    static func origin(session: String, nodeId: String, multi: Bool, map: [String: CGPoint],
                       teamIndex: Int, role: String, workerIndex: Int, canvas: CGSize) -> CGPoint {
        let sk = scopedKey(session: session, nodeId: nodeId)
        if let p = map[sk] { return snap(p) }
        // CRITICAL: multi view must never use bare `c1`/`w1` — every team shares those ids.
        if !multi, let p = map[nodeId] { return snap(p) }
        return snap(defaultPosition(teamIndex: teamIndex, role: role, workerIndex: workerIndex, canvas: canvas, multi: multi))
    }

    private static func loadMap(from entry: [String: Any]) -> [String: CGPoint] {
        let raw = entry["canvas_positions"] as? [String: [String: Any]] ?? [:]
        var out: [String: CGPoint] = [:]
        for (k, v) in raw {
            let x = CGFloat((v["x"] as? Double) ?? Double(v["x"] as? Int ?? 0))
            let y = CGFloat((v["y"] as? Double) ?? Double(v["y"] as? Int ?? 0))
            out[k] = CGPoint(x: x, y: y)
        }
        return out
    }

    /// Persist one seat: pair entry dual-writes bare + scoped; canvas-all is scoped-only.
    static func saveSeat(session: String, nodeId: String, origin: CGPoint) {
        let snapped = snap(origin)
        let bare = nodeId
        let scoped = scopedKey(session: session, nodeId: nodeId)
        let point: [String: Any] = ["x": Double(snapped.x), "y": Double(snapped.y)]

        PairWriteLock.withLock {
            var db = PairState.loadPairsDb()
            var entry = db[session] as? [String: Any] ?? [:]
            var local = entry["canvas_positions"] as? [String: [String: Any]] ?? [:]
            local[bare] = point
            local[scoped] = point
            entry["canvas_positions"] = local
            entry["updated"] = Date().timeIntervalSince1970
            db[session] = entry
            Pong.writeJSON(PairState.pairsPath, db)

            var all = Pong.loadJSON(Pong.stateDir + "/canvas-all.json")
            var raw = all["canvas_positions"] as? [String: [String: Any]] ?? [:]
            // Scoped only in global map — prevents w1 from team A overwriting team B
            raw[scoped] = point
            // Never keep bare keys in canvas-all
            raw = raw.filter { $0.key.contains("::") }
            all["canvas_positions"] = raw
            all["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(Pong.stateDir + "/canvas-all.json", all)
        }
    }

    static func save(session: String?, positions: [String: CGPoint], multi: Bool) {
        var raw: [String: [String: Any]] = [:]
        for (k, p) in positions {
            let s = snap(p)
            raw[k] = ["x": Double(s.x), "y": Double(s.y)]
        }
        if multi || session == nil {
            // canvas-all is always scoped-only
            let cleaned = raw.filter { $0.key.contains("::") }
            Pong.writeJSON(
                Pong.stateDir + "/canvas-all.json",
                ["canvas_positions": cleaned, "updated": Date().timeIntervalSince1970]
            )
            return
        }
        guard let session else { return }
        PairWriteLock.withLock {
            var db = PairState.loadPairsDb()
            var entry = db[session] as? [String: Any] ?? [:]
            entry["canvas_positions"] = raw
            entry["updated"] = Date().timeIntervalSince1970
            db[session] = entry
            Pong.writeJSON(PairState.pairsPath, db)
        }
    }

    /// Comfortable workplace: room to pan; grows when seats approach edges.
    static let minCanvas = NSSize(width: 2400, height: 1800)
    static let maxCanvas = NSSize(width: 8000, height: 6000)
    /// Padding around seat cluster when sizing the document.
    static let workplacePad: CGFloat = 640
    /// Clear of left HUD (Tracking / YOU) on first layout.
    static let hudClearX: CGFloat = 360
    static let hudClearY: CGFloat = 280
    /// Multi-team grid pitch. Orch card ~200 wide + workers at +300 → right edge ~500;
    /// pitch must clear that plus margin so adjacent clusters never collide.
    static let multiPitchX: CGFloat = 1200
    static let multiPitchY: CGFloat = 720
    static let multiCols: Int = 3

    /// Tight cluster — fixed coords, never scaled to canvas size.
    /// Multi: grid of clusters (columns × rows). Single: clear of left HUD.
    static func defaultPosition(teamIndex: Int, role: String, workerIndex: Int, canvas: CGSize, multi: Bool) -> CGPoint {
        _ = canvas
        let clusterX: CGFloat
        let clusterY: CGFloat
        if multi {
            let col = teamIndex % multiCols
            let row = teamIndex / multiCols
            clusterX = hudClearX + CGFloat(col) * multiPitchX
            clusterY = hudClearY + CGFloat(row) * multiPitchY
        } else {
            clusterX = hudClearX
            clusterY = hudClearY
        }
        if role == "conductor" {
            return snap(CGPoint(x: clusterX, y: clusterY))
        }
        // Workers sit in a compact column to the right of the boss
        return snap(CGPoint(
            x: clusterX + 300,
            y: clusterY - 20 + CGFloat(workerIndex) * 150
        ))
    }

    /// Document size that fits seats + pan room (clamped).
    static func workplaceSize(fitting nodes: [CGPoint], card: NSSize = NSSize(width: 200, height: 120)) -> NSSize {
        guard !nodes.isEmpty else { return minCanvas }
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in nodes {
            maxX = max(maxX, p.x + card.width)
            maxY = max(maxY, p.y + card.height)
        }
        let w = max(minCanvas.width, min(maxCanvas.width, maxX + workplacePad))
        let h = max(minCanvas.height, min(maxCanvas.height, maxY + workplacePad))
        return NSSize(width: w, height: h)
    }

    /// Grow document so `frame` (seat rect) has pan room; returns new size if expanded.
    @discardableResult
    static func expandSize(_ current: NSSize, toFit origin: CGPoint, card: NSSize) -> NSSize {
        let needW = origin.x + card.width + workplacePad
        let needH = origin.y + card.height + workplacePad
        return NSSize(
            width: min(maxCanvas.width, max(current.width, needW, minCanvas.width)),
            height: min(maxCanvas.height, max(current.height, needH, minCanvas.height))
        )
    }

    /// Multi-team: if conductors are stacked / missing scoped slots, re-slot those teams.
    /// Preserves relative offsets within a team when a conductor anchor exists.
    @discardableResult
    static func unstackOverlappingTeams(_ points: inout [String: CGPoint], sessions: [String]) -> Bool {
        guard sessions.count >= 2 else { return false }
        // Drop bare keys from the working map (multi-safe)
        for k in points.keys.filter({ !$0.contains("::") }) {
            points.removeValue(forKey: k)
        }

        func condKey(session: String) -> String? {
            let c1 = scopedKey(session: session, nodeId: "c1")
            if points[c1] != nil { return c1 }
            let prefix = session + "::"
            return points.keys.first { key in
                guard key.hasPrefix(prefix) else { return false }
                let id = String(key.dropFirst(prefix.count))
                return (id == "c1" || id.hasPrefix("c")) && !id.hasPrefix("w")
            }
        }

        var conds: [String: CGPoint] = [:]
        var missing: Set<String> = []
        for sess in sessions {
            if let k = condKey(session: sess), let p = points[k] {
                conds[sess] = p
            } else {
                missing.insert(sess)
            }
        }

        var stacked: Set<String> = missing
        let list = sessions.filter { conds[$0] != nil }
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                let a = conds[list[i]]!
                let b = conds[list[j]]!
                if hypot(a.x - b.x, a.y - b.y) < 220 {
                    stacked.insert(list[i])
                    stacked.insert(list[j])
                }
            }
        }
        guard !stacked.isEmpty else { return false }

        var changed = false
        for (ti, sess) in sessions.enumerated() {
            guard stacked.contains(sess) else { continue }
            let prefix = sess + "::"
            let teamKeys = points.filter { $0.key.hasPrefix(prefix) }
            let newCond = defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: minCanvas, multi: true)
            if let oldCond = conds[sess], teamKeys.count >= 1 {
                let dx = newCond.x - oldCond.x
                let dy = newCond.y - oldCond.y
                if abs(dx) < 1, abs(dy) < 1, missing.contains(sess) == false { continue }
                for (k, p) in teamKeys {
                    points[k] = snap(CGPoint(x: p.x + dx, y: p.y + dy))
                }
                // Ensure conductor key exists
                points[scopedKey(session: sess, nodeId: "c1")] = newCond
                changed = true
            } else {
                // Full re-default for this team’s known seats
                points[scopedKey(session: sess, nodeId: "c1")] = newCond
                var wi = 0
                for k in teamKeys.keys.sorted() {
                    let id = String(k.dropFirst(prefix.count))
                    if id == "c1" || ((id.hasPrefix("c") || id == "hermes") && !id.hasPrefix("w")) {
                        points[k] = newCond
                        continue
                    }
                    points[k] = defaultPosition(teamIndex: ti, role: "worker", workerIndex: wi, canvas: minCanvas, multi: true)
                    wi += 1
                }
                changed = true
            }
        }
        return changed
    }

    /// Force multi default grid for every team from the **live pair roster**.
    /// Does not preserve relative offsets (those keep stacked seats stacked).
    /// Places conductor + each worker at `defaultPosition` for team index `ti`.
    @discardableResult
    static func arrangeTeams(_ points: inout [String: CGPoint], sessions: [String]) -> Bool {
        // Multi map is scoped-only
        for k in points.keys.filter({ !$0.contains("::") }) {
            points.removeValue(forKey: k)
        }
        guard !sessions.isEmpty else { return false }

        var changed = false
        func set(_ key: String, _ p: CGPoint) {
            let s = snap(p)
            if let old = points[key], hypot(old.x - s.x, old.y - s.y) < 1 { return }
            points[key] = s
            changed = true
        }

        for (ti, sess) in sessions.enumerated() {
            let entry = PairState.loadPairsDb()[sess] as? [String: Any] ?? [:]
            let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
            let newCond = defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: minCanvas, multi: true)
            set(scopedKey(session: sess, nodeId: condId), newCond)
            if condId != "c1" {
                set(scopedKey(session: sess, nodeId: "c1"), newCond)
            }

            let workers = Workers.list(from: entry)
            var knownIds: Set<String> = [condId, "c1"]
            for (i, w) in workers.enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                knownIds.insert(wid)
                let p = defaultPosition(teamIndex: ti, role: "worker", workerIndex: i, canvas: minCanvas, multi: true)
                set(scopedKey(session: sess, nodeId: wid), p)
            }

            // Re-slot any leftover scoped seats for this session (subagents, legacy ids)
            let prefix = sess + "::"
            var extraWi = workers.count
            for k in points.keys.filter({ $0.hasPrefix(prefix) }).sorted() {
                let id = String(k.dropFirst(prefix.count))
                if knownIds.contains(id) { continue }
                if id == "add" || id.hasPrefix("add") {
                    set(k, CGPoint(x: newCond.x + 200, y: newCond.y + 40))
                    continue
                }
                if (id.hasPrefix("c") || id == "hermes") && !id.hasPrefix("w") {
                    set(k, newCond)
                    continue
                }
                set(k, defaultPosition(teamIndex: ti, role: "worker", workerIndex: extraWi, canvas: minCanvas, multi: true))
                extraWi += 1
            }
        }
        return changed
    }

    /// If seats got scattered across an old huge canvas, pull them into a tight cluster.
    /// **Single-team only** — multi span is intentionally large.
    static func compactIfSpread(_ points: inout [String: CGPoint], multi: Bool) -> Bool {
        if multi { return false }
        let seats = points.filter { !$0.key.hasSuffix("::add") && !$0.key.hasSuffix("add") && !$0.key.contains("add-sub") }
        guard seats.count >= 2 else { return false }
        let xs = seats.values.map(\.x)
        let ys = seats.values.map(\.y)
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
        // Only truly pathological void scatter (user drag can exceed old 1100 threshold)
        guard spanX > 5000 || spanY > 4000 else { return false }
        var bySession: [String: [(id: String, role: String)]] = [:]
        for key in seats.keys {
            let parts = key.components(separatedBy: "::")
            let session: String
            let id: String
            if parts.count >= 2 {
                session = parts[0]; id = parts[1]
            } else {
                session = "_"; id = key
            }
            let role = (id == "c1" || id.hasPrefix("c")) && !id.hasPrefix("w") ? "conductor" : "worker"
            bySession[session, default: []].append((id, role))
        }
        let sessions = bySession.keys.sorted()
        var out: [String: CGPoint] = [:]
        for (ti, sess) in sessions.enumerated() {
            let members = bySession[sess] ?? []
            var wi = 0
            for m in members.sorted(by: { a, b in
                if a.role == "conductor" { return true }
                if b.role == "conductor" { return false }
                return a.id < b.id
            }) {
                let role = m.role
                let idx = role == "conductor" ? 0 : wi
                if role != "conductor" { wi += 1 }
                let p = defaultPosition(teamIndex: ti, role: role, workerIndex: idx, canvas: minCanvas, multi: false)
                let bare = m.id
                let scoped = sess == "_" ? bare : "\(sess)::\(bare)"
                out[scoped] = p
                out[bare] = p
            }
        }
        for (k, v) in out { points[k] = v }
        return true
    }
}

// MARK: - Model

struct AgentNodeModel {
    let session: String
    let id: String          // local: c1, w1
    var globalId: String { "\(session)::\(id)" }
    let role: String        // conductor | worker | add | subagent
    let title: String
    let subtitle: String
    let detail: String
    let status: String
    let teamLabel: String
    let accent: NSColor
    var origin: CGPoint
    /// Parity with Seat3D (shared HUD / panels)
    var parentId: String? = nil
    var openJobs: Int = 0
    var flowHint: String = ""
    var missionRole: String = "coder"

    init(
        session: String, id: String, role: String, title: String, subtitle: String,
        detail: String, status: String, teamLabel: String, accent: NSColor, origin: CGPoint,
        parentId: String? = nil, openJobs: Int = 0, flowHint: String = "", missionRole: String = "coder"
    ) {
        self.session = session; self.id = id; self.role = role
        self.title = title; self.subtitle = subtitle; self.detail = detail
        self.status = status; self.teamLabel = teamLabel; self.accent = accent
        self.origin = origin
        self.parentId = parentId; self.openJobs = openJobs
        self.flowHint = flowHint; self.missionRole = missionRole
    }
}

// MARK: - Node card

final class AgentNodeView: NSView {
    private(set) var model: AgentNodeModel
    var onMoved: ((AgentNodeModel, CGPoint) -> Void)?
    var onFront: ((AgentNodeModel) -> Void)?
    var onKill: ((AgentNodeModel) -> Void)?
    var onOptions: ((AgentNodeModel) -> Void)?
    var onPerms: ((AgentNodeModel) -> Void)?
    var onChangeModel: ((AgentNodeModel) -> Void)?
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onAddSub: ((AgentNodeModel) -> Void)?
    var onHuman: ((AgentNodeModel) -> Void)?
    var onRename: ((AgentNodeModel) -> Void)?
    var onHover: ((AgentNodeModel?) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var dragging = false
    private let accentRail = NSView()
    private let iconBadge = NSView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let teamField = NSTextField(labelWithString: "")
    private let idField = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Glowing activity dot — on when `SeatActivity.isActivelyWorking` (matches 3D).
    private let workingDot = NSView()
    private var buttons: [NSButton] = []
    private let actionBar = NSView()
    /// Job highlight (Mission/job → canvas link)
    var isJobHighlighted: Bool = false {
        didSet { needsDisplay = true; apply(model) }
    }

    /// Lattice-style floating module — cleaner, taller type, less chrome
    static let size = NSSize(width: 300, height: 152)
    /// Larger card when opened from the 3D map click
    static let moduleSize = NSSize(width: 380, height: 210)
    static let addSize = NSSize(width: 28, height: 28)

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    private var isAddChip: Bool {
        model.role == "add" || model.role == "add-sub"
    }

    init(model: AgentNodeModel) {
        self.model = model
        let sz = (model.role == "add" || model.role == "add-sub") ? Self.addSize : Self.size
        super.init(frame: NSRect(origin: model.origin, size: sz))
        wantsLayer = true
        layer?.cornerRadius = isAddChip ? 3 : PongTheme.radiusCard
        layer?.borderWidth = PongTheme.hairline
        layer?.masksToBounds = false

        if isAddChip {
            buildAddStyle()
        } else {
            buildCardStyle()
        }
        apply(model)
        toolTip = isAddChip
            ? "Add worker to this conductor"
            : "Drag to move · Open for terminal · Pencil to rename"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !isAddChip else { return }
        layoutCardChrome()
    }

    private func buildAddStyle() {
        // + chip docks on orchestrator → white line work shell
        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        layer?.borderColor = PongTheme.line.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 10
        layer?.shadowOffset = .zero
        let plus = NSTextField(labelWithString: "+")
        plus.font = PongTheme.font(16, weight: .medium)
        plus.textColor = PongTheme.textPrimary
        plus.alignment = .center
        plus.frame = NSRect(x: 0, y: 4, width: 28, height: 20)
        plus.isEditable = false
        plus.isBordered = false
        plus.backgroundColor = .clear
        plus.toolTip = model.role == "add-sub" ? "Add subagent under this worker" : "Add worker to conductor"
        addSubview(plus)
    }

    /// Visual selection (Lattice-style rings drawn under card).
    var isSelected: Bool = false {
        didSet { refreshSelectionChrome() }
    }

    private func refreshSelectionChrome() {
        guard !isAddChip else { return }
        apply(model)
        needsDisplay = true
    }

    private func buildCardStyle() {
        // Floating black panel — no texture noise (Anduril clarity)
        accentRail.wantsLayer = true
        accentRail.frame = NSRect(x: 0, y: 0, width: 2, height: Self.size.height)
        addSubview(accentRail)

        idField.font = PongTheme.labelFont(9)
        idField.textColor = PongTheme.textTertiary
        idField.frame = NSRect(x: 14, y: Self.size.height - 20, width: 80, height: 12)
        labelStyle(idField)
        addSubview(idField)

        teamField.font = PongTheme.labelFont(10)
        teamField.textColor = PongTheme.textSecondary
        teamField.frame = NSRect(x: 14, y: Self.size.height - 20, width: Self.size.width - 90, height: 12)
        labelStyle(teamField)
        addSubview(teamField)

        statusPill.frame = NSRect(x: Self.size.width - 72, y: Self.size.height - 24, width: 58, height: 16)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 2
        addSubview(statusPill)
        statusLabel.font = PongTheme.labelFont(9)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 0, y: 1, width: 58, height: 14)
        labelStyle(statusLabel)
        statusPill.addSubview(statusLabel)

        // Working glow (top-right of card, left of status pill)
        workingDot.wantsLayer = true
        workingDot.frame = NSRect(x: Self.size.width - 88, y: Self.size.height - 22, width: 10, height: 10)
        workingDot.layer?.cornerRadius = 5
        workingDot.layer?.backgroundColor = NSColor.clear.cgColor
        workingDot.isHidden = true
        workingDot.toolTip = "Working — job handoff in flight"
        addSubview(workingDot)

        iconBadge.frame = NSRect(x: 14, y: Self.size.height - 52, width: 24, height: 24)
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 12
        iconBadge.layer?.borderWidth = 1
        addSubview(iconBadge)
        iconLabel.font = PongTheme.font(12, weight: .medium)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 3, width: 24, height: 18)
        labelStyle(iconLabel)
        iconBadge.addSubview(iconLabel)
        // Role-shaped mark (hub / code) — not robot heads or generic terminal blocks
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            let name = model.role == "conductor"
                ? "point.3.filled.connected.trianglepath.dotted"
                : "chevron.left.forwardslash.chevron.right"
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: model.role)?
                .withSymbolConfiguration(cfg) {
                let iv = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
                iv.image = img
                iv.contentTintColor = model.role == "conductor" ? PongTheme.blue : PongTheme.magenta
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.identifier = NSUserInterfaceItemIdentifier("sfIcon")
                iconBadge.addSubview(iv)
                iconLabel.isHidden = true
            }
        }

        titleField.font = PongTheme.font(14, weight: .semibold)
        titleField.textColor = PongTheme.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        labelStyle(titleField)
        addSubview(titleField)

        // Pencil rename control (icon only — text "Edit" was easy to miss and hit-test broken)
        let pencil = NSButton(frame: .zero)
        pencil.bezelStyle = .inline
        pencil.isBordered = false
        pencil.setButtonType(.momentaryChange)
        pencil.wantsLayer = true
        pencil.layer?.cornerRadius = 4
        pencil.layer?.backgroundColor = NSColor.clear.cgColor
        pencil.toolTip = "Rename this seat"
        pencil.identifier = NSUserInterfaceItemIdentifier("editName")
        pencil.target = self
        pencil.action = #selector(renameTap)
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")?
                .withSymbolConfiguration(cfg)
            pencil.imagePosition = .imageOnly
            pencil.contentTintColor = PongTheme.textSecondary
        } else {
            pencil.title = "✎"
            pencil.font = PongTheme.font(13, weight: .medium)
            pencil.contentTintColor = PongTheme.textSecondary
        }
        addSubview(pencil)
        buttons.append(pencil)

        subField.font = PongTheme.font(11)
        subField.textColor = PongTheme.textSecondary
        subField.lineBreakMode = .byTruncatingTail
        labelStyle(subField)
        addSubview(subField)

        detailField.font = PongTheme.font(11)
        detailField.textColor = PongTheme.textTertiary
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byWordWrapping
        detailField.cell?.truncatesLastVisibleLine = true
        detailField.usesSingleLineMode = false
        labelStyle(detailField)
        addSubview(detailField)

        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(actionBar)

        let kill = makeBtn("Kill", #selector(killTap), style: .danger,
                           frame: NSRect(x: 0, y: 4, width: 48, height: 22))
        actionBar.addSubview(kill)
        buttons.append(kill)

        var x: CGFloat = 0
        func addLeft(_ t: String, _ sel: Selector, style: BtnStyle, w: CGFloat) {
            let b = makeBtn(t, sel, style: style, frame: NSRect(x: x, y: 4, width: w, height: 22))
            actionBar.addSubview(b)
            buttons.append(b)
            x += w + 6
        }
        addLeft("Open", #selector(frontTap), style: .primary, w: 48)
        if model.role == "conductor" {
            addLeft("Opts", #selector(optsTap), style: .secondary, w: 44)
            addLeft("You", #selector(humanTap), style: .secondary, w: 36)
        } else {
            addLeft("Policy", #selector(permsTap), style: .secondary, w: 48)
            addLeft("CLI", #selector(modelTap), style: .secondary, w: 36)
            if model.role != "subagent", model.parentId == nil {
                addLeft("+sub", #selector(addSubTap), style: .secondary, w: 40)
            }
        }

        layoutCardChrome()
    }

    /// Reposition title / pencil / chrome for both canvas size and expanded map module card.
    private func layoutCardChrome() {
        guard !isAddChip else { return }
        let w = bounds.width
        let h = bounds.height
        accentRail.frame = NSRect(x: 0, y: 0, width: 2, height: h)
        // Team name always on conductor (single + multi); workers keep optional team chip
        let rawTeam = model.teamLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamName = rawTeam.isEmpty && model.role == "conductor" ? model.session : rawTeam
        let hasTeam = !teamName.isEmpty
        let teamOnTop = model.role == "conductor" && hasTeam
        if teamOnTop {
            teamField.isHidden = false
            teamField.stringValue = "TEAM · \(teamName)"
            teamField.font = PongTheme.mono(10, weight: .semibold)
            teamField.textColor = model.accent
            teamField.frame = NSRect(x: 14, y: h - 18, width: max(60, w - 90), height: 12)
            idField.frame = NSRect(x: 14, y: h - 32, width: 80, height: 10)
            idField.font = PongTheme.labelFont(8)
        } else {
            teamField.isHidden = !hasTeam
            if hasTeam {
                teamField.stringValue = teamName
                teamField.font = PongTheme.labelFont(10)
                teamField.textColor = PongTheme.textSecondary
                teamField.frame = NSRect(x: 90, y: h - 20, width: max(60, w - 180), height: 12)
            }
            idField.frame = NSRect(x: 14, y: h - 20, width: 80, height: 12)
            idField.font = PongTheme.labelFont(9)
        }
        statusPill.frame = NSRect(x: w - 72, y: h - 24, width: 58, height: 16)
        workingDot.frame = NSRect(x: w - 88, y: h - 22, width: 10, height: 10)
        let iconY = teamOnTop ? h - 64 : h - 52
        iconBadge.frame = NSRect(x: 14, y: iconY, width: 24, height: 24)

        let pencilSize: CGFloat = 22
        let pencilX = w - pencilSize - 14
        let titleY = teamOnTop ? h - 62 : h - 50
        if let pencil = subviews.first(where: { $0.identifier?.rawValue == "editName" }) {
            pencil.frame = NSRect(x: pencilX, y: titleY - 1, width: pencilSize, height: pencilSize)
        }
        // Title leaves room for pencil on the right
        titleField.frame = NSRect(x: 46, y: titleY, width: max(60, pencilX - 52), height: 20)
        subField.frame = NSRect(x: 46, y: titleY - 18, width: max(60, w - 60), height: 14)

        let detailTop = titleY - 28
        let detailH = max(28, detailTop - 42)
        detailField.frame = NSRect(x: 14, y: 42, width: max(60, w - 28), height: detailH)

        let barW = w - 20
        actionBar.frame = NSRect(x: 10, y: 8, width: barW, height: 30)
        // Kill stays right-aligned in the bar
        for b in actionBar.subviews.compactMap({ $0 as? NSButton }) {
            let label = b.attributedTitle.string.isEmpty ? b.title : b.attributedTitle.string
            if label == "Kill" {
                b.frame = NSRect(x: barW - 48, y: 4, width: 48, height: 22)
            }
        }
    }

    private enum BtnStyle { case primary, secondary, danger }

    private func labelStyle(_ f: NSTextField) {
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        f.backgroundColor = .clear
    }

    private func makeBtn(_ title: String, _ sel: Selector, style: BtnStyle, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.wantsLayer = true
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.layer?.masksToBounds = true
        let font = PongTheme.labelFont(10)
        // Primary uses seat neon accent when set (else role default via model.accent)
        let roleColor = model.accent
        switch style {
        case .primary:
            b.layer?.backgroundColor = roleColor.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.black, .font: font,
            ])
        case .secondary:
            b.layer?.backgroundColor = NSColor.clear.cgColor
            b.layer?.borderWidth = PongTheme.hairline
            b.layer?.borderColor = PongTheme.line.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textPrimary, .font: font,
            ])
        case .danger:
            b.layer?.backgroundColor = NSColor.clear.cgColor
            b.layer?.borderWidth = PongTheme.hairline
            b.layer?.borderColor = PongTheme.danger.withAlphaComponent(0.5).cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.danger, .font: font,
            ])
        }
        b.target = self
        b.action = sel
        if title == "Kill" {
            b.toolTip = model.role == "conductor" ? "Kill entire team" : "Remove this seat"
        } else if title == "Policy" {
            b.toolTip = "Session access policy for this seat"
        } else if title == "CLI" {
            b.toolTip = "Switch this seat’s AI / CLI model"
        } else {
            b.toolTip = title
        }
        return b
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isAddChip else { return }
        // Selection / human: white line rings (structure); human keeps amber
        if isSelected || isJobHighlighted || model.status.lowercased().contains("human") {
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let col: NSColor = model.status.lowercased().contains("human")
                ? PongTheme.amber
                : PongTheme.lineStrong
            PongTheme.drawRings(center: c, radii: [bounds.width * 0.55, bounds.width * 0.72], color: col)
        }
    }

    func apply(_ m: AgentNodeModel) {
        model = m
        if !dragging, frame.origin != m.origin { setFrameOrigin(m.origin) }
        if m.role == "add" || m.role == "add-sub" { return }

        let isCond = m.role == "conductor"
        let human = m.status.lowercased().contains("human")
        // Snapshot sets accent from neon catalog highlight (or role default)
        let role: NSColor = human ? PongTheme.amber : m.accent

        accentRail.layer?.backgroundColor = role.cgColor

        titleField.stringValue = m.title
        subField.stringValue = m.subtitle
        detailField.stringValue = m.detail
        // teamField final layout in layoutCardChrome (conductor always TEAM · name)
        let team = m.teamLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamShown = team.isEmpty && m.role == "conductor" ? m.session : team
        teamField.stringValue = m.role == "conductor" && !teamShown.isEmpty
            ? "TEAM · \(teamShown)" : teamShown
        idField.stringValue = m.id.uppercased()
        layoutCardChrome()
        iconLabel.stringValue = isCond ? "◎" : "{}"
        iconLabel.textColor = role
        iconBadge.layer?.backgroundColor = role.withAlphaComponent(0.16).cgColor
        iconBadge.layer?.borderColor = role.withAlphaComponent(0.55).cgColor
        if #available(macOS 11.0, *) {
            for sub in iconBadge.subviews {
                if sub.identifier?.rawValue == "sfIcon", let iv = sub as? NSImageView {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                    let name = isCond
                        ? "point.3.filled.connected.trianglepath.dotted"
                        : "chevron.left.forwardslash.chevron.right"
                    iv.image = NSImage(systemSymbolName: name, accessibilityDescription: m.role)?
                        .withSymbolConfiguration(cfg)
                    iv.contentTintColor = role
                    iconLabel.isHidden = true
                }
            }
        }

        titleField.textColor = PongTheme.textPrimary
        subField.textColor = PongTheme.textSecondary
        detailField.textColor = PongTheme.textTertiary
        teamField.textColor = PongTheme.textTertiary
        idField.textColor = PongTheme.textTertiary

        // Glass module + white line work borders
        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        layer?.cornerRadius = PongTheme.radiusCard
        layer?.borderWidth = PongTheme.hairline
        if isSelected || isJobHighlighted {
            layer?.borderColor = PongTheme.lineStrong.cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.55
            layer?.shadowRadius = 18
        } else if human {
            layer?.borderColor = PongTheme.amber.withAlphaComponent(0.65).cgColor
            layer?.shadowColor = PongTheme.amber.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 14
        } else {
            layer?.borderColor = PongTheme.lineSoft.cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 12
        }
        layer?.shadowOffset = .zero

        // LIVE status uses role color; HUMAN stays amber
        let sk = PongTheme.statusKind(m.status)
        statusLabel.stringValue = sk.label
        if sk.label == "LIVE" {
            statusLabel.textColor = role
            statusPill.layer?.backgroundColor = (isCond ? PongTheme.blueSoft : PongTheme.magentaSoft).cgColor
        } else {
            statusLabel.textColor = sk.color
            statusPill.layer?.backgroundColor = sk.soft.cgColor
        }

        // Glowing activity dot — same rule as 3D packets / seat pulse
        let working = SeatActivity.isActivelyWorking(status: m.status, role: m.role)
        updateWorkingGlow(active: working, human: human, roleColor: role)
        needsDisplay = true
    }

    private func updateWorkingGlow(active: Bool, human: Bool, roleColor: NSColor) {
        workingDot.layer?.removeAnimation(forKey: "pulse")
        layer?.removeAnimation(forKey: "halo")
        guard active else {
            workingDot.isHidden = true
            workingDot.layer?.backgroundColor = NSColor.clear.cgColor
            workingDot.layer?.shadowOpacity = 0
            // Calm border/shadow when idle
            return
        }
        workingDot.isHidden = false
        let glow = human ? PongTheme.amber : roleColor
        workingDot.layer?.backgroundColor = glow.cgColor
        workingDot.layer?.shadowColor = glow.cgColor
        workingDot.layer?.shadowOffset = .zero
        workingDot.layer?.shadowRadius = 8
        workingDot.layer?.shadowOpacity = 0.95
        // Card halo — stronger presence when working (3D ring parity)
        layer?.shadowColor = glow.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 22
        layer?.shadowOffset = .zero
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.45
        anim.toValue = 1.0
        anim.duration = 0.7
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        workingDot.layer?.add(anim, forKey: "pulse")
        let halo = CABasicAnimation(keyPath: "shadowOpacity")
        halo.fromValue = 0.28
        halo.toValue = 0.7
        halo.duration = 0.85
        halo.autoreverses = true
        halo.repeatCount = .infinity
        layer?.add(halo, forKey: "halo")
    }

    @objc private func frontTap() {
        Pong.log("module Open tapped id=\(model.id) role=\(model.role) session=\(model.session)")
        onFront?(model)
    }
    @objc private func optsTap() { onOptions?(model) }
    @objc private func permsTap() { onPerms?(model) }
    @objc private func modelTap() { onChangeModel?(model) }
    @objc private func focusTap() { onFocus?(model) }
    @objc private func humanTap() { onHuman?(model) }
    @objc private func addSubTap() { onAddSub?(model) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in the receiver's superview coordinates
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Pencil rename (sibling of card, not in action bar)
        if let edit = subviews.first(where: { $0.identifier?.rawValue == "editName" }),
           edit.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return edit
        }
        // Prefer action-bar buttons so Open/Opts receive the click (not drag)
        if actionBar.frame.contains(local) {
            let inBar = actionBar.convert(local, from: self)
            for b in actionBar.subviews.compactMap({ $0 as? NSButton }) where b.frame.contains(inBar) {
                return b
            }
            // Click on bar chrome still shouldn't start a drag — handle Open if near it
            return actionBar
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if model.role == "add" || model.role == "add-sub" {
            onAddWorker?(model)
            return
        }
        (superview as? AgentCanvasView)?.select(globalId: model.globalId)
        let local = convert(event.locationInWindow, from: nil)
        // Pencil → rename immediately (custom hitTest can miss when card is over SceneKit)
        if let edit = subviews.first(where: { $0.identifier?.rawValue == "editName" }),
           edit.frame.insetBy(dx: -6, dy: -6).contains(local) {
            renameTap()
            return
        }
        // Buttons (Open / Kill…) — if hitTest missed them, fire manually when
        // the primary left segment is clicked (module card over SceneKit is finicky).
        if actionBar.frame.contains(local) {
            let inBar = actionBar.convert(local, from: self)
            for b in actionBar.subviews.compactMap({ $0 as? NSButton }) where b.frame.contains(inBar) {
                let label = b.attributedTitle.string.isEmpty ? b.title : b.attributedTitle.string
                if label == "Open" {
                    frontTap()
                    return
                }
                if let action = b.action, let target = b.target {
                    _ = target.perform(action, with: b)
                } else {
                    b.performClick(nil)
                }
                return
            }
            // Fallback: left side of action bar = Open
            if inBar.x < 70 {
                frontTap()
            }
            return
        }
        if event.clickCount >= 2 {
            // Double-click title → rename only (never open terminal)
            if titleField.frame.insetBy(dx: -8, dy: -4).contains(local)
                || subField.frame.insetBy(dx: -8, dy: -2).contains(local) {
                onRename?(model)
            }
            return
        }
        dragStart = event.locationInWindow
        originStart = frame.origin
        dragging = true
        onDragBegan?()
        superview?.addSubview(self)
        // Keep action bar + pencil above siblings after re-add
        addSubview(actionBar)
        if let edit = subviews.first(where: { $0.identifier?.rawValue == "editName" }) {
            addSubview(edit)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        var nx = originStart.x + (p.x - dragStart.x)
        var ny = originStart.y + (p.y - dragStart.y)
        nx = max(4, nx)
        ny = max(4, ny)
        // Grow document when seat approaches edges so orch can leave the left HUD zone
        if let canvas = superV as? AgentCanvasView {
            let expanded = CanvasLayout.expandSize(
                canvas.bounds.size,
                toFit: CGPoint(x: nx, y: ny),
                card: bounds.size
            )
            if expanded.width > canvas.bounds.width + 0.5 || expanded.height > canvas.bounds.height + 0.5 {
                canvas.setFrameSize(expanded)
            }
        }
        // Clamp only to (possibly expanded) document bounds
        nx = min(nx, max(4, superV.bounds.width - bounds.width - 4))
        ny = min(ny, max(4, superV.bounds.height - bounds.height - 4))
        let snapped = CanvasLayout.snap(CGPoint(x: nx, y: ny))
        setFrameOrigin(snapped)
        if let canvas = superview as? AgentCanvasView {
            canvas.layoutDockedAddButtons()
            canvas.needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            if let dragStart {
                let p = event.locationInWindow
                let moved = hypot(p.x - dragStart.x, p.y - dragStart.y)
                // Click-without-drag: select only — Open button is the sole terminal entry
                if moved >= 4 {
                    let snapped = CanvasLayout.snap(frame.origin)
                    setFrameOrigin(snapped)
                    onMoved?(model, snapped)
                }
            } else {
                let snapped = CanvasLayout.snap(frame.origin)
                setFrameOrigin(snapped)
                onMoved?(model, snapped)
            }
            onDragEnded?()
        }
        dragging = false
        dragStart = nil
        originStart = nil
        (superview as? AgentCanvasView)?.needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard model.role != "add" else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open terminal", action: #selector(frontTap), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…", action: #selector(renameTap), keyEquivalent: "")
        if model.role == "conductor" {
            // Team activity recap is on the map TASKS panel (under YOU).
            menu.addItem(withTitle: "Add worker…", action: #selector(addFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Team options", action: #selector(optsTap), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Kill team", action: #selector(killTap), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Add subagent…", action: #selector(addFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Seat policy", action: #selector(permsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Switch CLI / model…", action: #selector(modelTap), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Remove seat", action: #selector(killTap), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func killTap() { onKill?(model) }
    @objc private func renameTap() { onRename?(model) }
    @objc private func addFromMenu() {
        // Worker context → treat as subagent request; orchestrator → worker
        if model.role == "worker" {
            // Synthesize add-sub identity for handler
            let sub = AgentNodeModel(
                session: model.session, id: "add-sub-\(model.id)", role: "add-sub",
                title: "+", subtitle: "subagent", detail: "", status: "idle",
                teamLabel: "", accent: PongTheme.blue, origin: model.origin
            )
            onAddWorker?(sub)
        } else {
            onAddWorker?(model)
        }
    }
}

private extension NSView {
    func enclosingNodeView() -> AgentNodeView? {
        var v: NSView? = self
        while let cur = v {
            if let n = cur as? AgentNodeView { return n }
            v = cur.superview
        }
        return nil
    }

    func enclosingButton() -> NSButton? {
        var v: NSView? = self
        while let cur = v {
            if let b = cur as? NSButton { return b }
            v = cur.superview
        }
        return nil
    }
}

// MARK: - Canvas

final class AgentCanvasView: NSView {
    private(set) var isDragging = false
    private(set) var isPanning = false
    private var multiTeam = false
    private var models: [AgentNodeModel] = []
    private var nodeViews: [String: AgentNodeView] = [:]
    private var panStart: NSPoint?
    private var scrollOriginStart: NSPoint?
    private(set) var selectedGlobalId: String?
    private(set) var highlightedGlobalIds: Set<String> = []
    /// Live positions win over disk until next full save — stops poll from jumping cards.
    private var liveOrigins: [String: CGPoint] = [:]

    var onFront: ((AgentNodeModel) -> Void)?
    var onKill: ((AgentNodeModel) -> Void)?
    var onOptions: ((AgentNodeModel) -> Void)?
    var onPerms: ((AgentNodeModel) -> Void)?
    var onChangeModel: ((AgentNodeModel) -> Void)?
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onAddSub: ((AgentNodeModel) -> Void)?
    var onHuman: ((AgentNodeModel) -> Void)?
    var onRename: ((AgentNodeModel) -> Void)?
    var onHover: ((AgentNodeModel?) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onSelectionChanged: ((AgentNodeModel?) -> Void)?

    /// Animated flow phase 0…1 for live edge packets (Phase 1 parity)
    private var flowPhase: CGFloat = 0
    private var flowTimer: Timer?
    /// Linger for live edges after last active signal (match 3D ~5s)
    private var edgeFlowExpire: [String: TimeInterval] = [:]
    private let flowLingerSec: TimeInterval = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bg.cgColor
        startFlowTimer()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func startFlowTimer() {
        flowTimer?.invalidate()
        // 15fps is plenty for packets; only dirty the edge band, never the whole map
        flowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            let anyLive = self.edgeFlowExpire.values.contains(where: { $0 > now })
            guard anyLive || !self.edgeFlowExpire.isEmpty else { return }
            self.flowPhase = (self.flowPhase + 0.04).truncatingRemainder(dividingBy: 1)
            // Expire stale keys so we stop animating
            self.edgeFlowExpire = self.edgeFlowExpire.filter { $0.value > now - 0.5 }
            if let box = self.contentBoundsOfNodes() {
                self.setNeedsDisplay(box.insetBy(dx: -80, dy: -80))
            } else {
                self.needsDisplay = true
            }
        }
        if let flowTimer { RunLoop.main.add(flowTimer, forMode: .common) }
    }

    func select(globalId: String?) {
        selectedGlobalId = globalId
        for (id, v) in nodeViews {
            v.isSelected = (id == globalId)
        }
        let m = models.first(where: { $0.globalId == globalId })
        onSelectionChanged?(m)
        needsDisplay = true
    }

    func clearSelection() { select(globalId: nil) }

    /// Highlight seats related to a job (Mission → canvas).
    func highlight(globalIds: Set<String>) {
        highlightedGlobalIds = globalIds
        for (id, v) in nodeViews {
            v.isJobHighlighted = globalIds.contains(id)
        }
        needsDisplay = true
    }

    func clearHighlights() { highlight(globalIds: []) }

    /// Bounding rect of seat cards (excludes docked + chips).
    func contentBoundsOfNodes() -> NSRect? {
        let seats = models.filter { $0.role == "conductor" || $0.role == "worker" }
        guard !seats.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for m in seats {
            let f = nodeViews[m.globalId]?.frame
                ?? NSRect(origin: m.origin, size: AgentNodeView.size)
            minX = min(minX, f.minX)
            minY = min(minY, f.minY)
            maxX = max(maxX, f.maxX)
            maxY = max(maxY, f.maxY)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Retheme nodes after light/dark flip without rebuild.
    func retheme() {
        layer?.backgroundColor = PongTheme.bg.cgColor
        for (_, v) in nodeViews {
            // force chrome refresh
            if let m = models.first(where: { $0.globalId == v.model.globalId }) {
                v.apply(m)
            }
            v.isSelected = (v.model.globalId == selectedGlobalId)
        }
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Background hit → pan; nodes handle themselves.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in superview coords
        guard let hit = super.hitTest(point) else { return nil }
        if hit is AgentNodeView || hit.enclosingNodeView() != nil {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Only pan if click is not on a node
        let local = convert(event.locationInWindow, from: nil)
        for (_, v) in nodeViews {
            if v.frame.contains(local) { return }
        }
        clearSelection()
        guard let scroll = enclosingScrollView else { return }
        panStart = event.locationInWindow
        scrollOriginStart = scroll.contentView.bounds.origin
        isPanning = true
        onDragStateChanged?(true)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let panStart, let scrollOriginStart,
              let scroll = enclosingScrollView else { return }
        let p = event.locationInWindow
        // Clip-view bounds are in document space; window deltas ÷ magnification
        let mag = max(0.01, scroll.magnification)
        let dx = (p.x - panStart.x) / mag
        let dy = (p.y - panStart.y) / mag
        var origin = scrollOriginStart
        // Grab-and-drag: content follows the cursor
        origin.x -= dx
        origin.y -= dy
        let doc = bounds.size
        let vis = scroll.contentView.bounds.size
        let maxX = max(0, doc.width - vis.width)
        let maxY = max(0, doc.height - vis.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        self.panStart = p
        self.scrollOriginStart = origin
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            panStart = nil
            scrollOriginStart = nil
            onDragStateChanged?(false)
            NSCursor.arrow.set()
        }
    }

    // Trackpad / mouse-wheel: do NOT override — NSScrollView owns momentum pan
    // and rubber-banding when the document is larger than the clip view.

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Only paint the dirty region — full-document grid on a large canvas
        // was ~1M ovals/frame and made 2D take seconds to open.
        let clip = dirtyRect.intersection(bounds)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return }

        PongTheme.bg.setFill()
        clip.fill()

        // Dotted grid only inside dirtyRect
        let step = CanvasLayout.gridStep
        let r: CGFloat = PongTheme.appearance == .dark ? 0.9 : 0.75
        let a: CGFloat = PongTheme.appearance == .dark ? 0.18 : 0.14
        PongTheme.ink.withAlphaComponent(a).setFill()
        let x0 = max(step, (clip.minX / step).rounded(.down) * step)
        let y0 = max(step, (clip.minY / step).rounded(.down) * step)
        var x = x0
        while x <= clip.maxX + step {
            var y = y0
            while y <= clip.maxY + step {
                if clip.insetBy(dx: -2, dy: -2).contains(NSPoint(x: x, y: y)) {
                    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
                }
                y += step
            }
            x += step
        }

        // Edges from live flow_graph (same topology as 3D / Architecture canvas).
        // Fallback: FlowGraph.defaultEdges when graph empty.
        let sessions = Set(models.map(\.session))
        let db = PairState.loadPairsDb()
        for sess in sessions {
            let entry = db[sess] as? [String: Any] ?? [:]
            let edges = FlowGraph.load(from: entry)
            let byId: [String: AgentNodeModel] = {
                var m: [String: AgentNodeModel] = [:]
                for n in models where n.session == sess {
                    m[n.id] = n
                }
                return m
            }()

            for edge in edges {
                guard let fromM = byId[edge.from], let toM = byId[edge.to],
                      let fv = nodeViews[fromM.globalId],
                      let tv = nodeViews[toM.globalId] else { continue }
                // Never draw to add chips
                if fromM.role == "add" || fromM.role == "add-sub"
                    || toM.role == "add" || toM.role == "add-sub" { continue }

                let style = edgeStyle(kind: edge.kind)
                let (fromPt, toPt) = edgeEndpoints(
                    fromFrame: fv.frame, toFrame: tv.frame, style: style
                )
                let human = fromM.status.lowercased().contains("human")
                    || toM.status.lowercased().contains("human")
                let live = SeatActivity.linkHasLiveData(
                    fromStatus: fromM.status, fromRole: fromM.role,
                    toStatus: toM.status, toRole: toM.role
                )
                let label: String = {
                    if human { return "needs you" }
                    if live {
                        switch edge.kind {
                        case "claim": return "claim · send"
                        case "peer": return "peer · live"
                        case "sub": return "sub · live"
                        case "review": return "review · live"
                        default: return "assign · live"
                        }
                    }
                    let raw = edge.label.isEmpty
                        ? FlowGraph.Edge.defaultLabel(kind: edge.kind)
                        : edge.label
                    return raw.lowercased()
                }()
                let edgeKey = "\(sess)|\(edge.id)"
                let now = Date().timeIntervalSince1970
                if live { edgeFlowExpire[edgeKey] = now + flowLingerSec }
                let flowing = live || (edgeFlowExpire[edgeKey] ?? 0) > now
                drawEdge(
                    from: fromPt, to: toPt,
                    human: human, live: flowing, style: style, label: label,
                    animatePackets: flowing
                )
            }
        }
    }

    private enum EdgeStyle { case orchToWorker, workerPeer, claimBack }

    private func edgeStyle(kind: String) -> EdgeStyle {
        switch kind.lowercased() {
        case "peer": return .workerPeer
        case "claim", "review": return .claimBack
        default: return .orchToWorker // delegate, sub, …
        }
    }

    private func edgeEndpoints(
        fromFrame: NSRect, toFrame: NSRect, style: EdgeStyle
    ) -> (NSPoint, NSPoint) {
        switch style {
        case .orchToWorker:
            return (
                NSPoint(x: fromFrame.maxX - 2, y: fromFrame.midY),
                NSPoint(x: toFrame.minX + 2, y: toFrame.midY)
            )
        case .workerPeer:
            return (
                NSPoint(x: fromFrame.maxX - 18, y: fromFrame.minY + 4),
                NSPoint(x: toFrame.maxX - 18, y: toFrame.maxY - 4)
            )
        case .claimBack:
            // Agent → orch / parent (upward-ish)
            return (
                NSPoint(x: fromFrame.midX, y: fromFrame.maxY - 2),
                NSPoint(x: toFrame.midX, y: toFrame.minY + 2)
            )
        }
    }

    private func drawEdge(
        from: NSPoint, to: NSPoint,
        human: Bool, live: Bool, style: EdgeStyle, label: String,
        animatePackets: Bool = false
    ) {
        let path = NSBezierPath()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        let midY = (from.y + to.y) / 2
        let c1: NSPoint
        let c2: NSPoint
        switch style {
        case .orchToWorker:
            c1 = NSPoint(x: midX, y: from.y)
            c2 = NSPoint(x: midX, y: to.y)
        case .workerPeer:
            c1 = NSPoint(x: from.x + 12, y: from.y - abs(from.y - to.y) * 0.25)
            c2 = NSPoint(x: to.x + 12, y: to.y + abs(from.y - to.y) * 0.25)
        case .claimBack:
            c1 = NSPoint(x: from.x, y: midY)
            c2 = NSPoint(x: to.x, y: midY)
        }
        path.curve(to: to, controlPoint1: c1, controlPoint2: c2)

        // Graph edges = white line work; human amber; live edges brighten
        let base: NSColor = human
            ? PongTheme.amber
            : (style == .workerPeer || style == .claimBack ? PongTheme.lineSoft : PongTheme.line)
        let color: NSColor = live && !human
            ? PongTheme.lineStrong
            : base

        let under: CGFloat = live ? 4.0 : (style == .workerPeer || style == .claimBack ? 2.5 : 3.5)
        path.lineWidth = under
        color.withAlphaComponent(live ? 0.35 : 0.2).setStroke()
        path.stroke()
        path.lineWidth = live ? 1.8 : (style == .workerPeer || style == .claimBack ? 1.15 : 1.4)
        if style == .workerPeer || style == .claimBack {
            let dashes: [CGFloat] = style == .claimBack ? [3, 5] : [4, 4]
            path.setLineDash(dashes, count: 2, phase: 0)
        }
        color.setStroke()
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)

        drawArrowHead(at: to, from: c2, color: color)

        // Origin glow when link is live (working)
        let r: CGFloat = live ? 3.5 : 2.5
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()
        if live {
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: from.x - r * 2, y: from.y - r * 2, width: r * 4, height: r * 4)).fill()
        }

        // Traveling packets when data flows (3D floor-dot parity)
        if animatePackets {
            for i in 0..<2 {
                let t = (flowPhase + CGFloat(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let pt = cubicBezier(t: t, p0: from, c1: c1, c2: c2, p3: to)
                let pr: CGFloat = 3.2
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: pt.x - pr, y: pt.y - pr, width: pr * 2, height: pr * 2)).fill()
                color.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: pt.x - pr * 2, y: pt.y - pr * 2, width: pr * 4, height: pr * 4)).fill()
            }
        }

        guard !label.isEmpty else { return }
        let bx = 0.125 * from.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * to.x
        let by = 0.125 * from.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * to.y
        let attrs: [NSAttributedString.Key: Any] = [
            .font: PongTheme.labelFont(9),
            .foregroundColor: human ? PongTheme.amber : PongTheme.textPrimary,
            .backgroundColor: PongTheme.bg.withAlphaComponent(0.9),
        ]
        let s = NSAttributedString(string: " \(label) ", attributes: attrs)
        let sz = s.size()
        let labelOrigin = NSPoint(x: bx - sz.width / 2, y: by - sz.height / 2)
        let pill = NSBezierPath(roundedRect: NSRect(x: labelOrigin.x - 3, y: labelOrigin.y - 1,
                                                    width: sz.width + 6, height: sz.height + 2),
                                xRadius: 3, yRadius: 3)
        PongTheme.bgElevated.setFill()
        pill.fill()
        (live ? color : PongTheme.lineSoft).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        s.draw(at: labelOrigin)
    }

    /// Cubic Bezier point (matches NSBezierPath curve)
    private func cubicBezier(t: CGFloat, p0: NSPoint, c1: NSPoint, c2: NSPoint, p3: NSPoint) -> NSPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t
        var p = NSPoint(x: uuu * p0.x, y: uuu * p0.y)
        p.x += 3 * uu * t * c1.x
        p.y += 3 * uu * t * c1.y
        p.x += 3 * u * tt * c2.x
        p.y += 3 * u * tt * c2.y
        p.x += ttt * p3.x
        p.y += ttt * p3.y
        return p
    }

    private func drawArrowHead(at tip: NSPoint, from: NSPoint, color: NSColor) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let len: CGFloat = 10
        let spread: CGFloat = .pi / 7
        let p1 = NSPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread))
        let p2 = NSPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread))
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: p1)
        arrow.line(to: p2)
        arrow.close()
        color.withAlphaComponent(0.9).setFill()
        arrow.fill()
    }

    func reload(models: [AgentNodeModel], multiTeam: Bool) {
        if isDragging { return }
        self.multiTeam = multiTeam
        // Prefer live origins (just dragged) over disk so poll never jumps cards
        var merged = models
        for i in merged.indices {
            let gid = merged[i].globalId
            if let live = liveOrigins[gid] {
                merged[i].origin = live
            } else if let view = nodeViews[gid], !view.frame.origin.equalTo(.zero) {
                // Keep current frame if model has no better saved point and we already laid out
                // Only when disk origin matches default-ish jump would hurt — use live map only
            }
        }
        self.models = merged
        let keep = Set(merged.map(\.globalId))
        for (id, v) in nodeViews where !keep.contains(id) {
            v.removeFromSuperview()
            nodeViews[id] = nil
            liveOrigins[id] = nil
        }
        if let sel = selectedGlobalId, !keep.contains(sel) {
            selectedGlobalId = nil
        }
        for m in merged {
            if let existing = nodeViews[m.globalId] {
                existing.apply(m)
                existing.isSelected = (m.globalId == selectedGlobalId)
            } else {
                let v = AgentNodeView(model: m)
                wire(v)
                addSubview(v)
                nodeViews[m.globalId] = v
                v.isSelected = (m.globalId == selectedGlobalId)
            }
        }
        layoutDockedAddButtons()
        needsDisplay = true
    }

    /// Keep + chips glued to the right edge of their parent card (never free-float).
    func layoutDockedAddButtons() {
        for m in models where m.role == "add" || m.role == "add-sub" {
            guard let av = nodeViews[m.globalId] else { continue }
            let parentId: String
            if m.role == "add" {
                // dock to orchestrator
                guard let c = models.first(where: { $0.session == m.session && $0.role == "conductor" }),
                      let cv = nodeViews[c.globalId] else { continue }
                parentId = c.globalId
                _ = parentId
                let o = CGPoint(
                    x: cv.frame.maxX + 6,
                    y: cv.frame.midY - av.bounds.height / 2
                )
                av.setFrameOrigin(o)
            } else {
                // add-sub: dock to worker named in m.id after "add-sub-"
                let workerId = m.id.replacingOccurrences(of: "add-sub-", with: "")
                guard let w = models.first(where: { $0.session == m.session && $0.id == workerId }),
                      let wv = nodeViews[w.globalId] else { continue }
                let o = CGPoint(
                    x: wv.frame.maxX + 6,
                    y: wv.frame.midY - av.bounds.height / 2
                )
                av.setFrameOrigin(o)
            }
        }
    }

    private func wire(_ v: AgentNodeView) {
        v.onMoved = { [weak self] m, origin in
            self?.persist(m, origin: origin)
            self?.layoutDockedAddButtons()
            self?.needsDisplay = true
        }
        v.onFront = { [weak self] m in self?.onFront?(m) }
        v.onKill = { [weak self] m in self?.onKill?(m) }
        v.onOptions = { [weak self] m in self?.onOptions?(m) }
        v.onPerms = { [weak self] m in self?.onPerms?(m) }
        v.onChangeModel = { [weak self] m in self?.onChangeModel?(m) }
        v.onFocus = { [weak self] m in self?.onFocus?(m) }
        v.onAddWorker = { [weak self] m in self?.onAddWorker?(m) }
        v.onAddSub = { [weak self] m in self?.onAddSub?(m) }
        v.onHuman = { [weak self] m in self?.onHuman?(m) }
        v.onRename = { [weak self] m in self?.onRename?(m) }
        v.onDragBegan = { [weak self] in
            self?.isDragging = true
            self?.onDragStateChanged?(true)
        }
        v.onDragEnded = { [weak self] in
            self?.isDragging = false
            self?.onDragStateChanged?(false)
            self?.layoutDockedAddButtons()
            self?.needsDisplay = true
        }
    }

    private func persist(_ m: AgentNodeModel, origin: CGPoint) {
        if m.role == "add" || m.role == "add-sub" { return }
        let snapped = CanvasLayout.snap(origin)
        liveOrigins[m.globalId] = snapped
        // Grow canvas after drop if needed
        let expanded = CanvasLayout.expandSize(bounds.size, toFit: snapped, card: AgentNodeView.size)
        if expanded.width > bounds.width + 0.5 || expanded.height > bounds.height + 0.5 {
            setFrameSize(expanded)
        }
        // Live write: pair dual bare+scoped; canvas-all scoped-only
        CanvasLayout.saveSeat(session: m.session, nodeId: m.id, origin: snapped)
        if let i = models.firstIndex(where: { $0.globalId == m.globalId }) {
            models[i].origin = snapped
        }
        if let v = nodeViews[m.globalId] {
            v.setFrameOrigin(snapped)
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutDockedAddButtons()
        needsDisplay = true
    }
}

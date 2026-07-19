import AppKit

// MARK: - Positions (keyed "session::nodeId" for multi-team, or bare id for single)

enum CanvasLayout {
    static func key(session: String, nodeId: String, multi: Bool) -> String {
        multi ? "\(session)::\(nodeId)" : nodeId
    }

    static func positions(for session: String?) -> [String: CGPoint] {
        // When session nil = all-teams map lives under active or special file
        if let session {
            return loadMap(from: PairState.loadPairsDb()[session] as? [String: Any] ?? [:])
        }
        return loadMap(from: Pong.loadJSON(Pong.stateDir + "/canvas-all.json"))
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

    static func save(session: String?, positions: [String: CGPoint], multi: Bool) {
        var raw: [String: [String: Any]] = [:]
        for (k, p) in positions {
            raw[k] = ["x": Double(p.x), "y": Double(p.y)]
        }
        if multi || session == nil {
            Pong.writeJSON(Pong.stateDir + "/canvas-all.json", ["canvas_positions": raw, "updated": Date().timeIntervalSince1970])
            return
        }
        guard let session else { return }
        var db = PairState.loadPairsDb()
        var entry = db[session] as? [String: Any] ?? [:]
        entry["canvas_positions"] = raw
        entry["updated"] = Date().timeIntervalSince1970
        db[session] = entry
        Pong.writeJSON(PairState.pairsPath, db)
    }

    /// Cluster layout: each team gets a horizontal band.
    static func defaultPosition(teamIndex: Int, role: String, workerIndex: Int, canvas: CGSize, multi: Bool) -> CGPoint {
        let clusterX = multi ? 40 + CGFloat(teamIndex) * 520 : max(48, canvas.width * 0.14)
        let clusterY = multi ? max(80, canvas.height * 0.35) : max(100, canvas.height * 0.42)
        if role == "conductor" {
            return CGPoint(x: clusterX, y: clusterY)
        }
        return CGPoint(x: clusterX + 300, y: max(50, clusterY - 40) + CGFloat(workerIndex) * 160)
    }
}

// MARK: - Model

struct AgentNodeModel {
    let session: String
    let id: String          // local: c1, w1
    var globalId: String { "\(session)::\(id)" }
    let role: String        // conductor | worker | add
    let title: String
    let subtitle: String
    let detail: String
    let status: String
    let teamLabel: String
    let accent: NSColor
    var origin: CGPoint
}

// MARK: - Node card

final class AgentNodeView: NSView {
    let model: AgentNodeModel
    var onMoved: ((AgentNodeModel, CGPoint) -> Void)?
    var onFront: ((AgentNodeModel) -> Void)?
    var onKill: ((AgentNodeModel) -> Void)?
    var onOptions: ((AgentNodeModel) -> Void)?
    var onPerms: ((AgentNodeModel) -> Void)?
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var dragging = false
    private let iconBadge = NSView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let teamField = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private let actionBar = NSView()

    static let size = NSSize(width: 268, height: 160)
    /// Compact dock chip on card edge (not a free-floating blob)
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
        layer?.cornerRadius = isAddChip ? 14 : 16
        layer?.borderWidth = 1
        layer?.masksToBounds = false

        if isAddChip {
            buildAddStyle()
        } else {
            buildCardStyle()
        }
        apply(model)
        toolTip = isAddChip
            ? "Add worker to this orchestrator"
            : "Drag header to move · Open / Focus / Perms / Kill on the action bar"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildAddStyle() {
        let isSub = model.role == "add-sub"
        layer?.backgroundColor = (isSub ? PongTheme.blueSoft : PongTheme.magentaSoft).cgColor
        layer?.borderColor = (isSub ? PongTheme.blue : PongTheme.magenta).withAlphaComponent(0.6).cgColor
        layer?.shadowColor = (isSub ? PongTheme.blue : PongTheme.magenta).cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 6
        layer?.shadowOffset = .zero
        let plus = NSTextField(labelWithString: "+")
        plus.font = PongTheme.font(14, weight: .semibold)
        plus.textColor = isSub ? PongTheme.blue : PongTheme.magenta
        plus.alignment = .center
        plus.frame = NSRect(x: 0, y: 4, width: 28, height: 20)
        plus.isEditable = false
        plus.isBordered = false
        plus.backgroundColor = .clear
        plus.toolTip = isSub ? "Add subagent under this worker" : "Add worker to orchestrator"
        addSubview(plus)
    }

    private func buildCardStyle() {
        iconBadge.frame = NSRect(x: 14, y: Self.size.height - 48, width: 32, height: 32)
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 10
        addSubview(iconBadge)
        iconLabel.font = PongTheme.font(14, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 6, width: 32, height: 20)
        labelStyle(iconLabel)
        iconBadge.addSubview(iconLabel)

        statusPill.frame = NSRect(x: Self.size.width - 88, y: Self.size.height - 34, width: 74, height: 22)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 6
        addSubview(statusPill)
        statusLabel.font = PongTheme.font(9, weight: .bold)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 0, y: 3, width: 74, height: 16)
        labelStyle(statusLabel)
        statusPill.addSubview(statusLabel)

        teamField.font = PongTheme.font(9, weight: .medium)
        teamField.textColor = PongTheme.textTertiary
        teamField.frame = NSRect(x: 14, y: Self.size.height - 18, width: 140, height: 12)
        labelStyle(teamField)
        addSubview(teamField)

        titleField.font = PongTheme.font(13, weight: .semibold)
        titleField.textColor = PongTheme.textPrimary
        titleField.frame = NSRect(x: 54, y: Self.size.height - 48, width: 110, height: 18)
        titleField.lineBreakMode = .byTruncatingTail
        labelStyle(titleField)
        addSubview(titleField)

        subField.font = PongTheme.font(10)
        subField.textColor = PongTheme.textSecondary
        subField.frame = NSRect(x: 54, y: Self.size.height - 64, width: 110, height: 14)
        labelStyle(subField)
        addSubview(subField)

        // Detail sits above the fixed action bar
        detailField.font = PongTheme.font(10)
        detailField.textColor = PongTheme.textTertiary
        detailField.frame = NSRect(x: 14, y: 48, width: Self.size.width - 28, height: 26)
        detailField.maximumNumberOfLines = 2
        labelStyle(detailField)
        addSubview(detailField)

        // —— Action bar (always visible, full width) ——
        actionBar.frame = NSRect(x: 8, y: 8, width: Self.size.width - 16, height: 34)
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = PongTheme.bgInput.cgColor
        actionBar.layer?.cornerRadius = 10
        actionBar.layer?.borderWidth = 1
        actionBar.layer?.borderColor = PongTheme.border.cgColor
        addSubview(actionBar)

        var x: CGFloat = 6
        func addBtn(_ t: String, _ sel: Selector, style: BtnStyle, w: CGFloat) {
            let b = makeBtn(t, sel, style: style, frame: NSRect(x: x, y: 5, width: w, height: 24))
            actionBar.addSubview(b)
            buttons.append(b)
            x += w + 5
        }
        // Primary actions both roles
        addBtn("Open", #selector(frontTap), style: .primary, w: 50)
        if model.role == "conductor" {
            addBtn("Focus", #selector(focusTap), style: .secondary, w: 48)
            addBtn("Opts", #selector(optsTap), style: .secondary, w: 44)
            addBtn("Kill", #selector(killTap), style: .danger, w: 42)
        } else {
            addBtn("Perms", #selector(permsTap), style: .secondary, w: 48)
            addBtn("Kill", #selector(killTap), style: .danger, w: 42)
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
        b.layer?.cornerRadius = 7
        b.layer?.masksToBounds = true
        let font = PongTheme.font(10, weight: .semibold)
        switch style {
        case .primary:
            b.layer?.backgroundColor = PongTheme.blue.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white, .font: font,
            ])
        case .secondary:
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.borderStrong.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textPrimary, .font: font,
            ])
        case .danger:
            b.layer?.backgroundColor = PongTheme.danger.withAlphaComponent(0.2).cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.danger.withAlphaComponent(0.45).cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.danger, .font: font,
            ])
        }
        b.target = self
        b.action = sel
        b.toolTip = title
        return b
    }

    func apply(_ m: AgentNodeModel) {
        if !dragging, frame.origin != m.origin { setFrameOrigin(m.origin) }
        if m.role == "add" || m.role == "add-sub" { return }

        titleField.stringValue = m.title
        subField.stringValue = m.subtitle
        detailField.stringValue = m.detail
        teamField.stringValue = m.teamLabel
        iconLabel.stringValue = m.role == "conductor" ? "◎" : "◇"
        iconLabel.textColor = m.role == "conductor" ? PongTheme.blue : PongTheme.magenta
        iconBadge.layer?.backgroundColor = (m.role == "conductor" ? PongTheme.blueSoft : PongTheme.magentaSoft).cgColor

        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        if m.role == "conductor" {
            layer?.borderColor = PongTheme.borderAccent.cgColor
            layer?.shadowColor = PongTheme.blue.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 16
            layer?.shadowOffset = .zero
        } else {
            // Magenta glow behind workers
            layer?.borderColor = PongTheme.magenta.withAlphaComponent(0.35).cgColor
            layer?.shadowColor = PongTheme.magenta.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 14
            layer?.shadowOffset = .zero
        }
        let sk = PongTheme.statusKind(m.status)
        statusLabel.stringValue = sk.label
        statusLabel.textColor = sk.color
        statusPill.layer?.backgroundColor = sk.soft.cgColor
    }

    @objc private func frontTap() { onFront?(model) }
    @objc private func optsTap() { onOptions?(model) }
    @objc private func permsTap() { onPerms?(model) }
    @objc private func focusTap() { onFocus?(model) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in superview coordinates
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Prefer action-bar buttons (coords relative to actionBar)
        let inBar = actionBar.convert(local, from: self)
        for b in buttons {
            if b.frame.contains(inBar) { return b }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if model.role == "add" || model.role == "add-sub" {
            onAddWorker?(model)
            return
        }
        if event.clickCount >= 2 {
            onFront?(model)
            return
        }
        // Don't start drag if press is on the action bar
        let local = convert(event.locationInWindow, from: nil)
        if actionBar.frame.contains(local) { return }
        dragStart = event.locationInWindow
        originStart = frame.origin
        dragging = true
        onDragBegan?()
        superview?.addSubview(self)
        // Keep action bar above siblings after re-add
        addSubview(actionBar)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        var nx = originStart.x + (p.x - dragStart.x)
        var ny = originStart.y + (p.y - dragStart.y)
        nx = min(max(8, nx), max(8, superV.bounds.width - bounds.width - 8))
        ny = min(max(8, ny), max(8, superV.bounds.height - bounds.height - 8))
        setFrameOrigin(NSPoint(x: nx, y: ny))
        if let canvas = superview as? AgentCanvasView {
            canvas.layoutDockedAddButtons()
            canvas.needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            // Short click without movement → Open terminal
            if let dragStart, let originStart {
                let p = event.locationInWindow
                let moved = hypot(p.x - dragStart.x, p.y - dragStart.y)
                if moved < 4 {
                    onFront?(model)
                } else {
                    onMoved?(model, frame.origin)
                }
                _ = originStart
            } else {
                onMoved?(model, frame.origin)
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
        if model.role == "conductor" {
            menu.addItem(withTitle: "Focus team activity", action: #selector(focusTap), keyEquivalent: "")
            menu.addItem(withTitle: "Add worker…", action: #selector(addFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Team options", action: #selector(optsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Kill team", action: #selector(killTap), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Add subagent…", action: #selector(addFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Permissions", action: #selector(permsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Remove worker", action: #selector(killTap), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func killTap() { onKill?(model) }
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

    var onFront: ((AgentNodeModel) -> Void)?
    var onKill: ((AgentNodeModel) -> Void)?
    var onOptions: ((AgentNodeModel) -> Void)?
    var onPerms: ((AgentNodeModel) -> Void)?
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bg.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

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
        let dx = p.x - panStart.x
        let dy = p.y - panStart.y
        // Drag background: content moves with cursor (natural pan)
        var origin = scrollOriginStart
        origin.x -= dx
        origin.y -= dy
        // Clamp to document
        let doc = bounds.size
        let vis = scroll.contentView.bounds.size
        let maxX = max(0, doc.width - vis.width)
        let maxY = max(0, doc.height - vis.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        PongTheme.bg.setFill()
        bounds.fill()
        let step: CGFloat = 22
        NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            var y: CGFloat = 0
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                y += step
            }
            x += step
        }
        // Edges per team: orchestrator → workers (labeled). No line to "+".
        // Workers chained vertically with peer-flow labels when 2+.
        let sessions = Set(models.map(\.session))
        for sess in sessions {
            guard let c = models.first(where: { $0.session == sess && $0.role == "conductor" }),
                  let cv = nodeViews[c.globalId] else { continue }
            let from = NSPoint(x: cv.frame.maxX - 2, y: cv.frame.midY)
            let workers = models.filter { $0.session == sess && $0.role == "worker" }
                .sorted { $0.origin.y > $1.origin.y } // top-to-bottom in view coords (y up)
                .sorted { a, b in
                    // stable visual order by y descending (higher y first)
                    a.origin.y > b.origin.y
                }

            for m in workers {
                guard let wv = nodeViews[m.globalId] else { continue }
                let to = NSPoint(x: wv.frame.minX + 2, y: wv.frame.midY)
                let label: String = {
                    let st = m.status.lowercased()
                    if st.contains("human") { return "needs you" }
                    if st.contains("busy") || st.contains("running") { return "assign · build" }
                    return "delegate"
                }()
                drawEdge(from: from, to: to,
                         human: m.status.lowercased().contains("human"),
                         style: .orchToWorker,
                         label: label)
            }

            // Peer flow between workers (not for single worker)
            if workers.count >= 2 {
                for i in 0..<(workers.count - 1) {
                    guard let a = nodeViews[workers[i].globalId],
                          let b = nodeViews[workers[i + 1].globalId] else { continue }
                    let p0 = NSPoint(x: a.frame.midX, y: a.frame.minY)
                    let p1 = NSPoint(x: b.frame.midX, y: b.frame.maxY)
                    drawEdge(from: p0, to: p1, human: false, style: .workerPeer, label: "peer · handoff")
                }
            }
            // Intentionally no edge to the small "+" node
        }
    }

    private enum EdgeStyle { case orchToWorker, workerPeer }

    private func drawEdge(from: NSPoint, to: NSPoint, human: Bool, style: EdgeStyle, label: String) {
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
            c1 = NSPoint(x: from.x, y: midY)
            c2 = NSPoint(x: to.x, y: midY)
        }
        path.curve(to: to, controlPoint1: c1, controlPoint2: c2)

        let color: NSColor = {
            if human { return PongTheme.orange }
            switch style {
            case .orchToWorker: return PongTheme.blue
            case .workerPeer: return PongTheme.magenta
            }
        }()

        path.lineWidth = style == .workerPeer ? 3.5 : 5
        color.withAlphaComponent(0.16).setStroke()
        path.stroke()
        path.lineWidth = style == .workerPeer ? 1.25 : 1.75
        if style == .workerPeer {
            // dashed peer links
            let dashes: [CGFloat] = [5, 4]
            path.setLineDash(dashes, count: 2, phase: 0)
        }
        color.withAlphaComponent(0.85).setStroke()
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)

        // Direction arrow at destination (flow: from → to)
        drawArrowHead(at: to, from: from, color: color)

        let r: CGFloat = 2.5
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()

        // Flow caption at curve mid
        guard !label.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: PongTheme.font(9, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.95),
            .backgroundColor: PongTheme.bg.withAlphaComponent(0.82),
        ]
        let s = NSAttributedString(string: " \(label) ", attributes: attrs)
        let sz = s.size()
        let labelOrigin = NSPoint(x: midX - sz.width / 2, y: midY - sz.height / 2)
        // pill behind text
        let pill = NSBezierPath(roundedRect: NSRect(x: labelOrigin.x - 2, y: labelOrigin.y - 1,
                                                    width: sz.width + 4, height: sz.height + 2),
                                xRadius: 4, yRadius: 4)
        PongTheme.bg.withAlphaComponent(0.88).setFill()
        pill.fill()
        color.withAlphaComponent(0.25).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        s.draw(at: labelOrigin)
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
        self.models = models
        let keep = Set(models.map(\.globalId))
        for (id, v) in nodeViews where !keep.contains(id) {
            v.removeFromSuperview()
            nodeViews[id] = nil
        }
        for m in models {
            if let existing = nodeViews[m.globalId] {
                existing.apply(m)
            } else {
                let v = AgentNodeView(model: m)
                wire(v)
                addSubview(v)
                nodeViews[m.globalId] = v
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
        v.onFocus = { [weak self] m in self?.onFocus?(m) }
        v.onAddWorker = { [weak self] m in self?.onAddWorker?(m) }
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
        // Don't persist free positions for docked + chips
        if m.role == "add" || m.role == "add-sub" { return }
        var pos = CanvasLayout.positions(for: multiTeam ? nil : m.session)
        let key = CanvasLayout.key(session: m.session, nodeId: m.id, multi: multiTeam)
        pos[key] = origin
        if !multiTeam { pos[m.id] = origin }
        CanvasLayout.save(session: multiTeam ? nil : m.session, positions: pos, multi: multiTeam)
        if let i = models.firstIndex(where: { $0.globalId == m.globalId }) {
            models[i].origin = origin
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutDockedAddButtons()
        needsDisplay = true
    }
}

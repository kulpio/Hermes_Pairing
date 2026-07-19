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

    static let size = NSSize(width: 256, height: 148)
    static let addSize = NSSize(width: 56, height: 56)

    override var mouseDownCanMoveWindow: Bool { false }

    init(model: AgentNodeModel) {
        self.model = model
        let sz = model.role == "add" ? Self.addSize : Self.size
        super.init(frame: NSRect(origin: model.origin, size: sz))
        wantsLayer = true
        layer?.cornerRadius = model.role == "add" ? 28 : 16
        layer?.borderWidth = 1
        layer?.masksToBounds = false

        if model.role == "add" {
            buildAddStyle()
        } else {
            buildCardStyle()
        }
        apply(model)
        toolTip = model.role == "add"
            ? "Add worker to this orchestrator"
            : "Drag to move · click Open for terminal · Focus for team activity"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildAddStyle() {
        layer?.backgroundColor = PongTheme.magentaSoft.cgColor
        layer?.borderColor = PongTheme.magenta.withAlphaComponent(0.5).cgColor
        layer?.shadowColor = PongTheme.magenta.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 16
        layer?.shadowOffset = .zero
        let plus = NSTextField(labelWithString: "+")
        plus.font = PongTheme.font(28, weight: .medium)
        plus.textColor = PongTheme.magenta
        plus.alignment = .center
        plus.frame = NSRect(x: 0, y: 10, width: 56, height: 36)
        plus.isEditable = false
        plus.isBordered = false
        plus.backgroundColor = .clear
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

        detailField.font = PongTheme.font(10)
        detailField.textColor = PongTheme.textTertiary
        detailField.frame = NSRect(x: 14, y: 44, width: Self.size.width - 28, height: 28)
        detailField.maximumNumberOfLines = 2
        labelStyle(detailField)
        addSubview(detailField)

        // Actions row
        var x: CGFloat = 12
        func addBtn(_ t: String, _ sel: Selector, filled: Bool, w: CGFloat = 56) {
            let b = makeBtn(t, sel, filled: filled, frame: NSRect(x: x, y: 10, width: w, height: 26))
            addSubview(b)
            buttons.append(b)
            x += w + 6
        }
        addBtn("Open", #selector(frontTap), filled: true, w: 52)
        if model.role == "conductor" {
            addBtn("Focus", #selector(focusTap), filled: false, w: 52)
            addBtn("Opts", #selector(optsTap), filled: false, w: 44)
        } else {
            addBtn("Perms", #selector(permsTap), filled: false, w: 52)
        }
    }

    private func labelStyle(_ f: NSTextField) {
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        f.backgroundColor = .clear
    }

    private func makeBtn(_ title: String, _ sel: Selector, filled: Bool, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        if filled {
            b.layer?.backgroundColor = PongTheme.blue.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white, .font: PongTheme.font(10, weight: .semibold),
            ])
        } else {
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.border.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textSecondary, .font: PongTheme.font(10, weight: .medium),
            ])
        }
        b.target = self
        b.action = sel
        return b
    }

    func apply(_ m: AgentNodeModel) {
        if !dragging, frame.origin != m.origin { setFrameOrigin(m.origin) }
        if m.role == "add" { return }

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
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for b in buttons where b.frame.contains(local) { return b }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if model.role == "add" {
            onAddWorker?(model)
            return
        }
        if event.clickCount >= 2 {
            onFront?(model)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if buttons.contains(where: { $0.frame.contains(local) }) { return }
        dragStart = event.locationInWindow
        originStart = frame.origin
        dragging = true
        onDragBegan?()
        superview?.addSubview(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        var nx = originStart.x + (p.x - dragStart.x)
        var ny = originStart.y + (p.y - dragStart.y)
        nx = min(max(8, nx), max(8, superV.bounds.width - bounds.width - 8))
        ny = min(max(8, ny), max(8, superV.bounds.height - bounds.height - 8))
        setFrameOrigin(NSPoint(x: nx, y: ny))
        (superview as? AgentCanvasView)?.needsDisplay = true
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
            menu.addItem(withTitle: "Permissions", action: #selector(permsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Remove worker", action: #selector(killTap), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func killTap() { onKill?(model) }
    @objc private func addFromMenu() { onAddWorker?(model) }
}

// MARK: - Canvas

final class AgentCanvasView: NSView {
    private(set) var isDragging = false
    private var multiTeam = false
    private var models: [AgentNodeModel] = []
    private var nodeViews: [String: AgentNodeView] = [:]

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
        // Edges per team: conductor → workers; conductor → add handle
        let sessions = Set(models.map(\.session))
        for sess in sessions {
            guard let c = models.first(where: { $0.session == sess && $0.role == "conductor" }),
                  let cv = nodeViews[c.globalId] else { continue }
            let from = NSPoint(x: cv.frame.maxX - 2, y: cv.frame.midY)
            for m in models where m.session == sess && m.role == "worker" {
                guard let wv = nodeViews[m.globalId] else { continue }
                let to = NSPoint(x: wv.frame.minX + 2, y: wv.frame.midY)
                drawEdge(from: from, to: to, human: m.status.lowercased().contains("human"), worker: true)
            }
            if let add = models.first(where: { $0.session == sess && $0.role == "add" }),
               let av = nodeViews[add.globalId] {
                let to = NSPoint(x: av.frame.midX, y: av.frame.midY)
                drawEdge(from: from, to: to, human: false, worker: false)
            }
        }
    }

    private func drawEdge(from: NSPoint, to: NSPoint, human: Bool, worker: Bool) {
        let path = NSBezierPath()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        path.curve(to: to, controlPoint1: NSPoint(x: midX, y: from.y), controlPoint2: NSPoint(x: midX, y: to.y))
        let color: NSColor = human ? PongTheme.orange : (worker ? PongTheme.magenta : PongTheme.blue)
        path.lineWidth = 5
        color.withAlphaComponent(0.18).setStroke()
        path.stroke()
        path.lineWidth = 1.75
        color.withAlphaComponent(0.8).setStroke()
        path.stroke()
        let r: CGFloat = 3.5
        PongTheme.blue.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)).fill()
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
                // update model reference via re-init is hard; origin already applied
            } else {
                let v = AgentNodeView(model: m)
                wire(v)
                addSubview(v)
                nodeViews[m.globalId] = v
            }
        }
        needsDisplay = true
    }

    private func wire(_ v: AgentNodeView) {
        v.onMoved = { [weak self] m, origin in self?.persist(m, origin: origin) }
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
        }
    }

    private func persist(_ m: AgentNodeModel, origin: CGPoint) {
        var pos = CanvasLayout.positions(for: multiTeam ? nil : m.session)
        let key = CanvasLayout.key(session: m.session, nodeId: m.id, multi: multiTeam)
        pos[key] = origin
        // also bare id for single-team compat
        if !multiTeam { pos[m.id] = origin }
        CanvasLayout.save(session: multiTeam ? nil : m.session, positions: pos, multi: multiTeam)
        if let i = models.firstIndex(where: { $0.globalId == m.globalId }) {
            models[i].origin = origin
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

import AppKit

// MARK: - Canvas positions (persisted on pair)

enum CanvasLayout {
    static func positions(for session: String) -> [String: CGPoint] {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let raw = entry["canvas_positions"] as? [String: [String: Any]] ?? [:]
        var out: [String: CGPoint] = [:]
        for (k, v) in raw {
            let x = (v["x"] as? CGFloat) ?? CGFloat((v["x"] as? Double) ?? 0)
            let y = (v["y"] as? CGFloat) ?? CGFloat((v["y"] as? Double) ?? 0)
            out[k] = CGPoint(x: x, y: y)
        }
        return out
    }

    static func save(session: String, positions: [String: CGPoint]) {
        var db = PairState.loadPairsDb()
        var entry = db[session] as? [String: Any] ?? [:]
        var raw: [String: [String: Any]] = [:]
        for (k, p) in positions {
            raw[k] = ["x": Double(p.x), "y": Double(p.y)]
        }
        entry["canvas_positions"] = raw
        entry["updated"] = Date().timeIntervalSince1970
        db[session] = entry
        Pong.writeJSON(PairState.pairsPath, db)
    }

    static func defaultPosition(role: String, index: Int, canvas: CGSize) -> CGPoint {
        if role == "conductor" {
            return CGPoint(x: max(48, canvas.width * 0.18), y: max(80, canvas.height * 0.42))
        }
        let col = index % 2
        let row = index / 2
        let baseX = max(320, canvas.width * 0.48) + CGFloat(col) * 40
        let baseY = max(60, canvas.height * 0.22) + CGFloat(row) * 150
        return CGPoint(x: min(canvas.width - 280, baseX), y: baseY)
    }
}

// MARK: - Node model

struct AgentNodeModel {
    let id: String
    let role: String // conductor | worker
    let title: String
    let subtitle: String
    let detail: String
    let status: String
    let accent: NSColor
    var origin: CGPoint
}

// MARK: - Polished agent card (orchestration dashboard style)

final class AgentNodeView: NSView {
    let modelId: String
    var onMoved: ((String, CGPoint) -> Void)?
    var onFront: ((String) -> Void)?
    var onKill: ((String) -> Void)?
    var onOptions: ((String) -> Void)?
    var onPerms: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?

    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private let iconBadge = NSView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var primaryBtn: NSButton!
    private var secondaryBtn: NSButton!
    private var isConductor = false

    static let size = NSSize(width: 248, height: 132)

    init(model: AgentNodeModel) {
        self.modelId = model.id
        super.init(frame: NSRect(origin: model.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        isConductor = model.role == "conductor"
        applyChrome(model)

        // Icon tile
        iconBadge.frame = NSRect(x: 14, y: Self.size.height - 48, width: 32, height: 32)
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 10
        iconBadge.layer?.backgroundColor = PongTheme.accentSoft.cgColor
        addSubview(iconBadge)
        iconLabel.font = PongTheme.font(14, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 6, width: 32, height: 20)
        iconLabel.isEditable = false
        iconLabel.isBordered = false
        iconLabel.backgroundColor = .clear
        iconLabel.textColor = PongTheme.accent
        iconBadge.addSubview(iconLabel)

        // Status pill (top-right)
        statusPill.frame = NSRect(x: Self.size.width - 88, y: Self.size.height - 34, width: 74, height: 22)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 6
        addSubview(statusPill)
        statusLabel.font = PongTheme.font(9, weight: .bold)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 0, y: 3, width: 74, height: 16)
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear
        statusPill.addSubview(statusLabel)

        titleField.font = PongTheme.font(13, weight: .semibold)
        titleField.textColor = PongTheme.textPrimary
        titleField.frame = NSRect(x: 54, y: Self.size.height - 44, width: 100, height: 18)
        titleField.lineBreakMode = .byTruncatingTail
        configureLabel(titleField)
        addSubview(titleField)

        subField.font = PongTheme.font(10)
        subField.textColor = PongTheme.textSecondary
        subField.frame = NSRect(x: 54, y: Self.size.height - 60, width: 100, height: 14)
        subField.lineBreakMode = .byTruncatingTail
        configureLabel(subField)
        addSubview(subField)

        detailField.font = PongTheme.font(10)
        detailField.textColor = PongTheme.textTertiary
        detailField.frame = NSRect(x: 14, y: 40, width: Self.size.width - 28, height: 28)
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byWordWrapping
        configureLabel(detailField)
        addSubview(detailField)

        primaryBtn = makeAction("Open", #selector(frontTap), filled: true,
                                frame: NSRect(x: 14, y: 10, width: 72, height: 26))
        addSubview(primaryBtn)
        secondaryBtn = makeAction(isConductor ? "Options" : "Perms",
                                  isConductor ? #selector(optsTap) : #selector(permsTap),
                                  filled: false,
                                  frame: NSRect(x: 92, y: 10, width: 72, height: 26))
        addSubview(secondaryBtn)

        apply(model)
        toolTip = "Drag to rearrange · double-click to Open · right-click for more"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureLabel(_ f: NSTextField) {
        f.isEditable = false
        f.isBordered = false
        f.backgroundColor = .clear
        f.drawsBackground = false
    }

    private func makeAction(_ title: String, _ sel: Selector, filled: Bool, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        if filled {
            b.layer?.backgroundColor = PongTheme.accent.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.accentInk,
                .font: PongTheme.font(10, weight: .semibold),
            ])
        } else {
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.border.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textSecondary,
                .font: PongTheme.font(10, weight: .medium),
            ])
        }
        b.target = self
        b.action = sel
        return b
    }

    private func applyChrome(_ model: AgentNodeModel) {
        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        if model.role == "conductor" {
            layer?.borderColor = PongTheme.borderAccent.cgColor
            layer?.shadowColor = PongTheme.accent.cgColor
            layer?.shadowOpacity = 0.25
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: 0)
        } else {
            layer?.borderColor = PongTheme.border.cgColor
            layer?.shadowOpacity = 0
        }
    }

    func apply(_ model: AgentNodeModel) {
        applyChrome(model)
        titleField.stringValue = model.title
        subField.stringValue = model.subtitle
        detailField.stringValue = model.detail
        iconLabel.stringValue = model.role == "conductor" ? "◎" : "◇"
        let sk = PongTheme.statusKind(model.status)
        statusLabel.stringValue = sk.label
        statusLabel.textColor = sk.color
        statusPill.layer?.backgroundColor = sk.soft.cgColor
        if frame.origin != model.origin {
            setFrameOrigin(model.origin)
        }
    }

    @objc private func frontTap() { onFront?(modelId) }
    @objc private func optsTap() { onOptions?(modelId) }
    @objc private func permsTap() { onPerms?(modelId) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(modelId)
            return
        }
        // Don't start drag if clicking a button
        let local = convert(event.locationInWindow, from: nil)
        if primaryBtn.frame.contains(local) || secondaryBtn.frame.contains(local) {
            return
        }
        dragStart = event.locationInWindow
        originStart = frame.origin
        superview?.addSubview(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        var nx = originStart.x + (p.x - dragStart.x)
        var ny = originStart.y + (p.y - dragStart.y)
        nx = min(max(12, nx), max(12, superV.bounds.width - bounds.width - 12))
        ny = min(max(12, ny), max(12, superV.bounds.height - bounds.height - 12))
        setFrameOrigin(NSPoint(x: nx, y: ny))
        (superview as? AgentCanvasView)?.setNeedsDisplay(superV.bounds)
    }

    override func mouseUp(with event: NSEvent) {
        onMoved?(modelId, frame.origin)
        dragStart = nil
        originStart = nil
        (superview as? AgentCanvasView)?.setNeedsDisplay(superview?.bounds ?? bounds)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open terminal", action: #selector(frontTap), keyEquivalent: "")
        if isConductor {
            menu.addItem(withTitle: "Team options", action: #selector(optsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Kill team", action: #selector(killTap), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Permissions", action: #selector(permsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Remove worker", action: #selector(killTap), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func killTap() { onKill?(modelId) }
}

// MARK: - Canvas

final class AgentCanvasView: NSView {
    var session: String = ""
    var nodes: [AgentNodeModel] = []
    private var nodeViews: [String: AgentNodeView] = [:]
    var onFront: ((String, String) -> Void)?
    var onKill: ((String, String) -> Void)?
    var onOptions: ((String) -> Void)?
    var onPerms: ((String, String) -> Void)?
    var onLayoutChanged: (() -> Void)?

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

        // Fine dot grid
        let step: CGFloat = 22
        NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            var y: CGFloat = 0
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.6, height: 1.6)).fill()
                y += step
            }
            x += step
        }

        // Edges under nodes
        guard let cNode = nodes.first(where: { $0.role == "conductor" }),
              let cView = nodeViews[cNode.id] else { return }
        let from = NSPoint(x: cView.frame.maxX - 4, y: cView.frame.midY)
        for n in nodes where n.role == "worker" {
            guard let wv = nodeViews[n.id] else { continue }
            let to = NSPoint(x: wv.frame.minX + 4, y: wv.frame.midY)
            drawEdge(from: from, to: to)
        }
    }

    private func drawEdge(from: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        path.curve(to: to,
                   controlPoint1: NSPoint(x: midX, y: from.y),
                   controlPoint2: NSPoint(x: midX, y: to.y))
        // Soft glow
        path.lineWidth = 4
        PongTheme.accentGlow.setStroke()
        path.stroke()
        path.lineWidth = 1.5
        PongTheme.accent.withAlphaComponent(0.55).setStroke()
        path.stroke()

        // Endpoint dots
        let r: CGFloat = 3.5
        PongTheme.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)).fill()
    }

    func reload(session: String, models: [AgentNodeModel]) {
        self.session = session
        self.nodes = models
        let keep = Set(models.map(\.id))
        for (id, v) in nodeViews where !keep.contains(id) {
            v.removeFromSuperview()
            nodeViews[id] = nil
        }
        for m in models {
            if let existing = nodeViews[m.id] {
                existing.apply(m)
            } else {
                let v = AgentNodeView(model: m)
                v.onMoved = { [weak self] id, origin in self?.persistPosition(id: id, origin: origin) }
                v.onFront = { [weak self] id in guard let self else { return }; self.onFront?(self.session, id) }
                v.onKill = { [weak self] id in guard let self else { return }; self.onKill?(self.session, id) }
                v.onOptions = { [weak self] _ in guard let self else { return }; self.onOptions?(self.session) }
                v.onPerms = { [weak self] id in guard let self else { return }; self.onPerms?(self.session, id) }
                v.onDoubleClick = { [weak self] id in guard let self else { return }; self.onFront?(self.session, id) }
                addSubview(v)
                nodeViews[m.id] = v
            }
        }
        needsDisplay = true
    }

    private func persistPosition(id: String, origin: CGPoint) {
        var pos = CanvasLayout.positions(for: session)
        pos[id] = origin
        if let i = nodes.firstIndex(where: { $0.id == id }) {
            nodes[i].origin = origin
        }
        CanvasLayout.save(session: session, positions: pos)
        needsDisplay = true
        onLayoutChanged?()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

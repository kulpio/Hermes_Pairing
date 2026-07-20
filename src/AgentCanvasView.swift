import AppKit

// MARK: - Positions (keyed "session::nodeId" for multi-team, or bare id for single)

enum CanvasLayout {
    /// Uniform design-grid step (matches canvas dots).
    static let gridStep: CGFloat = 20

    static func key(session: String, nodeId: String, multi: Bool) -> String {
        multi ? "\(session)::\(nodeId)" : nodeId
    }

    /// Snap origin to the dotted grid (top-left of module).
    static func snap(_ p: CGPoint) -> CGPoint {
        let s = gridStep
        let x = (p.x / s).rounded() * s
        let y = (p.y / s).rounded() * s
        return CGPoint(x: max(s, x), y: max(s, y))
    }

    static func positions(for session: String?) -> [String: CGPoint] {
        // Merge pair-local + all-teams maps so single/multi views don't lose seats
        var out = loadMap(from: Pong.loadJSON(Pong.stateDir + "/canvas-all.json"))
        if let session {
            let local = loadMap(from: PairState.loadPairsDb()[session] as? [String: Any] ?? [:])
            for (k, v) in local { out[k] = v }
        }
        return out
    }

    /// Resolve a seat position from map (session-scoped key, then bare id).
    static func origin(session: String, nodeId: String, multi: Bool, map: [String: CGPoint],
                       teamIndex: Int, role: String, workerIndex: Int, canvas: CGSize) -> CGPoint {
        let sk = "\(session)::\(nodeId)"
        if let p = map[sk] { return snap(p) }
        if let p = map[nodeId] { return snap(p) }
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

    /// Persist one seat: write both bare + session::id keys into pair file and canvas-all.
    static func saveSeat(session: String, nodeId: String, origin: CGPoint) {
        let snapped = snap(origin)
        let bare = nodeId
        let scoped = "\(session)::\(nodeId)"

        func merge(_ entry: [String: Any]) -> [String: Any] {
            var e = entry
            var raw = e["canvas_positions"] as? [String: [String: Any]] ?? [:]
            raw[bare] = ["x": Double(snapped.x), "y": Double(snapped.y)]
            raw[scoped] = ["x": Double(snapped.x), "y": Double(snapped.y)]
            e["canvas_positions"] = raw
            e["updated"] = Date().timeIntervalSince1970
            return e
        }

        var db = PairState.loadPairsDb()
        var entry = db[session] as? [String: Any] ?? [:]
        entry = merge(entry)
        db[session] = entry
        Pong.writeJSON(PairState.pairsPath, db)

        var all = Pong.loadJSON(Pong.stateDir + "/canvas-all.json")
        all = merge(all)
        Pong.writeJSON(Pong.stateDir + "/canvas-all.json", all)
    }

    static func save(session: String?, positions: [String: CGPoint], multi: Bool) {
        var raw: [String: [String: Any]] = [:]
        for (k, p) in positions {
            let s = snap(p)
            raw[k] = ["x": Double(s.x), "y": Double(s.y)]
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

    /// Cluster layout: each team gets a horizontal band (grid-aligned).
    static func defaultPosition(teamIndex: Int, role: String, workerIndex: Int, canvas: CGSize, multi: Bool) -> CGPoint {
        let clusterX = multi ? 40 + CGFloat(teamIndex) * 520 : max(48, canvas.width * 0.14)
        let clusterY = multi ? max(80, canvas.height * 0.35) : max(100, canvas.height * 0.42)
        if role == "conductor" {
            return snap(CGPoint(x: clusterX, y: clusterY))
        }
        return snap(CGPoint(x: clusterX + 300, y: max(50, clusterY - 40) + CGFloat(workerIndex) * 160))
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
    private(set) var model: AgentNodeModel
    var onMoved: ((AgentNodeModel, CGPoint) -> Void)?
    var onFront: ((AgentNodeModel) -> Void)?
    var onKill: ((AgentNodeModel) -> Void)?
    var onOptions: ((AgentNodeModel) -> Void)?
    var onPerms: ((AgentNodeModel) -> Void)?
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onRename: ((AgentNodeModel) -> Void)?
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
    private var buttons: [NSButton] = []
    private let actionBar = NSView()
    /// Job highlight (Mission/job → canvas link)
    var isJobHighlighted: Bool = false {
        didSet { needsDisplay = true; apply(model) }
    }

    /// Lattice-style floating module — cleaner, taller type, less chrome
    static let size = NSSize(width: 280, height: 152)
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
            : "Drag to move · Open for terminal · Edit to rename"
    }

    required init?(coder: NSCoder) { fatalError() }

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

        teamField.font = PongTheme.labelFont(9)
        teamField.textColor = PongTheme.textTertiary
        teamField.frame = NSRect(x: 90, y: Self.size.height - 20, width: 100, height: 12)
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
        // Leave room for Edit next to name
        titleField.frame = NSRect(x: 46, y: Self.size.height - 50, width: Self.size.width - 175, height: 20)
        titleField.lineBreakMode = .byTruncatingTail
        labelStyle(titleField)
        addSubview(titleField)

        let editBtn = makeBtn("Edit", #selector(renameTap), style: .secondary,
                              frame: NSRect(x: Self.size.width - 120, y: Self.size.height - 50, width: 44, height: 20))
        editBtn.toolTip = "Rename this seat"
        editBtn.identifier = NSUserInterfaceItemIdentifier("editName")
        addSubview(editBtn)
        buttons.append(editBtn)

        subField.font = PongTheme.font(11)
        subField.textColor = PongTheme.textSecondary
        subField.frame = NSRect(x: 46, y: Self.size.height - 68, width: Self.size.width - 60, height: 14)
        subField.lineBreakMode = .byTruncatingTail
        labelStyle(subField)
        addSubview(subField)

        detailField.font = PongTheme.font(11)
        detailField.textColor = PongTheme.textTertiary
        detailField.frame = NSRect(x: 14, y: 42, width: Self.size.width - 28, height: 28)
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byWordWrapping
        detailField.cell?.truncatesLastVisibleLine = true
        detailField.usesSingleLineMode = false
        labelStyle(detailField)
        addSubview(detailField)

        actionBar.frame = NSRect(x: 10, y: 8, width: Self.size.width - 20, height: 30)
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(actionBar)

        let barW = Self.size.width - 20
        let kill = makeBtn("Kill", #selector(killTap), style: .danger,
                           frame: NSRect(x: barW - 48, y: 4, width: 48, height: 22))
        actionBar.addSubview(kill)
        buttons.append(kill)

        var x: CGFloat = 0
        func addLeft(_ t: String, _ sel: Selector, style: BtnStyle, w: CGFloat) {
            let b = makeBtn(t, sel, style: style, frame: NSRect(x: x, y: 4, width: w, height: 22))
            actionBar.addSubview(b)
            buttons.append(b)
            x += w + 6
        }
        addLeft("Open", #selector(frontTap), style: .primary, w: 56)
        if model.role == "conductor" {
            // Task recap lives in the map’s TASKS panel under YOU (not a Focus popup).
            addLeft("Opts", #selector(optsTap), style: .secondary, w: 48)
        } else {
            addLeft("Policy", #selector(permsTap), style: .secondary, w: 54)
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
        // Primary uses role color: blue conductor · magenta worker
        let roleColor = model.role == "conductor" ? PongTheme.blue : PongTheme.magenta
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
        // Role color only: blue orchestrator · magenta agents
        let role: NSColor = isCond ? PongTheme.blue : PongTheme.magenta

        accentRail.layer?.backgroundColor = role.cgColor

        titleField.stringValue = m.title
        subField.stringValue = m.subtitle
        detailField.stringValue = m.detail
        teamField.stringValue = m.teamLabel
        idField.stringValue = m.id.uppercased()
        iconLabel.stringValue = isCond ? "◎" : "{}"
        iconLabel.textColor = role
        iconBadge.layer?.backgroundColor = (isCond ? PongTheme.blueSoft : PongTheme.magentaSoft).cgColor
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
        needsDisplay = true
    }

    @objc private func frontTap() {
        Pong.log("module Open tapped id=\(model.id) role=\(model.role) session=\(model.session)")
        onFront?(model)
    }
    @objc private func optsTap() { onOptions?(model) }
    @objc private func permsTap() { onPerms?(model) }
    @objc private func focusTap() { onFocus?(model) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in the receiver's superview coordinates
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Prefer action-bar buttons so Open/Opts receive the click (not drag)
        if actionBar.frame.contains(local) {
            let inBar = actionBar.convert(local, from: self)
            for b in buttons where b.frame.contains(inBar) {
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
        // Buttons (Open / Edit…) — if hitTest missed them, fire Open manually when
        // the primary left segment is clicked (module card over SceneKit is finicky).
        if actionBar.frame.contains(local) {
            let inBar = actionBar.convert(local, from: self)
            for b in buttons where b.frame.contains(inBar) {
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
        if let edit = subviews.first(where: { $0.identifier?.rawValue == "editName" }),
           edit.frame.contains(local) { return }
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
        // Keep action bar above siblings after re-add
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
        nx = min(max(8, nx), max(8, superV.bounds.width - bounds.width - 8))
        ny = min(max(8, ny), max(8, superV.bounds.height - bounds.height - 8))
        // Live snap while dragging so modules stick to the dotted field
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
    var onFocus: ((AgentNodeModel) -> Void)?
    var onAddWorker: ((AgentNodeModel) -> Void)?
    var onRename: ((AgentNodeModel) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onSelectionChanged: ((AgentNodeModel?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bg.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

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
        // Map void — pure black (Lattice aerial stage)
        PongTheme.bg.setFill()
        bounds.fill()

        // Uniform dotted grid (design-tool style: even spacing, equal dots)
        let step = CanvasLayout.gridStep
        let r: CGFloat = PongTheme.appearance == .dark ? 0.9 : 0.75
        let a: CGFloat = PongTheme.appearance == .dark ? 0.18 : 0.14
        PongTheme.ink.withAlphaComponent(a).setFill()
        var x: CGFloat = step
        while x < bounds.width {
            var y: CGFloat = step
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
                y += step
            }
            x += step
        }

        // Edges per team: conductor → workers (labeled). No line to "+".
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
            // Connect right-side midpoints so arrows sit on the visible link
            if workers.count >= 2 {
                for i in 0..<(workers.count - 1) {
                    guard let a = nodeViews[workers[i].globalId],
                          let b = nodeViews[workers[i + 1].globalId] else { continue }
                    // Slight inset from right edge so arrow tracks the curve
                    let p0 = NSPoint(x: a.frame.maxX - 18, y: a.frame.minY + 4)
                    let p1 = NSPoint(x: b.frame.maxX - 18, y: b.frame.maxY - 4)
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
        let c1: NSPoint
        let c2: NSPoint
        switch style {
        case .orchToWorker:
            c1 = NSPoint(x: midX, y: from.y)
            c2 = NSPoint(x: midX, y: to.y)
        case .workerPeer:
            // Vertical-ish S curve hugging the right side of cards
            c1 = NSPoint(x: from.x + 12, y: from.y - abs(from.y - to.y) * 0.25)
            c2 = NSPoint(x: to.x + 12, y: to.y + abs(from.y - to.y) * 0.25)
        }
        path.curve(to: to, controlPoint1: c1, controlPoint2: c2)

        // Graph edges = white line work. Role color only on seats, not edges —
        // except human path uses amber.
        let color: NSColor = human
            ? PongTheme.amber
            : (style == .workerPeer ? PongTheme.lineSoft : PongTheme.line)

        // Soft white underglow then crisp stroke
        path.lineWidth = style == .workerPeer ? 2.5 : 3.5
        color.withAlphaComponent(0.2).setStroke()
        path.stroke()
        path.lineWidth = style == .workerPeer ? 1.15 : 1.4
        if style == .workerPeer {
            let dashes: [CGFloat] = [4, 4]
            path.setLineDash(dashes, count: 2, phase: 0)
        }
        color.setStroke()
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)

        drawArrowHead(at: to, from: c2, color: color)

        let r: CGFloat = 2.5
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()

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
        PongTheme.lineSoft.setStroke()
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
        v.onFocus = { [weak self] m in self?.onFocus?(m) }
        v.onAddWorker = { [weak self] m in self?.onAddWorker?(m) }
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
        // Live write: both bare + scoped keys, pair file + canvas-all
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

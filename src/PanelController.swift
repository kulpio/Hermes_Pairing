import AppKit

/// Canvas host that prefers the left HUD splitter strip over full-bleed SceneKit/map.
/// Without this, map3D (fills the page) can win hit-testing after layout reorders.
private final class CanvasPageView: NSView {
    weak var map3D: Agent3DMapView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let split = map3D?.hitTestLeftHUDSplitter(in: self, point: point) {
            return split
        }
        return super.hitTest(point)
    }
}

/// Lasting control panel: top tabs + primary stage (Canvas · Mission · Setup).
/// Design: docs/UI-VISION.md — orchestration surface, not a list form.
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    // Window
    private var window: NSWindow?
    private var root: NSView!

    // Chrome
    private var topBar: NSView!
    private var brandLabel: NSTextField!
    private var brandLogo: NSImageView!
    private var teamPopup: NSPopUpButton!
    private var statusPill: NSView!
    private var statusDot: NSView!
    private var statusText: NSTextField!
    private var refreshBtn: NSButton!
    private var appearanceBtn: NSButton!
    /// Top nav tabs (Map / Mission / Setup) — reclaims former left-rail width.
    private var topTabCanvas: NSButton!
    private var topTabMission: NSButton!
    private var topTabSetup: NSButton!

    // Legacy rail (hidden; width 0 — kept so existing styleRail calls no-op safely)
    private var rail: NSView!
    private var railCanvas: NSButton!
    private var railMission: NSButton!
    private var railSetup: NSButton!

    // Stage
    private var stage: NSView!
    private var canvasPage: CanvasPageView!
    private var canvasScroll: NSScrollView!
    private var canvas: AgentCanvasView!
    private var map3D: Agent3DMapView!
    private var canvasToolbar: NSView!
    private var canvasEmpty: NSView!
    private var missionPage: NSView!
    private var missionScroll: NSScrollView!
    private var missionBody: NSView!
    private var setupPage: NSView!
    private var setupScroll: NSScrollView!
    private var setupBody: NSView!

    private var selected: Destination = .canvas
    private var selectedSession: String?
    private var lastSnapshot: [String: Any]?
    private var canvasDragging = false
    /// true = 3D constellation (default special view); false = flat map
    /// Prefer product default 3D so first open shows the promise of the map.
    private var use3DMap: Bool = AppAISettings.prefer3DMap
    private var poll: Timer?
    private let guide = LinkGuideController()
    /// Mission ask strip — last grounded reply survives paintMission rebuilds.
    private var missionAskLastReply: String = ""
    private var hardRefreshInFlight = false

    /// Left rail removed — map is full-bleed under the top bar.
    private let railW: CGFloat = 0
    /// Tall enough for wordmark + team popup + top tabs
    private let topH: CGFloat = 58
    private let titlebarLift: CGFloat = 30
    private let trafficInset: CGFloat = 76
    private let minSize = NSSize(width: 720, height: 520)
    private let defaultSize = NSSize(width: 960, height: 680)

    enum Destination: Int { case canvas = 0, mission = 1, setup = 2 }

    // MARK: Public

    func show() {
        if window == nil { build() }
        // Always land on canvas + 3D when opening the app (unless user saved 2D)
        selected = .canvas
        use3DMap = AppAISettings.prefer3DMap
        reload()
        applyMapMode()
        go(.canvas)
        startPoll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Promise view: constellation even before first team
        ensure3DVisible()
    }

    func refreshUI() { reload() }

    /// Force 3D map visible (empty-state preview seats if no team yet).
    func ensure3DVisible() {
        use3DMap = true
        AppAISettings.setPrefer3DMap(true)
        selected = .canvas
        go(.canvas)
        applyMapMode()
        refreshCanvas()
        if use3DMap {
            map3D?.resetCamera()
            map3D?.setMapPlaying(true)
        }
        DispatchQueue.main.async {
            AppAIChatBubble.shared.attachIfNeeded(to: self.canvasPage)
        }
    }

    @objc private func openAppAIGuide() {
        AppAIOnboarding.present()
    }

    /// Host for floating Guide bubble.
    func _mapHostForBubble() -> NSView? {
        canvasPage
    }

    static func label(_ text: String, frame: NSRect, bold: Bool = false,
                      size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? PongTheme.font(size, weight: .semibold) : PongTheme.font(size)
        f.textColor = secondary ? PongTheme.textSecondary : PongTheme.textPrimary
        f.frame = frame
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 8
        f.isBezeled = false
        f.drawsBackground = false
        f.backgroundColor = .clear
        return f
    }

    static func showPairPersistTip(_ name: String) {
        let flag = Pong.stateDir + "/dont-remind-pair-persist"
        guard !FileManager.default.fileExists(atPath: flag) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Team is live"
        a.informativeText = "“\(name)” stays connected until you kill it. Arrange agents on the canvas; open any terminal anytime."
        a.addButton(withTitle: "Got it")
        a.addButton(withTitle: "Don't remind me")
        if a.runModal() == .alertSecondButtonReturn {
            try? "1\n".write(toFile: flag, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Build

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = PongTheme.productName
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bg
        win.minSize = minSize
        win.isMovableByWindowBackground = true
        win.center()
        win.delegate = self

        root = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]

        buildTopBar()
        buildRail() // builds hidden zero-width shell for API compatibility
        rail.isHidden = true
        buildStage()
        root.addSubview(topBar)
        root.addSubview(stage)

        win.contentView = root
        window = win
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: PongTheme.appearanceDidChange, object: nil)
        applyChrome()
        layoutAll()
        go(.canvas)
    }

    @objc private func themeDidChange() {
        applyChrome()
        reload()
    }

    /// Anduril chrome: pure black bars, white type, hairline structure.
    private func applyChrome() {
        window?.backgroundColor = PongTheme.bg
        window?.appearance = NSAppearance(named: PongTheme.appearance == .dark ? .darkAqua : .aqua)
        root?.layer?.backgroundColor = PongTheme.bg.cgColor
        topBar?.layer?.backgroundColor = PongTheme.bgChrome.cgColor
        brandLabel?.textColor = PongTheme.textPrimary
        brandLabel?.font = PongTheme.font(13, weight: .semibold)
        brandLogo?.image = PongTheme.wordmarkImage(height: 38)
        brandLabel?.isHidden = true
        statusText?.textColor = PongTheme.textSecondary
        statusText?.font = PongTheme.labelFont(10)
        statusPill?.wantsLayer = true
        statusPill?.layer?.backgroundColor = NSColor.clear.cgColor
        statusPill?.layer?.cornerRadius = 12
        statusPill?.layer?.borderWidth = PongTheme.hairline
        statusPill?.layer?.borderColor = PongTheme.border.cgColor
        for v in topBar?.subviews ?? [] where v.identifier?.rawValue == "topline" {
            v.layer?.backgroundColor = PongTheme.border.cgColor
        }
        rail?.layer?.backgroundColor = PongTheme.bgChrome.cgColor
        for v in rail?.subviews ?? [] where v.identifier?.rawValue == "railedge" {
            v.layer?.backgroundColor = PongTheme.lineSoft.cgColor
        }
        for v in rail?.subviews ?? [] where v.identifier?.rawValue == "railglow" {
            v.isHidden = true
        }
        stage?.layer?.backgroundColor = PongTheme.bg.cgColor
        styleRail()
        styleTopTabs()
        if let teamPopup { PongTheme.stylePopUp(teamPopup) }
        styleAppearanceBtn()
        styleRefreshBtn()
        restyleCanvasToolbar()
        canvas?.retheme()
        map3D?.applyChromeTheme()
    }

    private func styleAppearanceBtn() {
        guard let appearanceBtn else { return }
        let isDark = PongTheme.appearance == .dark
        appearanceBtn.toolTip = isDark ? "Switch to light mode" : "Switch to dark mode"
        // Dark mode → show moon (click for light); light mode → sun
        appearanceBtn.attributedTitle = NSAttributedString(
            string: isDark ? "☾" : "☀",
            attributes: [
                .foregroundColor: PongTheme.textSecondary,
                .font: PongTheme.font(14, weight: .medium),
                .paragraphStyle: centered(),
            ])
        appearanceBtn.layer?.backgroundColor = NSColor.clear.cgColor
        appearanceBtn.layer?.borderWidth = PongTheme.hairline
        appearanceBtn.layer?.borderColor = PongTheme.border.cgColor
    }

    private func styleRefreshBtn() {
        guard let refreshBtn else { return }
        refreshBtn.layer?.backgroundColor = NSColor.clear.cgColor
        refreshBtn.layer?.borderWidth = PongTheme.hairline
        refreshBtn.layer?.borderColor = PongTheme.border.cgColor
        refreshBtn.attributedTitle = NSAttributedString(
            string: "↻",
            attributes: [
                .foregroundColor: PongTheme.textPrimary,
                .font: PongTheme.font(13, weight: .medium),
                .paragraphStyle: centered(),
            ])
    }

    private func restyleCanvasToolbar() {
        guard let canvasToolbar else { return }
        // Floating HUD like Lattice Tracking panel
        canvasToolbar.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        canvasToolbar.layer?.borderColor = PongTheme.border.cgColor
        canvasToolbar.layer?.cornerRadius = PongTheme.radiusCard
        for b in canvasToolbar.subviews.compactMap({ $0 as? NSButton }) {
            let title = b.attributedTitle.string
            let upper = title.uppercased()
            // Only the real New team CTA — never rewrite titles that merely contain "team".
            let isNewTeamCTA =
                b.action == #selector(newTeamPressed)
                || upper == "NEW TEAM"
            if isNewTeamCTA {
                // White line-work CTA (not role colors)
                b.layer?.backgroundColor = PongTheme.ink.cgColor
                b.layer?.borderWidth = 0
                b.attributedTitle = NSAttributedString(string: "New team", attributes: [
                    .foregroundColor: PongTheme.bg,
                    .font: PongTheme.labelFont(11),
                    .paragraphStyle: centered(),
                ])
            } else {
                b.layer?.backgroundColor = NSColor.clear.cgColor
                b.layer?.borderWidth = PongTheme.hairline
                b.layer?.borderColor = PongTheme.lineSoft.cgColor
                b.attributedTitle = NSAttributedString(string: title.capitalized == title ? title : title.lowercased().capitalized,
                    attributes: [
                    .foregroundColor: PongTheme.textPrimary,
                    .font: PongTheme.labelFont(11),
                    .paragraphStyle: centered(),
                ])
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutAll()
        if selected == .canvas { refreshCanvas(light: true) }
        if selected == .mission { paintMission() }
    }

    private func layoutAll() {
        guard let root else { return }
        let W = root.bounds.width
        let H = root.bounds.height

        // Top bar under traffic lights
        let topY = H - titlebarLift - topH
        topBar.frame = NSRect(x: 0, y: topY, width: W, height: topH)
        layoutTopBar(width: W)

        // Stage full-bleed under top bar (no left rail)
        let bodyH = topY
        stage.frame = NSRect(x: 0, y: 0, width: W, height: bodyH)
        for page in [canvasPage, missionPage, setupPage] {
            page?.frame = stage.bounds
        }
        layoutCanvasPage()
        layoutMissionPage()
        layoutSetupPage()
    }

    // MARK: Top bar

    private func buildTopBar() {
        topBar = NSView(frame: .zero)
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = PongTheme.bg.cgColor

        brandLogo = NSImageView(frame: .zero)
        brandLogo.imageScaling = .scaleProportionallyUpOrDown
        brandLogo.imageAlignment = .alignLeft
        // Original glow PNGs only — NSImageView scales; we do not re-export the asset
        brandLogo.image = PongTheme.wordmarkImage(height: 38)
        brandLogo.toolTip = PongTheme.productName
        brandLogo.wantsLayer = true
        brandLogo.layer?.masksToBounds = false
        topBar.addSubview(brandLogo)

        // Text label kept for a11y / fallback; wordmark image is the public mark
        brandLabel = Self.label(PongTheme.productName, frame: .zero, bold: true, size: 13)
        brandLabel.font = PongTheme.font(13, weight: .semibold)
        brandLabel.toolTip = PongTheme.productName
        brandLabel.isHidden = true
        topBar.addSubview(brandLabel)

        teamPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        teamPopup.target = self
        teamPopup.action = #selector(teamChanged)
        teamPopup.font = PongTheme.labelFont(11)
        PongTheme.stylePopUp(teamPopup)
        topBar.addSubview(teamPopup)

        topTabCanvas = makeTopTab("Map", tag: 0)
        topTabMission = makeTopTab("Mission", tag: 1)
        topTabSetup = makeTopTab("Setup", tag: 2)
        topBar.addSubview(topTabCanvas)
        topBar.addSubview(topTabMission)
        topBar.addSubview(topTabSetup)

        statusPill = NSView(frame: .zero)
        statusPill.wantsLayer = true
        statusPill.layer?.backgroundColor = NSColor.clear.cgColor
        statusPill.layer?.cornerRadius = 12
        statusPill.layer?.borderWidth = PongTheme.hairline
        statusPill.layer?.borderColor = PongTheme.border.cgColor
        statusDot = NSView(frame: NSRect(x: 10, y: 10, width: 6, height: 6))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusPill.addSubview(statusDot)
        statusText = Self.label("Idle", frame: NSRect(x: 22, y: 5, width: 120, height: 16), size: 11, secondary: true)
        statusText.font = PongTheme.labelFont(11)
        statusText.maximumNumberOfLines = 1
        statusText.lineBreakMode = .byTruncatingTail
        statusPill.addSubview(statusText)
        topBar.addSubview(statusPill)

        refreshBtn = iconTextButton("↻", #selector(reloadPressed))
        refreshBtn.toolTip = "Refresh"
        topBar.addSubview(refreshBtn)

        appearanceBtn = iconTextButton("☀", #selector(appearancePressed))
        topBar.addSubview(appearanceBtn)
        styleAppearanceBtn()

        let line = NSView(frame: .zero)
        line.identifier = NSUserInterfaceItemIdentifier("topline")
        line.wantsLayer = true
        line.layer?.backgroundColor = PongTheme.border.cgColor
        topBar.addSubview(line)
    }

    private func makeTopTab(_ title: String, tag: Int) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.tag = tag
        b.target = self
        b.action = #selector(railPressed(_:))
        b.toolTip = title
        PongTheme.styleTopTab(b, selected: false)
        return b
    }

    private func styleTopTabs() {
        guard topTabCanvas != nil else { return }
        PongTheme.styleTopTab(topTabCanvas, selected: selected == .canvas)
        PongTheme.styleTopTab(topTabMission, selected: selected == .mission)
        PongTheme.styleTopTab(topTabSetup, selected: selected == .setup)
    }

    private func layoutTopBar(width W: CGFloat) {
        let left = trafficInset
        // Compact wordmark so team + tabs fit
        let wmH: CGFloat = 34
        let wmW: CGFloat = min(180, max(120, W * 0.18))
        let wmY = (topH - wmH) / 2
        brandLogo.frame = NSRect(x: left, y: wmY, width: wmW, height: wmH)
        brandLabel.frame = NSRect(x: left, y: wmY, width: wmW, height: wmH)
        let teamX = left + wmW + 12
        let teamW = min(160, max(96, W * 0.14))
        teamPopup.frame = NSRect(x: teamX, y: (topH - 28) / 2, width: teamW, height: 28)
        // Tabs immediately after team dropdown
        var tabX = teamX + teamW + 10
        let tabH: CGFloat = 26
        let tabY = (topH - tabH) / 2
        for (btn, w) in [(topTabCanvas, CGFloat(48)), (topTabMission, CGFloat(64)), (topTabSetup, CGFloat(52))] {
            btn?.frame = NSRect(x: tabX, y: tabY, width: w, height: tabH)
            tabX += w + 4
        }
        statusPill.frame = NSRect(x: W - 236, y: (topH - 28) / 2, width: 140, height: 28)
        appearanceBtn.frame = NSRect(x: W - 80, y: (topH - 28) / 2, width: 28, height: 28)
        refreshBtn.frame = NSRect(x: W - 44, y: (topH - 28) / 2, width: 28, height: 28)
        for v in topBar.subviews where v.identifier?.rawValue == "topline" {
            v.frame = NSRect(x: 0, y: 0, width: W, height: 1)
        }
    }

    @objc private func appearancePressed() {
        PongTheme.toggleAppearance()
    }

    // MARK: Rail

    private func buildRail() {
        rail = NSView(frame: .zero)
        rail.wantsLayer = true
        rail.layer?.backgroundColor = PongTheme.bgRail.cgColor

        railCanvas = railButton(symbol: "square.grid.2x2", fallback: "◎", tip: "Canvas — map of seats", tag: 0)
        railMission = railButton(symbol: "target", fallback: "◎", tip: "Mission — jobs & flow", tag: 1)
        railSetup = railButton(symbol: "gearshape", fallback: "⚙", tip: "Setup — new team & link", tag: 2)
        rail.addSubview(railCanvas)
        rail.addSubview(railMission)
        rail.addSubview(railSetup)

        // Soft cyan glow strip + hard hairline edge (neon dual-edge language)
        let glow = NSView(frame: .zero)
        glow.identifier = NSUserInterfaceItemIdentifier("railglow")
        glow.wantsLayer = true
        glow.layer?.backgroundColor = NSColor.clear.cgColor
        rail.addSubview(glow)

        let edge = NSView(frame: .zero)
        edge.identifier = NSUserInterfaceItemIdentifier("railedge")
        edge.wantsLayer = true
        edge.layer?.backgroundColor = PongTheme.lineSoft.cgColor
        rail.addSubview(edge)
    }

    private func railButton(symbol: String, fallback: String, tip: String, tag: Int) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = ""
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = PongTheme.radiusRail
        b.tag = tag
        b.toolTip = tip
        b.target = self
        b.action = #selector(railPressed(_:))
        b.imagePosition = .imageOnly
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            b.image = img.withSymbolConfiguration(cfg)
            b.contentTintColor = PongTheme.textSecondary
        } else {
            b.attributedTitle = NSAttributedString(string: fallback, attributes: [
                .foregroundColor: PongTheme.textSecondary,
                .font: PongTheme.font(16, weight: .medium),
                .paragraphStyle: centered(),
            ])
        }
        return b
    }

    private func centered() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    private func layoutRail(height H: CGFloat) {
        let top = H - 72
        railCanvas.frame = NSRect(x: 10, y: top, width: 44, height: 44)
        railMission.frame = NSRect(x: 10, y: top - 56, width: 44, height: 44)
        railSetup.frame = NSRect(x: 10, y: top - 112, width: 44, height: 44)
        for v in rail.subviews where v.identifier?.rawValue == "railglow" {
            v.frame = NSRect(x: railW - 6, y: 0, width: 6, height: H)
        }
        for v in rail.subviews where v.identifier?.rawValue == "railedge" {
            v.frame = NSRect(x: railW - 2, y: 0, width: 2, height: H)
        }
    }

    private func styleRail() {
        styleRailBtn(railCanvas, on: selected == .canvas)
        styleRailBtn(railMission, on: selected == .mission)
        styleRailBtn(railSetup, on: selected == .setup)
    }

    private func styleRailBtn(_ b: NSButton, on: Bool) {
        b.layer?.cornerRadius = PongTheme.radiusRail
        b.layer?.backgroundColor = (on ? PongTheme.tabSelected : NSColor.clear).cgColor
        b.layer?.borderWidth = 0
        let tint = on ? PongTheme.textPrimary : PongTheme.textTertiary
        if #available(macOS 11.0, *), b.image != nil {
            b.contentTintColor = tint
            let names = [0: "square.grid.2x2", 1: "target", 2: "gearshape"]
            if let name = names[b.tag],
               let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: on ? .semibold : .medium)
                b.image = img.withSymbolConfiguration(cfg)
            }
        } else {
            let symbols = [0: "◎", 1: "◎", 2: "⚙"]
            let s = symbols[b.tag] ?? "·"
            b.attributedTitle = NSAttributedString(string: s, attributes: [
                .foregroundColor: tint,
                .font: PongTheme.font(16, weight: on ? .semibold : .regular),
                .paragraphStyle: centered(),
            ])
        }
    }

    // MARK: Stage pages

    private func buildStage() {
        stage = NSView(frame: .zero)
        stage.wantsLayer = true
        stage.layer?.backgroundColor = PongTheme.bg.cgColor

        // Canvas page (hit-tests left HUD splitter above SceneKit)
        canvasPage = CanvasPageView(frame: .zero)
        canvasScroll = NSScrollView(frame: .zero)
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.borderType = .noBorder
        canvasScroll.drawsBackground = false
        canvasScroll.backgroundColor = .clear
        // Comfortable workplace — sized to content on reload (not a continent)
        canvas = AgentCanvasView(frame: NSRect(origin: .zero, size: CanvasLayout.minCanvas))
        canvas.onFront = { [weak self] m in self?.frontModel(m) }
        canvas.onKill = { [weak self] m in self?.killModel(m) }
        canvas.onOptions = { [weak self] m in
            TeamOptionsSheetController.shared.show(for: m.session) { self?.reload() }
        }
        canvas.onPerms = { [weak self] m in
            PermissionsSheetController.shared.show(for: m.session, workerId: m.id) { self?.reload() }
        }
        canvas.onChangeModel = { [weak self] m in
            self?.changeSeatModel(m)
        }
        canvas.onFocus = { m in
            TeamFocusController.shared.show(session: m.session)
        }
        canvas.onAddWorker = { [weak self] m in
            self?.handleAdd(from: m)
        }
        canvas.onAddSub = { [weak self] m in
            self?.addWorker(to: m.session, parentId: m.id, parentLabel: m.title, guide: true)
        }
        canvas.onHuman = { [weak self] m in
            // YOU console lives on the HUD (re-parented to canvasPage for both modes)
            self?.map3D?.openHumanDock(session: m.session)
        }
        canvas.onRename = { [weak self] m in
            self?.renameSeat(m)
        }
        canvas.onDragStateChanged = { [weak self] dragging in
            self?.canvasDragging = dragging
            // Keep scrollers during pan; only suppress autoscroll fight while moving nodes
            if self?.canvas.isPanning != true {
                self?.canvasScroll.hasVerticalScroller = !dragging
                self?.canvasScroll.hasHorizontalScroller = !dragging
            }
        }
        // Pinch / toolbar zoom; trackpad pan uses native NSScrollView momentum
        canvasScroll.allowsMagnification = true
        canvasScroll.minMagnification = 0.5
        canvasScroll.maxMagnification = 2.0
        canvasScroll.magnification = 1.0
        canvasScroll.scrollerStyle = .overlay
        canvasScroll.horizontalScrollElasticity = .allowed
        canvasScroll.verticalScrollElasticity = .allowed
        canvasScroll.autohidesScrollers = true
        canvasScroll.documentView = canvas
        canvasPage.addSubview(canvasScroll)

        // 3D constellation map (default) — glowing hierarchy of seats
        map3D = Agent3DMapView(frame: .zero)
        map3D.onOpen = { [weak self] s in
            self?.frontModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: s.role == "conductor" ? PongTheme.blue : PongTheme.magenta,
                origin: .zero
            ))
        }
        map3D.onFocus = { s in
            TeamFocusController.shared.show(session: s.session)
        }
        map3D.onHuman = { s in
            // Docked YOU panel is primary; floating sheet still available as fallback expand
            _ = s
        }
        map3D.onRename = { [weak self] s in
            self?.renameSeat(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.blue, origin: .zero
            ))
        }
        map3D.onKill = { [weak self] s in
            self?.killModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "conductor" ? "conductor" : "worker",
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        map3D.onOptions = { s in
            TeamOptionsSheetController.shared.show(for: s.session) { PanelController.shared.reload() }
        }
        map3D.onPerms = { s in
            PermissionsSheetController.shared.show(for: s.session, workerId: s.id) {
                PanelController.shared.reload()
            }
        }
        map3D.onChangeModel = { [weak self] s in
            self?.changeSeatModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        // Side pad: peer on the same plane
        // - orch/worker → new top-level agent
        // - subagent → another sub under the same parent (same SUB level, not nested)
        map3D.onPlus = { [weak self] s in
            guard let self else { return }
            if s.role == "conductor" || s.role == "worker" {
                self.addWorker(to: s.session, parentId: nil, parentLabel: nil, guide: true)
            } else if s.role == "subagent" {
                let parent = s.parentId
                let entry = PairState.loadPairsDb()[s.session] as? [String: Any] ?? [:]
                let lab = parent.flatMap { pid in
                    Workers.list(from: entry).first(where: { ($0["id"] as? String) == pid })?["label"] as? String
                }
                self.addWorker(to: s.session, parentId: parent, parentLabel: lab ?? parent, guide: true)
            }
        }
        // Under-cube pad: only top-level agents → SUB deck under them
        map3D.onAddSub = { [weak self] s in
            guard s.role == "worker" else { return }
            self?.addWorker(to: s.session, parentId: s.id, parentLabel: s.title, guide: true)
        }
        map3D.onMinus = { [weak self] s in
            self?.killModel(AgentNodeModel(
                session: s.session, id: s.id,
                role: s.role == "conductor" ? "conductor" : "worker",
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        canvasPage.addSubview(map3D)
        canvasPage.map3D = map3D
        // Phase 0: left HUD + legend float over both 2D and 3D (not trapped in map3D)
        map3D.promoteSharedHUD(to: canvasPage)

        canvasToolbar = glassBar()
        canvasPage.addSubview(canvasToolbar)
        // One bar: Orbit/Move · 2D/3D · zoom · Link · Architecture · Reset position (2D) · New team
        // (Guide lives on the map sparkle FAB / app menu — not on this toolbar)
        canvasToolbar.addSubview(pillButton("Orbit", #selector(orbitModePressed)))
        canvasToolbar.addSubview(pillButton("Move", #selector(moveModePressed)))
        canvasToolbar.addSubview(pillButton("3D", #selector(toggleMapMode)))
        canvasToolbar.addSubview(pillButton("−", #selector(zoomOutPressed)))
        canvasToolbar.addSubview(pillButton("+", #selector(zoomInPressed)))
        canvasToolbar.addSubview(pillButton("Link terminals", #selector(linkPressed)))
        canvasToolbar.addSubview(pillButton("Architecture", #selector(architecturePressed)))
        canvasToolbar.addSubview(pillButton("Reset position", #selector(arrangeTeamsPressed)))
        canvasToolbar.addSubview(accentButton("New team", #selector(newTeamPressed)))

        canvasEmpty = emptyState(
            title: "No teams yet",
            body: "Create a team to place a conductor and workers on the constellation.\nYou can also link terminals you already have open.",
            cta: "New team",
            action: #selector(newTeamPressed)
        )
        canvasPage.addSubview(canvasEmpty)
        stage.addSubview(canvasPage)
        applyMapMode()

        // Mission page
        missionPage = NSView(frame: .zero)
        missionScroll = NSScrollView(frame: .zero)
        missionScroll.hasVerticalScroller = true
        missionScroll.autohidesScrollers = true
        missionScroll.borderType = .noBorder
        missionScroll.drawsBackground = false
        missionBody = NSView(frame: .zero)
        missionScroll.documentView = missionBody
        missionPage.addSubview(missionScroll)
        missionPage.isHidden = true
        stage.addSubview(missionPage)

        // Setup page
        setupPage = NSView(frame: .zero)
        setupScroll = NSScrollView(frame: .zero)
        setupScroll.hasVerticalScroller = true
        setupScroll.autohidesScrollers = true
        setupScroll.borderType = .noBorder
        setupScroll.drawsBackground = false
        setupBody = NSView(frame: .zero)
        setupScroll.documentView = setupBody
        setupPage.addSubview(setupScroll)
        setupPage.isHidden = true
        stage.addSubview(setupPage)
        paintSetup()
    }

    private func layoutCanvasPage() {
        let b = canvasPage.bounds
        // Map nearly full-bleed — chrome (toolbar + hint) floats tight at bottom
        let mapFrame = b.insetBy(dx: 6, dy: 6)
        canvasScroll.frame = mapFrame
        canvasScroll.frame.size.height = max(100, b.height - 12)
        map3D.frame = mapFrame
        // Stack: [toolbar] then [hint under it] — no dead 124pt band
        let barH: CGFloat = 40
        let gap: CGFloat = 1
        let hintH = Agent3DMapView.hintStripHeight
        let bottomPad: CGFloat = 4
        // Toolbar sits just above the map’s hint strip (hint is inside map3D at y≈2)
        let barY = mapFrame.minY + bottomPad + hintH + gap
        let contentW = layoutGlassBar(canvasToolbar)
        let tw = min(b.width - 20, max(120, contentW))
        canvasToolbar.frame = NSRect(x: (b.width - tw) / 2, y: barY, width: tw, height: barH)
        _ = layoutGlassBar(canvasToolbar)
        // Keep chrome above SceneKit; HUD/splitter last so widen grip stays hittable
        canvasPage.addSubview(canvasToolbar)
        canvasEmpty.frame = NSRect(x: (b.width - 360) / 2, y: (b.height - 160) / 2, width: 360, height: 160)
        map3D?.layoutPromotedHUD(in: b)
        // After layoutPromotedHUD, re-assert toolbar above map but under? No — toolbar
        // may cover bottom; splitter is on the left column edge so OK under toolbar.
        // Ensure map3D is not re-added above HUD (frame set only).
    }

    private func applyMapMode() {
        map3D?.isHidden = !use3DMap
        canvasScroll?.isHidden = use3DMap
        // Update mode pill label + Orbit/Move selection chrome
        if let canvasToolbar {
            let moveOn = map3D?.isMoveMode == true
            for b in canvasToolbar.subviews.compactMap({ $0 as? NSButton }) {
                let t = b.attributedTitle.string
                let u = t.uppercased()
                if u == "3D" || u == "2D" || u == "FLAT" {
                    let label = use3DMap ? "2D" : "3D"
                    b.attributedTitle = NSAttributedString(string: label, attributes: [
                        .foregroundColor: PongTheme.textPrimary,
                        .font: PongTheme.labelFont(11),
                        .paragraphStyle: centered(),
                    ])
                    b.toolTip = use3DMap ? "Switch to flat map" : "Switch to 3D constellation"
                }
                // Orbit / Move only meaningful on 3D map
                if u == "ORBIT" || u == "MOVE" {
                    b.isHidden = !use3DMap
                    let selected = (u == "MOVE" && moveOn) || (u == "ORBIT" && !moveOn && use3DMap)
                    b.layer?.backgroundColor = (selected
                        ? PongTheme.ink.withAlphaComponent(0.18)
                        : NSColor.clear).cgColor
                }
                if u == "ARCHITECTURE" {
                    b.isHidden = !use3DMap
                }
                // Reset position is 2D-only (flat multi grid)
                if u == "RESET POSITION" || u == "ARRANGE TEAMS" || b.action == #selector(arrangeTeamsPressed) {
                    b.isHidden = use3DMap
                }
            }
            // Re-center after hide/show changes content width
            layoutCanvasPage()
        }
    }

    @objc private func toggleMapMode() {
        use3DMap.toggle()
        AppAISettings.setPrefer3DMap(use3DMap)
        applyMapMode()
        if use3DMap {
            map3D.resetCamera()
            refreshCanvas(light: true)
        } else {
            refreshCanvas(light: true)
            // Fit seats in view so 2D opens usable (not lost in empty space)
            DispatchQueue.main.async { [weak self] in
                self?.fitViewportToNodes()
            }
        }
    }

    /// Ghost seats so first-open 3D still sells the product (not a blank void).
    private static func previewConstellationSeats() -> [Seat3D] {
        let sess = "preview"
        return [
            Seat3D(
                session: sess, id: "c1", role: "conductor",
                title: "Orchestrator", subtitle: "plans · routes · verifies",
                detail: "Your conductor seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "orchestrator"
            ),
            Seat3D(
                session: sess, id: "w1", role: "worker",
                title: "Coder", subtitle: "implements · tests",
                detail: "Worker seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "coder"
            ),
            Seat3D(
                session: sess, id: "w2", role: "worker",
                title: "Reviewer", subtitle: "reviews · rejects soft claims",
                detail: "Worker seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "reviewer"
            ),
            Seat3D(
                session: sess, id: "you", role: "human",
                title: "You", subtitle: "human console",
                detail: "Stay in the loop", status: "idle", parentId: "c1",
                openJobs: 0, flowHint: "", missionRole: "human"
            ),
        ]
    }

    private func layoutMissionPage() {
        missionScroll.frame = missionPage.bounds.insetBy(dx: 20, dy: 16)
    }

    private func layoutSetupPage() {
        setupScroll.frame = setupPage.bounds.insetBy(dx: 20, dy: 16)
    }

    private func glassBar() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        PongTheme.applyFloating(v)
        return v
    }

    /// Lays out visible pills left→right with tight padding. Returns total bar content width.
    @discardableResult
    private func layoutGlassBar(_ bar: NSView) -> CGFloat {
        let buttons = bar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        guard !buttons.isEmpty else { return 40 }
        let pad: CGFloat = 6
        let side: CGFloat = 10
        var x: CGFloat = side
        for b in buttons {
            let title = b.attributedTitle.string.uppercased()
            let w: CGFloat
            switch title {
            case "−", "+", "–", "3D", "2D": w = 36
            case "ORBIT", "MOVE": w = 56
            case "LINK TERMINALS": w = 118
            case "ARCHITECTURE": w = 100
            case "RESET POSITION", "ARRANGE TEAMS": w = 118
            case "NEW TEAM": w = 96
            default: w = max(48, CGFloat(title.count) * 8 + 20)
            }
            b.frame = NSRect(x: x, y: 8, width: w, height: 28)
            x += w + pad
        }
        // Trim trailing pad; keep symmetric side insets
        return x - pad + side
    }

    // MARK: Navigation

    @objc private func railPressed(_ sender: NSButton) {
        guard let d = Destination(rawValue: sender.tag) else { return }
        go(d)
    }

    private func go(_ d: Destination) {
        selected = d
        styleRail()
        styleTopTabs()
        canvasPage.isHidden = d != .canvas
        missionPage.isHidden = d != .mission
        setupPage.isHidden = d != .setup
        // Design: pause 3D while Mission/Setup are showing
        if use3DMap {
            map3D.setMapPlaying(d == .canvas)
            map3D.isHidden = d != .canvas
        }
        reload()
    }

    /// Human chat job chip → Mission tab.
    func goToMission() {
        go(.mission)
    }

    /// Push top-bar team focus into the human console (lock orch target).
    private func syncHumanFocusToMap() {
        map3D?.setFocusedTeamSession(selectedSession)
    }

    private func pairsEmptyOrNoMap() -> Bool {
        // Empty teams still show 3D preview constellation (product promise)
        !use3DMap
    }

    // MARK: Data reload

    @objc private func reloadPressed() { hardRefresh() }

    /// Soft reload (poll / navigation) — file cache + light canvas.
    private func reload() {
        updateStatus()
        fillTeamPopup()
        switch selected {
        case .canvas: refreshCanvas()
        case .mission: paintMission()
        case .setup: paintSetup()
        }
        layoutAll()
    }

    /// Top-right ↻ — force control-plane snapshot + full UI rebuild.
    private func hardRefresh() {
        guard !hardRefreshInFlight else { return }
        hardRefreshInFlight = true
        refreshBtn?.isEnabled = false
        statusText.stringValue = "Refreshing…"
        statusDot.layer?.backgroundColor = PongTheme.blue.cgColor
        PairState.invalidatePairsCache()
        // Allow a concurrent async writer to finish; we force our own snapshot pass
        snapshotRefreshInFlight = false
        Pong.log("refresh hard begin selected=\(selected.rawValue)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Force regenerate snapshot.json (not only re-read a stale file)
            let out = Pong.sh(
                "export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; " +
                "pong snapshot --compact 2>/dev/null | head -c 500000"
            )
            var obj: [String: Any]?
            if let data = out.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               parsed["contract_version"] != nil || parsed["teams"] != nil {
                obj = parsed
            }
            // Best-effort write path if compact stdout failed but CLI still refreshed the file
            if obj == nil {
                _ = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot >/dev/null 2>&1")
                let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
                if !file.isEmpty { obj = file }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let obj { self.lastSnapshot = obj }
                self.updateStatus()
                self.fillTeamPopup()
                switch self.selected {
                case .canvas:
                    self.refreshCanvas(light: false)
                case .mission:
                    self.paintMission()
                case .setup:
                    self.paintSetup()
                }
                self.layoutAll()
                self.hardRefreshInFlight = false
                self.refreshBtn?.isEnabled = true
                // Brief “done” flash then restore normal status
                self.statusText.stringValue = "Refreshed"
                self.statusDot.layer?.backgroundColor = PongTheme.live.cgColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.updateStatus()
                }
                Pong.log("refresh hard done teams=\((obj?["teams"] as? [Any])?.count ?? -1)")
            }
        }
    }

    private func startPoll() {
        poll?.invalidate()
        // 4s poll on .default (not .common) so it pauses during live resize/drag
        let t = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.canvasDragging { return }
            // Skip heavy map rebuild while user is orbiting / moving seats
            if self.use3DMap, self.map3D?.isUserInteracting == true { return }
            // Window recovery OFF main (osascript freezes UI)
            let sess = self.selectedSession
            DispatchQueue.global(qos: .utility).async {
                if let s = sess, s != "__all__" {
                    _ = WindowRecovery.recover(session: s)
                } else {
                    // Throttle full scan: only every 3rd poll (~12s)
                    if Int(Date().timeIntervalSince1970 / 4) % 3 == 0 {
                        WindowRecovery.recoverAll()
                    }
                }
            }
            self.updateStatus()
            if self.selected == .mission { self.paintMission() }
            if self.selected == .canvas {
                self.refreshCanvas(light: true)
                // Poll human asks for focused team without opening Focus window
                self.map3D?.pollHumanConsole()
            }
            // Proactive Guide: situation detectors (ghosts, no-subs, stalled jobs)
            let pairs = PairState.listPairs()
            let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
            GuideCoach.tick(snapshot: snap.isEmpty ? nil : snap, pairs: pairs)
        }
        RunLoop.main.add(t, forMode: .default)
        poll = t
    }

    private func updateStatus() {
        // File-only count — never block main on `tmux list-sessions` (beachball)
        let n = PairState.pairCountFromDb()
        if n == 0 {
            statusText.stringValue = "Idle"
            statusDot.layer?.backgroundColor = PongTheme.idle.cgColor
        } else {
            statusText.stringValue = n == 1 ? "1 team live" : "\(n) teams live"
            statusDot.layer?.backgroundColor = PongTheme.live.cgColor
        }
    }

    private func fillTeamPopup() {
        let pairs = PairState.listPairs()
        let prev = selectedSession
        teamPopup.removeAllItems()
        if pairs.isEmpty {
            teamPopup.addItem(withTitle: "No team")
            teamPopup.isEnabled = false
            selectedSession = nil
            return
        }
        teamPopup.isEnabled = true
        // Multi-team canvas first
        teamPopup.addItem(withTitle: "All teams")
        teamPopup.lastItem?.representedObject = "__all__"
        let db = PairState.loadPairsDb()
        for p in pairs {
            let entry = db[p] as? [String: Any] ?? [:]
            let name = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            teamPopup.addItem(withTitle: name.isEmpty ? p : name)
            teamPopup.lastItem?.representedObject = p
        }
        if prev == "__all__" || prev == nil {
            teamPopup.selectItem(at: 0)
            selectedSession = pairs.count > 1 ? "__all__" : pairs[0]
            if pairs.count == 1 {
                teamPopup.selectItem(at: 1)
                selectedSession = pairs[0]
            }
        } else if let i = pairs.firstIndex(of: prev!) {
            teamPopup.selectItem(at: i + 1) // offset for All teams
            selectedSession = prev
        } else {
            teamPopup.selectItem(at: 0)
            selectedSession = pairs.count > 1 ? "__all__" : pairs[0]
        }
        syncHumanFocusToMap()
    }

    @objc private func teamChanged() {
        selectedSession = teamPopup.selectedItem?.representedObject as? String
        syncHumanFocusToMap()
        refreshCanvas()
    }

    // MARK: Canvas

    private func refreshCanvas(light: Bool = false) {
        if canvasDragging { return }
        let pairs = PairState.listPairs()
        // Empty state: keep 3D constellation + toolbar; hide flat empty card
        canvasEmpty.isHidden = true
        canvasToolbar.isHidden = false
        map3D.isHidden = !use3DMap || selected != .canvas
        // Keep 2D scroll visible even with zero teams so the workplace is always panable
        canvasScroll.isHidden = use3DMap || selected != .canvas
        if pairs.isEmpty {
            if use3DMap {
                map3D.reload(seats: Self.previewConstellationSeats(), multiTeam: false)
                map3D.setMapPlaying(true)
            }
            if !use3DMap {
                canvas.setFrameSize(CanvasLayout.minCanvas)
            }
            return
        }

        let multi = selectedSession == "__all__" || (selectedSession == nil && pairs.count > 1)
        let showPairs: [String] = multi ? pairs : [selectedSession ?? pairs[0]].compactMap { $0 }

        // Start from a modest document; grow to fit seats after layout
        var size = CanvasLayout.minCanvas
        if multi {
            // Grid pitch (see CanvasLayout.multiPitch*) — orch + workers column without overlap
            let cols = CanvasLayout.multiCols
            let rows = max(1, (showPairs.count + cols - 1) / cols)
            size.width = min(
                CanvasLayout.maxCanvas.width,
                max(CanvasLayout.minCanvas.width,
                    CanvasLayout.hudClearX + CGFloat(min(cols, showPairs.count)) * CanvasLayout.multiPitchX + CanvasLayout.workplacePad)
            )
            size.height = min(
                CanvasLayout.maxCanvas.height,
                max(CanvasLayout.minCanvas.height,
                    CanvasLayout.hudClearY + CGFloat(rows) * CanvasLayout.multiPitchY + CanvasLayout.workplacePad)
            )
        }
        canvas.setFrameSize(size)

        let snap = snapshot()
        var models: [AgentNodeModel] = []
        var seats3D: [Seat3D] = []
        var posMap = CanvasLayout.positions(for: multi ? nil : showPairs.first)
        // Multi: unstack teams that share nearly-identical conductor slots (bare-key bug residue)
        if multi {
            if CanvasLayout.unstackOverlappingTeams(&posMap, sessions: showPairs) {
                for (key, p) in posMap where key.contains("::") {
                    let parts = key.components(separatedBy: "::")
                    if parts.count >= 2 {
                        CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
                    }
                }
            }
        } else if CanvasLayout.compactIfSpread(&posMap, multi: false) {
            // Single-team only: heal pathological void scatter
            for (key, p) in posMap {
                if key.contains("::") {
                    let parts = key.components(separatedBy: "::")
                    if parts.count >= 2 {
                        CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
                    }
                } else if let sess = showPairs.first {
                    CanvasLayout.saveSeat(session: sess, nodeId: key, origin: p)
                }
            }
        }

        for (ti, session) in showPairs.enumerated() {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let cond = entry["conductor"] as? [String: Any]
            let condId = (cond?["id"] as? String) ?? "c1"
            let condLabel = (cond?["label"] as? String) ?? "Orchestrator"
            let condType = (cond?["type"] as? String) ?? "grok"
            let stowed = (entry["stowed"] as? Bool) == true
            let brief = (entry["team_brief"] as? String) ?? ""
            let rootPath = (entry["project_root"] as? String) ?? ""
            let detail: String = {
                if !brief.isEmpty { return Self.clampDetail(brief) }
                return Self.seatBlurb(role: "conductor", type: condType, openJobs: 0, root: rootPath)
            }()
            let cOrigin = CanvasLayout.origin(
                session: session, nodeId: condId, multi: multi, map: posMap,
                teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size)
            let cAccent = TerminalTheme.Colors.from(entry["colors"])?.asNSColors.hi ?? PongTheme.blue
            // Orchestrator active only for real in-flight work (same rule as floor dots).
            // Queued jobs → calm “busy”; finished → idle (no pulse/ACTIVE face).
            let teamSnapEarly = (snap?["teams"] as? [[String: Any]])?
                .first(where: { ($0["session"] as? String) == session })
            // Prefer activity_open (age-filtered in snapshot); fall back to open.
            let jobsBag = teamSnapEarly?["jobs"] as? [String: Any]
            let openJobsList: [[String: Any]] = {
                if let act = jobsBag?["activity_open"] as? [[String: Any]] { return act }
                return (jobsBag?["open"] as? [[String: Any]]) ?? []
            }()
            var condOpen = 0
            var condBusy = false       // queued / soft (no pulse)
            var condRunning = false    // real in-flight → packets + primitive pulse
            var condHuman = false
            var condHint = ""
            for j in openJobsList {
                condOpen += 1
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st == "running" || st == "notified" || st.contains("working") {
                    condBusy = true
                    condRunning = true
                }
                if st == "queued" || st == "pending" { condBusy = true }
                if st.contains("human") || st == "human_takeover" {
                    condHuman = true; condBusy = true; condRunning = true
                }
                if condHint.isEmpty {
                    condHint = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? ""
                }
            }
            for w in (teamSnapEarly?["workers"] as? [[String: Any]]) ?? [] {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    condHuman = true; condBusy = true; condRunning = true
                }
                // sticky "busy" alone is not in-flight — only running/working hints
                if h.contains("running") || h.contains("working") || h.contains("notified") {
                    condBusy = true; condRunning = true
                } else if h.contains("busy") {
                    condBusy = true
                }
            }
            let cStatus: String = {
                if stowed { return "hidden" }
                if condHuman { return "human" }
                // "running" → pulse + packets; "busy" → quiet; none → idle
                if condRunning { return "running" }
                if condBusy { return "busy" }
                return "idle"
            }()
            models.append(AgentNodeModel(
                session: session, id: condId, role: "conductor",
                title: condLabel, subtitle: "\(condType) · conductor seat",
                detail: detail, status: cStatus,
                // Always show team display name over the orchestrator (single + multi)
                teamLabel: display,
                accent: cAccent, origin: cOrigin,
                parentId: nil, openJobs: condOpen, flowHint: condHint,
                missionRole: "orchestrator"
            ))
            seats3D.append(Seat3D(
                session: session, id: condId, role: "conductor",
                title: condLabel, subtitle: "\(condType) · conductor",
                detail: detail, status: cStatus, parentId: nil,
                openJobs: condOpen, flowHint: condHint,
                missionRole: "orchestrator",
                accent: cAccent
            ))

            let teamSnap = (snap?["teams"] as? [[String: Any]])?.first(where: { ($0["session"] as? String) == session })
            let snapWorkers = teamSnap?["workers"] as? [[String: Any]] ?? []
            let ws = Workers.list(from: entry)
            for (i, w) in ws.enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let lab = (w["label"] as? String) ?? wid
                let typ = (w["type"] as? String) ?? "worker"
                var status = "idle"
                var openN = 0
                var flowHint = ""
                var mapVisible = true
                var isEphWorker = (w["ephemeral"] as? Bool) == true
                if let match = snapWorkers.first(where: { ($0["id"] as? String) == wid }) {
                    status = (match["status_hint"] as? String) ?? status
                    openN = match["open_jobs"] as? Int ?? 0
                    if let mv = match["map_visible"] as? Bool { mapVisible = mv }
                    if let e = match["ephemeral"] as? Bool { isEphWorker = e }
                }
                // Ephemeral permanent-roster workers vanish from the map when idle
                if isEphWorker && !mapVisible { continue }

                // Job preview + precise status for map (dots + primitive pulse share this):
                // running/notified → "running", human → "human",
                // queued only → "busy" (calm seat — no pulse/dots), none → "idle".
                // Prefer activity_open (age-filtered) so stale notified jobs don't keep seats ACTIVE.
                let workerJobsBlob = teamSnap?["jobs"] as? [String: Any]
                let workerOpenList: [[String: Any]]? = {
                    if let act = workerJobsBlob?["activity_open"] as? [[String: Any]] { return act }
                    return workerJobsBlob?["open"] as? [[String: Any]]
                }()
                if let openList = workerOpenList {
                    let mine = openList.filter {
                        (($0["worker"] as? String) ?? ($0["worker_id"] as? String)) == wid
                    }
                    if let first = mine.first {
                        flowHint = (first["task_preview"] as? String)
                            ?? (first["task"] as? String)
                            ?? ""
                    }
                    let hasHuman = mine.contains {
                        let st = (($0["status"] as? String) ?? "").lowercased()
                        return st.contains("human") || st.contains("ask") || st.contains("takeover")
                    }
                    let hasRunning = mine.contains {
                        let st = (($0["status"] as? String) ?? "").lowercased()
                        return st == "running" || st == "notified" || st.contains("working")
                    }
                    if hasHuman {
                        status = "human"
                    } else if hasRunning {
                        status = "running"
                    } else if openN > 0 || !mine.isEmpty {
                        // Queued / waiting — quiet seat (no bob/ACTIVE)
                        status = "busy"
                    } else {
                        // Work finished — force calm (clear sticky busy/live hints)
                        status = "idle"
                    }
                } else if openN > 0 {
                    status = "busy"
                } else if !status.lowercased().contains("human") {
                    status = "idle"
                }
                let wdetail = Self.seatBlurb(role: "worker", type: typ, openJobs: openN, root: nil)
                let origin = CanvasLayout.origin(
                    session: session, nodeId: wid, multi: multi, map: posMap,
                    teamIndex: ti, role: "worker", workerIndex: i, canvas: size)
                let accent = TerminalTheme.Colors.from(w["colors"])?.asNSColors.hi ?? PongTheme.magenta
                // parent_id → subagent level in 3D (also treat empty string as nil)
                let rawParent = (w["parent_id"] as? String) ?? (w["parent"] as? String)
                let parentId = rawParent.flatMap { $0.isEmpty ? nil : $0 }
                // Flow graph sub edges are a second source of truth if parent_id was lost
                let isSubEdge: Bool = {
                    guard parentId == nil else { return false }
                    let edges = FlowGraph.load(from: entry)
                    return edges.contains { $0.kind == "sub" && $0.to == wid }
                }()
                let role3 = (parentId != nil || isSubEdge) ? "subagent" : "worker"
                let resolvedParent: String? = {
                    if let parentId { return parentId }
                    if isSubEdge {
                        return FlowGraph.load(from: entry).first { $0.kind == "sub" && $0.to == wid }?.from
                    }
                    return nil
                }()
                let missionRole = (w["mission_role"] as? String)
                    ?? (w["role"] as? String)
                    ?? "coder"
                models.append(AgentNodeModel(
                    session: session, id: wid, role: role3,
                    title: lab, subtitle: "\(typ) · \(MissionRole.parse(missionRole)?.title ?? "Agent")",
                    detail: wdetail, status: status,
                    teamLabel: multi ? display : "",
                    accent: accent, origin: origin,
                    parentId: resolvedParent, openJobs: openN, flowHint: flowHint,
                    missionRole: missionRole
                ))
                seats3D.append(Seat3D(
                    session: session, id: wid, role: role3,
                    title: lab, subtitle: "\(typ) · \(MissionRole.parse(missionRole)?.title ?? "Agent")",
                    detail: wdetail, status: status, parentId: resolvedParent,
                    openJobs: openN, flowHint: flowHint,
                    missionRole: missionRole,
                    ephemeral: isEphWorker,
                    accent: accent
                ))
            }

            // Live-spawned subagents (Claude Task agents, pong subagent up, ephemeral jobs)
            // Appear on SUB layer under parent; gone on next poll when job/registry clears.
            if let ephList = teamSnap?["ephemeral_subs"] as? [[String: Any]] {
                for e in ephList {
                    guard let eid = e["id"] as? String, !eid.isEmpty else { continue }
                    // Skip if already present as a permanent worker with same id
                    if seats3D.contains(where: { $0.session == session && $0.id == eid }) { continue }
                    let parentId = (e["parent_id"] as? String) ?? condId
                    let lab = (e["label"] as? String) ?? "Subagent"
                    let preview = (e["task_preview"] as? String) ?? ""
                    let st = (e["status"] as? String) ?? "busy"
                    let mission = (e["mission_role"] as? String) ?? "coder"
                    seats3D.append(Seat3D(
                        session: session, id: eid, role: "subagent",
                        title: lab,
                        subtitle: "spawned · under \(parentId)",
                        detail: preview.isEmpty
                            ? "Ephemeral subagent — vanishes when done"
                            : Self.clampDetail(preview),
                        status: st, parentId: parentId,
                        openJobs: 1, flowHint: preview,
                        missionRole: mission,
                        ephemeral: true
                    ))
                }
            }

            models.append(AgentNodeModel(
                session: session, id: "add", role: "add",
                title: "+", subtitle: "worker", detail: "Add worker",
                status: "idle", teamLabel: "", accent: PongTheme.magenta,
                origin: CGPoint(x: cOrigin.x + AgentNodeView.size.width + 6,
                                y: cOrigin.y + AgentNodeView.size.height / 2 - 14)
            ))
        }

        // Ensure flow_graph exists for editable topology
        for session in showPairs {
            let db = PairState.loadPairsDb()
            if let entry = db[session] as? [String: Any] {
                let g = entry["flow_graph"] as? [String: Any]
                let arr = g?["edges"] as? [[String: Any]] ?? []
                if arr.isEmpty {
                    FlowGraph.save(pair: session, edges: FlowGraph.defaultEdges(entry: entry))
                }
            }
        }

        // Single shared YOU seat (never one-per-team)
        if !showPairs.isEmpty {
            var needsHuman = false
            var primarySession = showPairs[0]
            if let teams = snap?["teams"] as? [[String: Any]] {
                for session in showPairs {
                    guard let team = teams.first(where: { ($0["session"] as? String) == session }) else { continue }
                    for w in (team["workers"] as? [[String: Any]]) ?? [] {
                        let h = ((w["status_hint"] as? String) ?? "").lowercased()
                        if h.contains("human") || h.contains("takeover") {
                            needsHuman = true
                            primarySession = session
                        }
                    }
                    for j in ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                        let st = ((j["status"] as? String) ?? "").lowercased()
                        if st.contains("human") || st.contains("ask") {
                            needsHuman = true
                            primarySession = session
                        }
                    }
                }
            }
            let primaryCond = (PairState.loadPairsDb()[primarySession] as? [String: Any])
                .flatMap { ($0["conductor"] as? [String: Any])?["id"] as? String } ?? "c1"
            seats3D.append(Seat3D(
                session: primarySession, id: "you", role: "human",
                title: "You",
                subtitle: needsHuman
                    ? "A team needs input"
                    : (multi ? "All teams · one human console" : "Send prompts · answer asks"),
                detail: multi
                    ? "One human seat for every team. Dock chat routes to the focused team."
                    : "Human console — talk to the orchestrator without hunting Terminal windows.",
                status: needsHuman ? "human" : "idle",
                parentId: primaryCond, openJobs: 0,
                flowHint: needsHuman ? "NEEDS YOU" : "",
                missionRole: "human"
            ))
        }

        if use3DMap {
            map3D.reload(seats: seats3D, multiTeam: multi)
        } else {
            // Size document to seat cluster + pan padding (fast draw, easy navigation)
            let pts = models.filter { $0.role != "add" && $0.role != "add-sub" }.map(\.origin)
            let fitted = CanvasLayout.workplaceSize(fitting: pts, card: AgentNodeView.size)
            if fitted.width > size.width || fitted.height > size.height {
                size = fitted
                canvas.setFrameSize(size)
            }
            canvas.reload(models: models, multiTeam: multi)
        }
    }

    /// Short seat blurbs for canvas cards (wrap-safe length).
    private static func clampDetail(_ s: String, max: Int = 72) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max - 1)) + "…"
    }

    private static func seatBlurb(role: String, type: String, openJobs: Int, root: String?) -> String {
        let t = type.lowercased()
        if role == "conductor" {
            if let root, !root.isEmpty {
                let leaf = (root as NSString).lastPathComponent
                return clampDetail("Plans jobs · verdicts · \(leaf)")
            }
            switch t {
            case "grok": return "Plans & verifies · Grok Build seat"
            case "hermes": return "Plans & verifies · Hermes seat"
            case "claude": return "Plans & verifies · Claude seat"
            default: return "Plans jobs · verifies claims"
            }
        }
        if openJobs > 0 {
            return "\(openJobs) open job\(openJobs == 1 ? "" : "s") · building"
        }
        switch t {
        case "claude": return "Implements code · files & tests"
        case "grok": return "Implements · Grok Build worker"
        case "codex": return "Implements · Codex worker"
        case "kimi": return "Implements · Kimi worker"
        case "opencode": return "Implements · OpenCode worker"
        case "linked": return "Linked terminal · live session"
        default: return "Executes assigned jobs"
        }
    }

    // MARK: - Mission dashboard

    private var snapshotRefreshInFlight = false

    /// Never block main on `pong snapshot` — paint from file/cache; refresh async.
    private func snapshot() -> [String: Any]? {
        let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if !file.isEmpty { lastSnapshot = file }
        refreshSnapshotAsync()
        return lastSnapshot ?? (file.isEmpty ? nil : file)
    }

    private func refreshSnapshotAsync() {
        guard !snapshotRefreshInFlight else { return }
        snapshotRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot --compact 2>/dev/null | head -c 500000")
            var obj: [String: Any]?
            if let data = out.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               parsed["contract_version"] != nil {
                obj = parsed
            }
            DispatchQueue.main.async {
                self?.snapshotRefreshInFlight = false
                if let obj {
                    self?.lastSnapshot = obj
                    // Apply fresh seat activity immediately (was mission-only → ~poll-cycle lag)
                    if self?.selected == .mission { self?.paintMission() }
                    if self?.selected == .canvas { self?.refreshCanvas(light: true) }
                }
            }
        }
    }

    private func paintMission() {
        // Preserve scroll while repainting (async snapshot used to jump the page)
        let savedScroll = missionScroll.contentView.bounds.origin
        missionBody.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(400, missionScroll.contentSize.width > 20 ? missionScroll.contentSize.width - 4 : 560)
        let snap = snapshot() ?? [:]
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        let ledger = (snap["ledger"] as? [String: Any]) ?? [:]
        let bridgeOn = (snap["bridge_on"] as? Bool) == true
        let events = (snap["events_tail"] as? [[String: Any]]) ?? []

        var yCursor: CGFloat = 0
        var blocks: [(NSView, CGFloat)] = []

        func push(_ v: NSView, _ h: CGFloat) {
            blocks.append((v, h))
            yCursor += h + 12
        }

        // Scan for human-needed seats / jobs
        var humanSessions: [String] = []
        var openJobs = 0, agentCount = 0
        for t in teams {
            let sess = (t["session"] as? String) ?? ""
            openJobs += (t["jobs"] as? [String: Any]).flatMap { ($0["counts"] as? [String: Any])?["open"] as? Int } ?? 0
            agentCount += 1 + ((t["workers"] as? [[String: Any]])?.count ?? 0)
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            for w in workers {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    if !sess.isEmpty, !humanSessions.contains(sess) { humanSessions.append(sess) }
                }
            }
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            for j in openList {
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st.contains("human") || st.contains("ask") {
                    if !sess.isEmpty, !humanSessions.contains(sess) { humanSessions.append(sess) }
                }
            }
        }
        let rounds = ledger["rounds"] as? Int ?? 0
        let rate = Int(((ledger["accept_rate"] as? Double) ?? 0) * 100)
        let streak = ledger["reject_streak"] as? Int ?? 0

        // Header — design: large title + CONTROL PLANE status
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 72))
        head.wantsLayer = true
        let titleL = Self.label("Mission", frame: NSRect(x: 0, y: 30, width: 320, height: 36), bold: true, size: 30)
        titleL.font = PongTheme.font(30, weight: .bold)
        titleL.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        head.addSubview(titleL)
        let bridgeText = bridgeOn ? "CONTROL PLANE · LIVE" : "CONTROL PLANE · OFFLINE"
        let bridgeLbl = Self.label(bridgeText, frame: NSRect(x: 0, y: 10, width: boxW - 8, height: 14), size: 11, secondary: true)
        bridgeLbl.font = PongTheme.mono(11, weight: .medium)
        bridgeLbl.textColor = bridgeOn ? PongTheme.blue : PongTheme.textTertiary
        head.addSubview(bridgeLbl)
        let rule = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        head.addSubview(rule)
        push(head, 72)

        // Mission Q&A + cron entry (Guide-grounded; chips use live snapshot)
        let askH: CGFloat = 118
        let askCard = tacticalCard(width: boxW, height: askH, accent: PongTheme.blue)
        let askTitle = Self.label("Ask about this mission…",
            frame: NSRect(x: 16, y: askH - 28, width: 240, height: 16), size: 12, secondary: false)
        askTitle.font = PongTheme.font(12, weight: .semibold)
        askCard.addSubview(askTitle)
        let cronBtn = NSButton(title: "Describe a schedule…", target: self, action: #selector(missionDescribeCron))
        cronBtn.bezelStyle = .rounded
        cronBtn.font = PongTheme.font(11, weight: .medium)
        cronBtn.frame = NSRect(x: boxW - 168, y: askH - 32, width: 152, height: 24)
        askCard.addSubview(cronBtn)
        let chips = ["Who is idle?", "Any rogue/stale jobs?", "What should I do next?", "Why is orch active?"]
        var chipX: CGFloat = 16
        for (i, chip) in chips.enumerated() {
            let b = NSButton(title: chip, target: self, action: #selector(missionAskChip(_:)))
            b.bezelStyle = .rounded
            b.font = PongTheme.font(10, weight: .medium)
            b.identifier = NSUserInterfaceItemIdentifier(chip)
            b.tag = i
            let w = max(88, CGFloat(chip.count) * 6.2 + 20)
            b.frame = NSRect(x: chipX, y: askH - 58, width: min(w, 160), height: 22)
            askCard.addSubview(b)
            chipX += b.frame.width + 6
        }
        let askField = NSTextField(frame: NSRect(x: 16, y: 36, width: boxW - 100, height: 24))
        askField.placeholderString = "Ask about idle seats, stuck jobs, orch pulse…"
        askField.font = PongTheme.font(12)
        askField.isBordered = true
        askField.bezelStyle = .roundedBezel
        askField.identifier = NSUserInterfaceItemIdentifier("missionAskField")
        askCard.addSubview(askField)
        let askSend = NSButton(title: "Ask", target: self, action: #selector(missionAskSend))
        askSend.bezelStyle = .rounded
        askSend.font = PongTheme.font(11, weight: .semibold)
        askSend.frame = NSRect(x: boxW - 76, y: 34, width: 60, height: 26)
        askCard.addSubview(askSend)
        let replyText = missionAskLastReply.isEmpty
            ? "Answers use live snapshot (status_hint, open jobs, ages)."
            : missionAskLastReply
        let replyL = Self.label(replyText,
            frame: NSRect(x: 16, y: 6, width: boxW - 32, height: 26), size: 11, secondary: true)
        replyL.maximumNumberOfLines = 2
        replyL.lineBreakMode = .byTruncatingTail
        replyL.identifier = NSUserInterfaceItemIdentifier("missionAskReply")
        askCard.addSubview(replyL)
        // Stash field for send action (paint rebuilds; re-find by identifier when sending)
        push(askCard, askH)

        // Human-needed banner (orange path → Focus)
        if !humanSessions.isEmpty {
            let banH: CGFloat = 56
            let ban = tacticalCard(width: boxW, height: banH, accent: PongTheme.orange)
            let humanT = Self.label("Human input required",
                frame: NSRect(x: 16, y: 30, width: boxW - 140, height: 16), size: 13, secondary: false)
            humanT.font = PongTheme.font(13, weight: .semibold)
            humanT.textColor = PongTheme.amber
            ban.addSubview(humanT)
            ban.addSubview(Self.label("\(humanSessions.count) team\(humanSessions.count == 1 ? "" : "s") need you — open Focus to intervene",
                frame: NSRect(x: 16, y: 12, width: boxW - 140, height: 14), size: 12, secondary: true))
            let fb = accentButton("Take action", #selector(missionFocusFirstHuman))
            fb.frame = NSRect(x: boxW - 118, y: 14, width: 100, height: 28)
            ban.addSubview(fb)
            push(ban, banH)
        }

        // What’s happening — cyan left rule
        let digest = missionDigest(openJobs: openJobs, teams: teams.count, streak: streak, human: !humanSessions.isEmpty)
        let digH: CGFloat = 72
        let dig = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: digH))
        dig.wantsLayer = true
        dig.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.9).cgColor
        dig.layer?.cornerRadius = 6
        dig.layer?.borderWidth = 1
        dig.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        let cyanBar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: digH))
        cyanBar.wantsLayer = true
        cyanBar.layer?.backgroundColor = PongTheme.blue.cgColor
        dig.addSubview(cyanBar)
        dig.addSubview(Self.label("What’s happening",
            frame: NSRect(x: 16, y: 46, width: 200, height: 14), size: 11, secondary: true))
        let digBody = Self.label(digest.text,
            frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 26), bold: true, size: 14)
        digBody.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        dig.addSubview(digBody)
        push(dig, digH)

        // KPI 4-up — large values (design)
        let metricsH: CGFloat = 100
        let metrics = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: metricsH))
        let titles = ["Open jobs", "Accept rate", "Seats", "Reject streak"]
        let values = ["\(openJobs)", "\(rate)%", "\(agentCount)", "\(streak)"]
        let subs = ["In flight", "\(rounds) rounds", "\(teams.count) teams", "Current"]
        let metricGap: CGFloat = 12
        let tw = (boxW - metricGap * 3) / 4
        for i in 0..<4 {
            let tile = NSView(frame: NSRect(x: CGFloat(i) * (tw + metricGap), y: 0, width: tw, height: metricsH))
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.85).cgColor
            tile.layer?.cornerRadius = 6
            tile.layer?.borderWidth = 1
            tile.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.14).cgColor
            if i == 3 {
                let top = NSView(frame: NSRect(x: 0, y: metricsH - 2, width: tw, height: 2))
                top.wantsLayer = true
                top.layer?.backgroundColor = PongTheme.amber.withAlphaComponent(0.55).cgColor
                tile.addSubview(top)
            }
            let tL = Self.label(titles[i], frame: NSRect(x: 14, y: 72, width: tw - 28, height: 14), size: 11, secondary: true)
            tL.font = PongTheme.mono(10)
            tile.addSubview(tL)
            let v = Self.label(values[i], frame: NSRect(x: 14, y: 28, width: tw - 28, height: 36), bold: true, size: 28)
            v.font = PongTheme.font(28, weight: .bold)
            v.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
            tile.addSubview(v)
            tile.addSubview(Self.label(subs[i], frame: NSRect(x: 14, y: 10, width: tw - 28, height: 14), size: 11, secondary: true))
            metrics.addSubview(tile)
        }
        push(metrics, metricsH)

        // ── Design handoff: data-viz row 1 — throughput + jobs by status ──
        let gap: CGFloat = 12
        let half = (boxW - gap) / 2
        let chartH: CGFloat = 168
        let row1 = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: chartH))
        let throughputSeries = missionThroughputSeries(events: events)
        let throughputCard = missionChartCard(
            title: "Job throughput", subtitle: "LAST 24H",
            width: half, height: chartH
        )
        drawAreaLineChart(in: throughputCard, series: throughputSeries,
                          plot: NSRect(x: 14, y: 14, width: half - 28, height: chartH - 48),
                          color: PongTheme.blue)
        row1.addSubview(throughputCard)

        // Aggregate real job status counts across teams
        var statusCounts: [String: Int] = [:]
        for t in teams {
            let counts = ((t["jobs"] as? [String: Any])?["counts"] as? [String: Any]) ?? [:]
            if let by = counts["by_status"] as? [String: Any] {
                for (k, v) in by {
                    let n = (v as? Int) ?? Int("\(v)") ?? 0
                    statusCounts[k, default: 0] += n
                }
            } else {
                statusCounts["done", default: 0] += counts["done"] as? Int ?? 0
                statusCounts["failed", default: 0] += counts["failed"] as? Int ?? 0
                statusCounts["open", default: 0] += counts["open"] as? Int ?? 0
            }
            for j in ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                let st = (j["status"] as? String) ?? "queued"
                // Prefer by_status when present; else tally open statuses
                if counts["by_status"] == nil {
                    statusCounts[st, default: 0] += 1
                }
            }
        }
        let statusOrder = ["done", "notified", "running", "queued", "failed", "rejected", "cancelled"]
        var statusRows: [(String, Int, NSColor)] = []
        for key in statusOrder {
            if let n = statusCounts[key], n > 0 {
                let col: NSColor = {
                    switch key {
                    case "done": return PongTheme.blue
                    case "notified", "running": return PongTheme.cyanBright
                    case "failed", "rejected": return PongTheme.orange
                    default: return PongTheme.line
                    }
                }()
                statusRows.append((key, n, col))
            }
        }
        if statusRows.isEmpty {
            statusRows = [("done", 0, PongTheme.blue), ("queued", 0, PongTheme.line)]
        }
        let statusCard = missionChartCard(title: "Jobs by status", subtitle: "", width: half, height: chartH)
        statusCard.frame.origin.x = half + gap
        drawHorizontalBars(in: statusCard, rows: statusRows,
                           plot: NSRect(x: 14, y: 12, width: half - 28, height: chartH - 44))
        row1.addSubview(statusCard)
        push(row1, chartH)

        // ── Design handoff: data-viz row 2 — accept trend + seat utilization ──
        let row2 = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: chartH))
        let acceptSeries = missionAcceptTrend(events: events, ledger: ledger)
        let acceptCard = missionChartCard(
            title: "Accept rate trend", subtitle: "\(rounds) ROUNDS",
            width: half, height: chartH
        )
        drawAreaLineChart(in: acceptCard, series: acceptSeries,
                          plot: NSRect(x: 14, y: 14, width: half - 28, height: chartH - 48),
                          color: NSColor(calibratedWhite: 0.55, alpha: 1),
                          fill: false)
        row2.addSubview(acceptCard)

        let seatBars = missionSeatUtilization(teams: teams)
        let seatCard = missionChartCard(title: "Seat utilization", subtitle: "", width: half, height: chartH)
        seatCard.frame.origin.x = half + gap
        drawVerticalBars(in: seatCard, bars: seatBars,
                         plot: NSRect(x: 14, y: 28, width: half - 28, height: chartH - 56))
        row2.addSubview(seatCard)
        push(row2, chartH)

        // ── Agent / team watchlist (rogue · mistakes · runtime · sharpness) ──
        let watch = missionAgentWatchlist(teams: teams, events: events, ledger: ledger)
        let watchH: CGFloat = 44 + CGFloat(max(watch.count, 1)) * 52 + 8
        let watchCard = missionChartCard(title: "Agent watchlist", subtitle: "HEALTH · RUNTIME · QUALITY",
                                         width: boxW, height: watchH)
        if watch.isEmpty {
            let ok = Self.label("All clear — no seats look stuck, reject-heavy, or over-runtime.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 18), size: 12, secondary: true)
            watchCard.addSubview(ok)
        } else {
            var wy = watchH - 48
            for item in watch.prefix(8) {
                let row = NSView(frame: NSRect(x: 12, y: wy - 44, width: boxW - 24, height: 48))
                row.wantsLayer = true
                row.layer?.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.055, blue: 0.07, alpha: 1).cgColor
                row.layer?.cornerRadius = 5
                row.layer?.borderWidth = 1
                row.layer?.borderColor = item.severity.withAlphaComponent(0.35).cgColor
                let rail = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 48))
                rail.wantsLayer = true
                rail.layer?.backgroundColor = item.severity.cgColor
                row.addSubview(rail)
                let badge = Self.label(item.tag, frame: NSRect(x: 14, y: 26, width: 100, height: 14), size: 10, secondary: false)
                badge.font = PongTheme.mono(10, weight: .semibold)
                badge.textColor = item.severity
                row.addSubview(badge)
                let who = Self.label(item.title, frame: NSRect(x: 120, y: 26, width: boxW - 160, height: 14), bold: true, size: 12)
                who.textColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.96, alpha: 1)
                row.addSubview(who)
                let detail = Self.label(item.detail, frame: NSRect(x: 14, y: 8, width: boxW - 50, height: 14), size: 11, secondary: true)
                detail.lineBreakMode = .byTruncatingTail
                row.addSubview(detail)
                watchCard.addSubview(row)
                wy -= 52
            }
        }
        push(watchCard, watchH)

        // ACTIVITY log (design mono rows)
        let show = Array(events.suffix(12).reversed())
        let actH: CGFloat = 44 + CGFloat(max(show.count, 1)) * 28
        let act = missionChartCard(title: "Activity", subtitle: "CONTROL PLANE", width: boxW, height: actH)
        if show.isEmpty {
            act.addSubview(Self.label("Jobs and verdicts appear here from the control plane.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 14), size: 12, secondary: true))
        } else {
            var ey = actH - 44
            for e in show {
                let t = (e["type"] as? String) ?? "event"
                let extra = [(e["job_id"] as? String), (e["status"] as? String), (e["verdict"] as? String), (e["session"] as? String)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                let line = Self.label("\(t)   \(extra)",
                    frame: NSRect(x: 16, y: ey - 4, width: boxW - 32, height: 16), size: 11, secondary: true)
                line.font = PongTheme.mono(11)
                line.lineBreakMode = .byTruncatingTail
                act.addSubview(line)
                ey -= 28
            }
        }
        push(act, actH)

        // Team boards + Focus CTA
        for team in teams {
            let session = (team["session"] as? String) ?? "?"
            let display = (team["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let openList = ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            let workers = (team["workers"] as? [[String: Any]]) ?? []
            let condLabel = ((team["conductor"] as? [String: Any])?["label"] as? String) ?? "Conductor"
            let needsHuman = humanSessions.contains(session)
            let h: CGFloat = 72 + CGFloat(max(openList.count, 1)) * 28 + 8
            let card = tacticalCard(width: boxW, height: h, accent: needsHuman ? PongTheme.amber : PongTheme.ink)
            card.addSubview(Self.label(display,
                frame: NSRect(x: 14, y: h - 28, width: boxW - 130, height: 18), bold: true, size: 14))
            card.addSubview(Self.label("\(condLabel) · \(workers.count) workers · \(openList.count) open",
                frame: NSRect(x: 14, y: h - 46, width: boxW - 130, height: 14), size: 12, secondary: true))
            let focusBtn = pillButton("Focus", #selector(missionFocusTeam(_:)))
            focusBtn.identifier = NSUserInterfaceItemIdentifier(session)
            focusBtn.frame = NSRect(x: boxW - 90, y: h - 38, width: 72, height: 26)
            card.addSubview(focusBtn)
            var ly = h - 58
            if openList.isEmpty {
                card.addSubview(Self.label("Queue empty — assign work from the conductor.",
                    frame: NSRect(x: 14, y: 14, width: boxW - 28, height: 14), size: 12, secondary: true))
            } else {
                for j in openList.prefix(8) {
                    ly -= 28
                    let st = (j["status"] as? String) ?? "?"
                    let prev = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? ""
                    let workerId = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "w1"
                    let sk = PongTheme.statusKind(st)
                    let row = MissionJobRow(frame: NSRect(x: 10, y: ly, width: boxW - 20, height: 24))
                    row.session = session
                    row.workerId = workerId
                    row.target = self
                    row.action = #selector(missionSelectJob(_:))
                    row.wantsLayer = true
                    row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                    row.layer?.cornerRadius = 4
                    let badge = NSTextField(labelWithString: sk.label)
                    badge.font = PongTheme.labelFont(9)
                    badge.textColor = sk.color
                    badge.isBordered = false
                    badge.backgroundColor = .clear
                    badge.frame = NSRect(x: 8, y: 4, width: 52, height: 14)
                    row.addSubview(badge)
                    let preview = Self.label(String(prev.prefix(80)),
                        frame: NSRect(x: 64, y: 4, width: boxW - 120, height: 14), size: 12, secondary: true)
                    preview.lineBreakMode = .byTruncatingTail
                    row.addSubview(preview)
                    card.addSubview(row)
                }
            }
            push(card, h)
        }

        if teams.isEmpty {
            let empty = emptyState(title: "No mission data",
                                   body: "Start a team on the canvas. Jobs and verdicts from the control plane show up here.",
                                   cta: "Canvas", action: #selector(goCanvas))
            empty.frame = NSRect(x: 0, y: 0, width: min(400, boxW), height: 150)
            push(empty, 150)
        }

        let contentH = max(yCursor + 40, missionScroll.contentSize.height)
        missionBody.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for (v, h) in blocks {
            y -= h
            v.setFrameOrigin(NSPoint(x: 0, y: y))
            if v.frame.width < 10 { v.setFrameSize(NSSize(width: boxW, height: h)) }
            missionBody.addSubview(v)
            y -= 12
        }
        let cv = missionScroll.contentView
        // Keep user's scroll position (async snapshot was resetting it → scroll bug)
        let maxY = max(0, contentH - cv.bounds.height)
        let restoreY = min(max(0, savedScroll.y), maxY)
        cv.scroll(to: NSPoint(x: 0, y: restoreY))
        missionScroll.reflectScrolledClipView(cv)
    }

    /// Shared tactical card shell: lime/role accent rail.
    private func tacticalCard(width: CGFloat, height: CGFloat, accent: NSColor) -> NSView {
        PongSheetChrome.plate(frame: NSRect(x: 0, y: 0, width: width, height: height), accent: accent)
    }

    private func missionDigest(openJobs: Int, teams: Int, streak: Int, human: Bool) -> (text: String, color: NSColor) {
        if human {
            return ("A seat is waiting on you — open Focus and take the terminal.", PongTheme.orange)
        }
        if streak >= 2 {
            return ("Reject streak \(streak) — review claims before the next handoff.", PongTheme.orange)
        }
        if openJobs > 0 {
            return ("\(openJobs) job\(openJobs == 1 ? "" : "s") in flight across \(teams) team\(teams == 1 ? "" : "s").", PongTheme.blue)
        }
        if teams == 0 {
            return ("No live teams. Create or link a team from Setup.", PongTheme.textSecondary)
        }
        return ("Queues clear. Conductor can assign the next job.", PongTheme.magenta)
    }

    // MARK: Mission charts + agent watchlist

    private func missionChartCard(title: String, subtitle: String, width: CGFloat, height: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.92).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.14).cgColor
        // Soft top hairline for depth
        let topLine = NSView(frame: NSRect(x: 1, y: height - 1, width: width - 2, height: 1))
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        v.addSubview(topLine)
        let t = Self.label(title, frame: NSRect(x: 14, y: height - 30, width: max(80, width - 120), height: 16), bold: true, size: 12)
        t.font = PongTheme.font(12, weight: .semibold)
        t.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        v.addSubview(t)
        if !subtitle.isEmpty {
            let s = Self.label(subtitle, frame: NSRect(x: width - 118, y: height - 28, width: 104, height: 14), size: 10, secondary: true)
            s.font = PongTheme.mono(10, weight: .medium)
            s.alignment = .right
            s.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
            v.addSubview(s)
        }
        return v
    }

    /// Bucket event activity into evenly spaced samples for area/line charts.
    private func missionThroughputSeries(events: [[String: Any]]) -> [CGFloat] {
        let now = Date().timeIntervalSince1970
        let window: TimeInterval = 24 * 3600
        let buckets = 12
        var counts = [CGFloat](repeating: 0, count: buckets)
        let step = window / Double(buckets)
        for e in events {
            let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
            guard ts > 0, now - ts <= window else { continue }
            let t = (e["type"] as? String) ?? ""
            // Throughput = created + completed work signals
            guard t == "job.created" || t == "job.dispatch"
                || (t == "job.status" && ((e["status"] as? String) == "done" || (e["status"] as? String) == "notified"))
            else { continue }
            let age = now - ts
            let idx = min(buckets - 1, max(0, Int((window - age) / step)))
            counts[idx] += 1
        }
        // Soft baseline so an empty series still draws a flat floor
        if counts.allSatisfy({ $0 == 0 }) { return [0.2, 0.15, 0.18, 0.12, 0.2, 0.15, 0.1, 0.18, 0.14, 0.2, 0.16, 0.12] }
        return counts
    }

    /// Rolling accept rate (0…1) from verdict events, padded with ledger rate.
    private func missionAcceptTrend(events: [[String: Any]], ledger: [String: Any]) -> [CGFloat] {
        let verdicts = events.filter { ($0["type"] as? String) == "verdict" }
            .compactMap { e -> (TimeInterval, Bool)? in
                let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
                let v = (e["verdict"] as? String) ?? ""
                guard ts > 0, v == "accept" || v == "reject" else { return nil }
                return (ts, v == "accept")
            }
            .sorted { $0.0 < $1.0 }
        let base = CGFloat((ledger["accept_rate"] as? Double) ?? 0.75)
        guard !verdicts.isEmpty else {
            // Gentle flatline at ledger rate
            return Array(repeating: max(0.05, min(1, base)), count: 8)
        }
        let window = max(4, min(12, verdicts.count))
        var series: [CGFloat] = []
        for i in 0..<window {
            let end = Int(Double(verdicts.count - 1) * Double(i) / Double(max(window - 1, 1)))
            let start = max(0, end - 4)
            let slice = verdicts[start...end]
            let acc = slice.filter { $0.1 }.count
            let n = max(1, slice.count)
            series.append(CGFloat(acc) / CGFloat(n))
        }
        return series
    }

    /// Per-seat open-job load for vertical bars: (label, value 0…1, color).
    private func missionSeatUtilization(teams: [[String: Any]]) -> [(String, CGFloat, NSColor)] {
        var bars: [(String, CGFloat, NSColor)] = []
        for t in teams {
            let display = (t["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (t["session"] as? String) ?? "?"
            let shortTeam = String(display.prefix(10))
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            var load: [String: Int] = [:]
            for j in openList {
                let w = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
                load[w, default: 0] += 1
            }
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            if workers.isEmpty {
                let n = openList.count
                bars.append((shortTeam, CGFloat(min(1, Double(n) / 3.0)), n > 0 ? PongTheme.magenta : PongTheme.lineSoft))
                continue
            }
            for w in workers.prefix(6) {
                let id = (w["id"] as? String) ?? "?"
                let label = (w["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(8)) } ?? id
                let n = load[id] ?? 0
                let hint = ((w["status_hint"] as? String) ?? "").lowercased()
                let busyBoost: CGFloat = (hint.contains("busy") || hint.contains("run")) && n == 0 ? 0.35 : 0
                let val = min(1, CGFloat(n) / 2.0 + busyBoost)
                let col: NSColor = n >= 2 ? PongTheme.amber : (n > 0 || busyBoost > 0 ? PongTheme.magenta : PongTheme.lineSoft)
                let name = teams.count > 1 ? "\(label)" : label
                bars.append((name, max(0.06, val), col))
            }
            _ = shortTeam
        }
        if bars.isEmpty {
            return [("—", 0.08, PongTheme.lineSoft)]
        }
        return Array(bars.prefix(8))
    }

    private func drawAreaLineChart(in card: NSView, series: [CGFloat], plot: NSRect, color: NSColor, fill: Bool = true) {
        guard series.count >= 2, plot.width > 8, plot.height > 8 else { return }
        let maxV = max(series.max() ?? 1, 0.001)
        let minV = min(series.min() ?? 0, maxV)
        let span = max(maxV - minV, 0.001)
        let n = series.count
        let path = CGMutablePath()
        let line = CGMutablePath()
        for (i, raw) in series.enumerated() {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1)
            let y = plot.minY + plot.height * ((raw - minV) / span)
            if i == 0 {
                line.move(to: CGPoint(x: x, y: y))
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        path.closeSubpath()

        // Soft plot floor line
        let floor = CAShapeLayer()
        let floorP = CGMutablePath()
        floorP.move(to: CGPoint(x: plot.minX, y: plot.minY))
        floorP.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        floor.path = floorP
        floor.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        floor.lineWidth = 1
        floor.fillColor = nil
        card.layer?.addSublayer(floor)

        if fill {
            let fillL = CAShapeLayer()
            fillL.path = path
            fillL.fillColor = color.withAlphaComponent(0.18).cgColor
            fillL.strokeColor = nil
            card.layer?.addSublayer(fillL)
        }
        let stroke = CAShapeLayer()
        stroke.path = line
        stroke.strokeColor = color.cgColor
        stroke.fillColor = nil
        stroke.lineWidth = 1.5
        stroke.lineJoin = .round
        stroke.lineCap = .round
        card.layer?.addSublayer(stroke)

        // Endpoint dots
        if let last = series.last {
            let x = plot.maxX
            let y = plot.minY + plot.height * ((last - minV) / span)
            let dot = CALayer()
            dot.frame = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            dot.cornerRadius = 3
            dot.backgroundColor = color.cgColor
            card.layer?.addSublayer(dot)
        }
    }

    private func drawHorizontalBars(in card: NSView, rows: [(String, Int, NSColor)], plot: NSRect) {
        guard !rows.isEmpty, plot.height > 10 else { return }
        let maxN = max(rows.map(\.1).max() ?? 1, 1)
        let rowH = min(22, plot.height / CGFloat(rows.count))
        let barMaxW = plot.width - 72
        for (i, row) in rows.enumerated() {
            let y = plot.maxY - CGFloat(i + 1) * rowH + 4
            let lab = Self.label(row.0, frame: NSRect(x: plot.minX, y: y, width: 64, height: 14), size: 10, secondary: true)
            lab.font = PongTheme.mono(10)
            card.addSubview(lab)
            let frac = CGFloat(row.1) / CGFloat(maxN)
            let bw = max(4, barMaxW * frac)
            let bar = NSView(frame: NSRect(x: plot.minX + 68, y: y + 2, width: bw, height: 10))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = row.2.withAlphaComponent(0.85).cgColor
            bar.layer?.cornerRadius = 2
            card.addSubview(bar)
            let nL = Self.label("\(row.1)", frame: NSRect(x: plot.minX + 68 + bw + 6, y: y, width: 36, height: 14), size: 10, secondary: true)
            nL.font = PongTheme.mono(10)
            card.addSubview(nL)
        }
    }

    private func drawVerticalBars(in card: NSView, bars: [(String, CGFloat, NSColor)], plot: NSRect) {
        guard !bars.isEmpty, plot.width > 10 else { return }
        let n = bars.count
        let gap: CGFloat = 6
        let bw = max(8, (plot.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, bar) in bars.enumerated() {
            let x = plot.minX + CGFloat(i) * (bw + gap)
            let h = max(3, plot.height * min(1, max(0, bar.1)))
            let rect = NSView(frame: NSRect(x: x, y: plot.minY, width: bw, height: h))
            rect.wantsLayer = true
            rect.layer?.backgroundColor = bar.2.withAlphaComponent(0.9).cgColor
            rect.layer?.cornerRadius = 2
            card.addSubview(rect)
            let lab = Self.label(bar.0, frame: NSRect(x: x - 4, y: plot.minY - 16, width: bw + 8, height: 12), size: 9, secondary: true)
            lab.font = PongTheme.mono(9)
            lab.alignment = .center
            lab.lineBreakMode = .byTruncatingTail
            card.addSubview(lab)
        }
    }

    /// Flags seats/teams that look stuck, reject-heavy, over-runtime, off-topic, or dull.
    private struct MissionWatchItem {
        let tag: String
        let title: String
        let detail: String
        let severity: NSColor
        let rank: Int // lower = more urgent
    }

    private func missionAgentWatchlist(
        teams: [[String: Any]],
        events: [[String: Any]],
        ledger: [String: Any]
    ) -> [MissionWatchItem] {
        let now = Date().timeIntervalSince1970
        var items: [MissionWatchItem] = []

        // Per-worker reject / fail tallies from events
        var rejects: [String: Int] = [:]   // "session::worker"
        var fails: [String: Int] = [:]
        var refuses: [String: Int] = [:]
        var lastActivity: [String: TimeInterval] = [:]

        for e in events {
            let sess = (e["session"] as? String) ?? ""
            let worker = (e["worker"] as? String) ?? ""
            let key = worker.isEmpty ? "\(sess)::*" : "\(sess)::\(worker)"
            let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
            if ts > (lastActivity[key] ?? 0) { lastActivity[key] = ts }
            let t = (e["type"] as? String) ?? ""
            if t == "verdict", (e["verdict"] as? String) == "reject" {
                rejects[key, default: 0] += 1
                if !worker.isEmpty { rejects["\(sess)::*", default: 0] += 0 }
            }
            if t == "job.status", (e["status"] as? String) == "failed" {
                fails[key, default: 0] += 1
            }
            if t == "route.refused" {
                refuses[key, default: 0] += 1
                if worker.isEmpty { refuses["\(sess)::*", default: 0] += 1 }
            }
        }

        let streak = ledger["reject_streak"] as? Int ?? 0
        if streak >= 2 {
            items.append(MissionWatchItem(
                tag: "STREAK",
                title: "Control plane",
                detail: "Reject streak \(streak) — claims need a sharper review before the next handoff.",
                severity: PongTheme.amber,
                rank: 1
            ))
        }

        for t in teams {
            let sess = (t["session"] as? String) ?? "?"
            let display = (t["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sess
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            let recent = ((t["jobs"] as? [String: Any])?["recent"] as? [[String: Any]]) ?? []
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            let condLabel = ((t["conductor"] as? [String: Any])?["label"] as? String) ?? "Conductor"

            // Map worker id → label
            var labels: [String: String] = ["c1": condLabel]
            for w in workers {
                let id = (w["id"] as? String) ?? ""
                let lab = (w["label"] as? String) ?? id
                if !id.isEmpty { labels[id] = lab }
            }

            // Over-runtime open jobs
            for j in openList {
                let st = ((j["status"] as? String) ?? "").lowercased()
                let created = (j["created_at"] as? Double)
                    ?? (j["created_at"] as? Int).map { Double($0) }
                    ?? (j["updated_at"] as? Double)
                    ?? (j["updated_at"] as? Int).map { Double($0) }
                    ?? 0
                let age = created > 0 ? now - created : 0
                let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
                let who = labels[wid] ?? wid
                let prev = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? j["id"] as? String ?? "job"
                let mins = Int(age / 60)

                // Runtime thresholds: running > 45m, queued/notified > 20m
                let runTooLong = (st == "running" || st == "notified") && age > 45 * 60
                let queueTooLong = (st == "queued" || st == "notified") && age > 20 * 60
                if runTooLong || queueTooLong {
                    let tag = runTooLong ? "RUNTIME" : "STUCK"
                    items.append(MissionWatchItem(
                        tag: tag,
                        title: "\(who) · \(display)",
                        detail: "\(st) \(mins)m — \(String(prev.prefix(72)))",
                        severity: runTooLong ? PongTheme.danger : PongTheme.amber,
                        rank: runTooLong ? 2 : 3
                    ))
                }

                if (j["human_takeover"] as? Bool) == true || st.contains("human") {
                    items.append(MissionWatchItem(
                        tag: "HUMAN",
                        title: "\(who) · \(display)",
                        detail: "Needs takeover — \(String(prev.prefix(72)))",
                        severity: PongTheme.amber,
                        rank: 0
                    ))
                }

                // High round count = not landing claims (dull / not sharp)
                let round = (j["round"] as? Int) ?? 1
                if round >= 3 {
                    items.append(MissionWatchItem(
                        tag: "BLUNT",
                        title: "\(who) · \(display)",
                        detail: "Round \(round) without clean accept — not sharp enough on this task.",
                        severity: PongTheme.violet,
                        rank: 4
                    ))
                }
            }

            // Per-worker quality from recent terminal jobs + events
            var workerFails: [String: Int] = [:]
            var workerDone: [String: Int] = [:]
            for j in recent {
                let wid = (j["worker"] as? String) ?? "?"
                let st = (j["status"] as? String) ?? ""
                if st == "failed" || st == "rejected" { workerFails[wid, default: 0] += 1 }
                if st == "done" { workerDone[wid, default: 0] += 1 }
            }

            for w in workers {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let key = "\(sess)::\(id)"
                let r = rejects[key] ?? 0
                let f = max(fails[key] ?? 0, workerFails[id] ?? 0)
                let ref = refuses[key] ?? 0
                let hint = ((w["status_hint"] as? String) ?? "").lowercased()

                if f >= 2 || r >= 2 {
                    items.append(MissionWatchItem(
                        tag: "MISTAKES",
                        title: "\(lab) · \(display)",
                        detail: "\(max(f, r)) recent fail/reject signal\(max(f, r) == 1 ? "" : "s") — review outputs before more work.",
                        severity: PongTheme.danger,
                        rank: 2
                    ))
                }

                if ref >= 1 {
                    items.append(MissionWatchItem(
                        tag: "ROUTE",
                        title: "\(lab) · \(display)",
                        detail: "Route refused \(ref)× — seat may be unbound, off-channel, or going rogue on transport.",
                        severity: PongTheme.orange,
                        rank: 2
                    ))
                }

                // Busy forever with no open job = phantom load / off-topic thrash
                let openForW = openList.filter {
                    (($0["worker"] as? String) ?? ($0["worker_id"] as? String)) == id
                }
                if (hint.contains("busy") || hint.contains("run")) && openForW.isEmpty {
                    items.append(MissionWatchItem(
                        tag: "DRIFT",
                        title: "\(lab) · \(display)",
                        detail: "Seat reports busy with no control-plane job — possible off-topic or untracked work.",
                        severity: PongTheme.magenta,
                        rank: 5
                    ))
                }

                // Low sharpness: many done but high fail ratio
                let done = workerDone[id] ?? 0
                if done + f >= 3, f > 0, Double(f) / Double(done + f) >= 0.4 {
                    items.append(MissionWatchItem(
                        tag: "BLUNT",
                        title: "\(lab) · \(display)",
                        detail: "Weak hit rate (\(f) bad / \(done + f) recent) — tighten brief or swap model.",
                        severity: PongTheme.violet,
                        rank: 4
                    ))
                }
            }

            // Team-level refuse flood
            let teamRef = refuses["\(sess)::*"] ?? events.filter {
                ($0["session"] as? String) == sess && ($0["type"] as? String) == "route.refused"
            }.count
            if teamRef >= 2 {
                items.append(MissionWatchItem(
                    tag: "ROGUE",
                    title: display,
                    detail: "\(teamRef) route refusals — team transport or seat binding is failing.",
                    severity: PongTheme.danger,
                    rank: 1
                ))
            }

            // Overloaded seat: 3+ open jobs on one worker
            var byW: [String: Int] = [:]
            for j in openList {
                let wid = (j["worker"] as? String) ?? "?"
                byW[wid, default: 0] += 1
            }
            for (wid, n) in byW where n >= 3 {
                let lab = labels[wid] ?? wid
                items.append(MissionWatchItem(
                    tag: "LOAD",
                    title: "\(lab) · \(display)",
                    detail: "\(n) open jobs stacked — risk of thrash and long runtime.",
                    severity: PongTheme.amber,
                    rank: 3
                ))
            }
        }

        // Deduplicate by tag+title, keep best rank
        var best: [String: MissionWatchItem] = [:]
        for it in items {
            let k = "\(it.tag)|\(it.title)"
            if let prev = best[k] {
                if it.rank < prev.rank { best[k] = it }
            } else {
                best[k] = it
            }
        }
        return best.values.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.title < b.title
        }
    }

    @objc private func goCanvas() { go(.canvas) }

    @objc private func missionDescribeCron() {
        let sess = selectedSession.flatMap { $0 == "__all__" ? nil : $0 } ?? PairState.listPairs().first
        // Switch to map so Guide FAB is on-screen, then open cron chat
        go(.canvas)
        DispatchQueue.main.async {
            AppAIChatBubble.shared.beginCronWizard(session: sess)
        }
    }

    @objc private func missionAskChip(_ sender: NSButton) {
        let q = sender.identifier?.rawValue ?? sender.title
        runMissionAsk(q)
    }

    @objc private func missionAskSend() {
        // Find field on mission body
        var text = ""
        func findField(_ v: NSView) {
            if let f = v as? NSTextField, f.identifier?.rawValue == "missionAskField" {
                text = f.stringValue
            }
            for c in v.subviews { findField(c) }
        }
        findField(missionBody)
        runMissionAsk(text)
    }

    private func runMissionAsk(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Instant grounded reply on Mission page + open Guide for follow-up
        let grounded = GuideCoach.answerMissionQuestion(q)
        missionAskLastReply = grounded
        AppAIChatBubble.shared.beginMissionAsk(q)
        // Refresh reply line without full paint when possible
        func setReply(_ v: NSView) {
            if let l = v as? NSTextField, l.identifier?.rawValue == "missionAskReply" {
                l.stringValue = grounded
            }
            for c in v.subviews { setReply(c) }
        }
        setReply(missionBody)
        Pong.log("mission ask q=\(String(q.prefix(80)))")
    }

    @objc private func missionFocusFirstHuman() {
        let snap = snapshot() ?? [:]
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        for t in teams {
            let sess = (t["session"] as? String) ?? ""
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            for w in workers {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    TeamFocusController.shared.show(session: sess)
                    return
                }
            }
        }
        if let first = PairState.listPairs().first {
            TeamFocusController.shared.show(session: first)
        }
    }

    @objc private func missionFocusTeam(_ sender: NSButton) {
        let session = sender.identifier?.rawValue ?? ""
        guard !session.isEmpty else { return }
        TeamFocusController.shared.show(session: session)
    }

    /// Job row → canvas: highlight that worker seat + switch to canvas.
    @objc private func missionSelectJob(_ sender: MissionJobRow) {
        let session = sender.session
        let wid = sender.workerId
        guard !session.isEmpty else { return }
        selectedSession = session
        go(.canvas)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let gid = "\(session)::\(wid)"
            // Also try bare id for single-team keys
            self.canvas.highlight(globalIds: [gid, wid, "\(session)::c1"])
            self.canvas.select(globalId: gid)
        }
    }

    // MARK: Setup

    private func paintSetup() {
        setupBody.subviews.forEach { $0.removeFromSuperview() }
        let W: CGFloat = max(420, setupScroll.contentSize.width > 20 ? setupScroll.contentSize.width - 8 : 480)
        let accessText = Self.accessMapSummary()
        let accessLines = CGFloat(accessText.components(separatedBy: "\n").count)
        let accessH = min(280, max(120, 36 + accessLines * 16))
        var y: CGFloat = 820 + accessH
        setupBody.setFrameSize(NSSize(width: W, height: y))

        // Design: large title + muted subtitle
        let title = Self.label("Setup", frame: NSRect(x: 0, y: y - 42, width: 280, height: 38), bold: true, size: 32)
        title.font = PongTheme.font(32, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        setupBody.addSubview(title)
        y -= 56
        let sub = Self.label("Architect a team, link terminals, or open saved layouts.",
            frame: NSRect(x: 0, y: y, width: W - 20, height: 18), size: 13, secondary: true)
        sub.font = PongTheme.mono(12)
        setupBody.addSubview(sub)
        y -= 28
        let rule = NSView(frame: NSRect(x: 0, y: y, width: W - 20, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        setupBody.addSubview(rule)
        y -= 28

        // Access / MCP map — clear view of who can use tools
        let accessCard = tacticalCard(width: W - 20, height: accessH, accent: PongTheme.limeAction.withAlphaComponent(0.45))
        accessCard.setFrameOrigin(NSPoint(x: 0, y: y - accessH))
        accessCard.addSubview(Self.label("Access · MCP · permissions", frame: NSRect(x: 16, y: accessH - 28, width: W - 48, height: 18), bold: true, size: 14))
        let accessBody = Self.label(accessText,
            frame: NSRect(x: 16, y: 12, width: W - 48, height: accessH - 44), size: 11, secondary: true)
        accessBody.font = PongTheme.mono(10)
        accessBody.maximumNumberOfLines = 0
        accessCard.addSubview(accessBody)
        setupBody.addSubview(accessCard)
        y -= accessH + 16

        // Lime-accent primary card
        let card1 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "New team",
            body: "Guided architecture: draw seats & flows, names, policy, SOUL.md / SKILL.md scaffold.",
            button: "Build team",
            action: #selector(newTeamPressed),
            accent: PongTheme.limeAction
        )
        setupBody.addSubview(card1)
        y -= 132

        let card2 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "Link terminals",
            body: "Attach windows already running — keep model, chat, and resume as-is.",
            button: "Link…",
            action: #selector(linkPressed),
            accent: PongTheme.limeAction.withAlphaComponent(0.55)
        )
        setupBody.addSubview(card2)
        y -= 132

        let n = SavedTeams.loadAll().count
        if n > 0 {
            let card3 = actionCard(
                frame: NSRect(x: 0, y: y - 100, width: W - 20, height: 100),
                title: "Saved teams",
                body: "\(n) saved layout\(n == 1 ? "" : "s"). Open, duplicate, or delete.",
                button: "Manage",
                action: #selector(showTeamsPressed),
                accent: PongTheme.limeAction.withAlphaComponent(0.4)
            )
            setupBody.addSubview(card3)
            y -= 114
        }

        let note = tacticalCard(width: W - 20, height: 96, accent: PongTheme.limeAction.withAlphaComponent(0.35))
        note.setFrameOrigin(NSPoint(x: 0, y: y - 96))
        note.addSubview(Self.label("Control plane", frame: NSRect(x: 16, y: 62, width: 200, height: 16), bold: true, size: 14))
        let noteBody = Self.label("pong snapshot · pong job create · pong check\nJobs are source of truth; the map is how you see seats.",
            frame: NSRect(x: 16, y: 14, width: W - 48, height: 44), size: 12, secondary: true)
        noteBody.font = PongTheme.mono(11)
        note.addSubview(noteBody)
        setupBody.addSubview(note)
        y -= 112

        let appCard = tacticalCard(width: W - 20, height: 64, accent: PongTheme.borderStrong)
        appCard.setFrameOrigin(NSPoint(x: 0, y: y - 64))
        appCard.addSubview(Self.label("Appearance", frame: NSRect(x: 16, y: 34, width: 160, height: 16), bold: true, size: 13))
        appCard.addSubview(Self.label(PongTheme.appearance == .dark ? "Dark" : "Light",
            frame: NSRect(x: 16, y: 14, width: 200, height: 14), size: 12, secondary: true))
        let appB = pillButton(PongTheme.appearance == .dark ? "Light" : "Dark", #selector(appearancePressed))
        appB.frame = NSRect(x: W - 100, y: 18, width: 64, height: 28)
        appCard.addSubview(appB)
        setupBody.addSubview(appCard)
        y -= 80

        // Sequential account switch (one active login per provider CLI)
        let authCard = tacticalCard(width: W - 20, height: 88, accent: PongTheme.limeAction.withAlphaComponent(0.3))
        authCard.setFrameOrigin(NSPoint(x: 0, y: y - 88))
        authCard.addSubview(Self.label("Provider accounts", frame: NSRect(x: 16, y: 58, width: 220, height: 16), bold: true, size: 13))
        authCard.addSubview(Self.label("One login per CLI (Grok/Claude/Hermes). Switch reopens Terminal sign-in.",
            frame: NSRect(x: 16, y: 28, width: W - 48, height: 28), size: 11, secondary: true))
        let switchB = pillButton("Switch account…", #selector(switchAccountPressed))
        switchB.frame = NSRect(x: W - 150, y: 18, width: 120, height: 28)
        authCard.addSubview(switchB)
        setupBody.addSubview(authCard)
    }

    @objc private func switchAccountPressed() {
        if let d = NSApp.delegate as? AppDelegate {
            d.switchProviderAccount()
        }
    }

    /// Who has MCP / tools / env scope — readable for humans.
    private static func accessMapSummary() -> String {
        var lines: [String] = []
        lines.append("MCP = tools a model can call (browser, files, APIs…).")
        lines.append("Ban MCP on a seat → that model cannot use tools.")
        lines.append("Other seats keep their own rules. Scope is per agent.")
        lines.append("")
        let pairs = PairState.listPairs()
        if pairs.isEmpty {
            lines.append("No live teams yet.")
            return lines.joined(separator: "\n")
        }
        let db = PairState.loadPairsDb()
        var mcpOk = 0, mcpBan = 0
        for sess in pairs {
            let entry = db[sess] as? [String: Any] ?? [:]
            let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sess
            let teamPerm = entry["permissions"] as? [String: Any] ?? PairState.defaultPermissions()
            let teamBan = (teamPerm["ban_mcp"] as? Bool) == true
            lines.append("▸ \(name)")
            let cond = entry["conductor"] as? [String: Any] ?? [:]
            let cLab = (cond["label"] as? String) ?? "Boss"
            let cType = (cond["type"] as? String) ?? "?"
            lines.append("  · \(cLab) (\(cType))  MCP: \(teamBan ? "banned" : "allowed")  env: team policy")
            if teamBan { mcpBan += 1 } else { mcpOk += 1 }
            for w in Workers.list(from: entry) {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let typ = (w["type"] as? String) ?? "?"
                let wp = w["permissions"] as? [String: Any] ?? teamPerm
                let ban = (wp["ban_mcp"] as? Bool) == true
                let net = (wp["ban_network"] as? Bool) == true
                let repo = (wp["repo_only"] as? Bool) == true
                var flags: [String] = []
                flags.append(ban ? "MCP off" : "MCP on")
                if net { flags.append("no network") }
                if repo { flags.append("repo only") }
                lines.append("  · \(lab) (\(typ)/\(id))  \(flags.joined(separator: " · "))")
                if ban { mcpBan += 1 } else { mcpOk += 1 }
            }
            // Env files hint
            let root = (entry["project_root"] as? String) ?? ""
            if !root.isEmpty {
                lines.append("  · project: \(root)  (.env lives here if present)")
            }
            lines.append("")
        }
        lines.append("Totals: \(mcpOk) seat(s) MCP-on · \(mcpBan) MCP-banned")
        lines.append("Edit: seat → Policy. Ban MCP on Hermes only keeps Claude tools alone.")
        return lines.joined(separator: "\n")
    }

    private func actionCard(frame: NSRect, title: String, body: String, button: String, action: Selector, accent: NSColor = PongTheme.amber) -> NSView {
        let v = PongSheetChrome.plate(frame: NSRect(origin: .zero, size: frame.size), accent: accent)
        v.setFrameOrigin(frame.origin)
        v.addSubview(Self.label(title, frame: NSRect(x: 16, y: frame.height - 34, width: frame.width - 40, height: 20), bold: true, size: 15))
        let bodyL = Self.label(body, frame: NSRect(x: 16, y: 44, width: frame.width - 150, height: frame.height - 86), size: 12, secondary: true)
        bodyL.maximumNumberOfLines = 3
        v.addSubview(bodyL)
        let b = PongSheetChrome.primaryButton(button, target: self, action: action)
        b.frame = NSRect(x: frame.width - 120, y: 14, width: 104, height: 30)
        v.addSubview(b)
        return v
    }

    // MARK: Buttons

    private func accentButton(_ title: String, _ sel: Selector) -> NSButton {
        // Primary chrome CTA = white fill (line-work system), not blue/magenta
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.ink.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.bg,
            .font: PongTheme.labelFont(11),
            .paragraphStyle: centered(),
        ])
        b.target = self
        b.action = sel
        return b
    }

    private func pillButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.clear.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.layer?.borderWidth = PongTheme.hairline
        b.layer?.borderColor = PongTheme.line.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.labelFont(11),
            .paragraphStyle: centered(),
        ])
        b.target = self
        b.action = sel
        return b
    }

    private func iconTextButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = pillButton(title, sel)
        b.layer?.cornerRadius = 8
        return b
    }

    private func emptyState(title: String, body: String, cta: String, action: Selector) -> NSView {
        let v = NSView(frame: .zero)
        PongTheme.applyCard(v)
        let t = Self.label(title, frame: NSRect(x: 24, y: 100, width: 300, height: 22), bold: true, size: 16)
        let b = Self.label(body, frame: NSRect(x: 24, y: 48, width: 300, height: 48), size: 12, secondary: true)
        let btn = accentButton(cta, action)
        btn.frame = NSRect(x: 24, y: 14, width: 120, height: 30)
        v.addSubview(t)
        v.addSubview(b)
        v.addSubview(btn)
        return v
    }

    // MARK: Actions

    @objc private func newTeamPressed() {
        AppDelegate.launchTeamWithOptionalWizard { [weak self] in
            guard let self else { return }
            let pairs = PairState.listPairs()
            if let last = pairs.last {
                self.selectedSession = last
            }
            self.go(.canvas)
            self.reload()
        }
    }

    @objc private func linkPressed() {
        guide.startLink(parent: self)
    }

    @objc private func showTeamsPressed() {
        TeamsManagerPanel.shared.show { [weak self] in self?.reload() }
    }

    @objc private func orbitModePressed() {
        map3D?.setNavigateMode()
        applyMapMode()
    }

    @objc private func moveModePressed() {
        map3D?.setMoveMode()
        applyMapMode()
    }

    @objc private func architecturePressed() {
        map3D?.openArchitectureSheet()
    }

    /// 2D multi: force every team onto distinct default grid slots (persists scoped positions).
    @objc private func arrangeTeamsPressed() {
        guard !use3DMap else { return }
        let pairs = PairState.listPairs()
        guard !pairs.isEmpty else { return }
        // Prefer all-teams view so the re-grid is visible
        if pairs.count > 1 { selectedSession = "__all__" }

        var posMap = CanvasLayout.positions(for: nil)
        let before = posMap
        let didChange = CanvasLayout.arrangeTeams(&posMap, sessions: pairs)

        var moved = 0
        for (key, p) in posMap where key.contains("::") {
            let parts = key.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            if let old = before[key] {
                if hypot(old.x - p.x, old.y - p.y) >= 1 { moved += 1 }
            } else {
                moved += 1
            }
            CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
        }
        CanvasLayout.scrubCanvasAllBareKeys()

        reload()
        DispatchQueue.main.async { [weak self] in
            self?.fitViewportToNodes()
        }
        Pong.log("reset position n=\(pairs.count) changed=\(didChange) moved=\(moved)")
    }

    @objc private func zoomInPressed() {
        if use3DMap {
            // Mild dolly-in on 3D camera if available; otherwise ignore
            map3D?.requestMapRender()
            return
        }
        guard let scroll = canvasScroll else { return }
        let next = min(scroll.maxMagnification, scroll.magnification * 1.15)
        scroll.animator().magnification = next
    }

    @objc private func zoomOutPressed() {
        if use3DMap {
            map3D?.requestMapRender()
            return
        }
        guard let scroll = canvasScroll else { return }
        let next = max(scroll.minMagnification, scroll.magnification / 1.15)
        scroll.animator().magnification = next
    }

    /// (Fit removed from toolbar — kept for any legacy callers.)
    @objc private func fitPressed() {
        if use3DMap {
            map3D.resetCamera()
            return
        }
        let multi = selectedSession == "__all__" || (selectedSession == nil && PairState.listPairs().count > 1)
        let pairs = PairState.listPairs()
        let show = multi ? pairs : [selectedSession].compactMap { $0 }.filter { $0 != "__all__" }
        guard !show.isEmpty else { return }
        let size = canvas.bounds.size.width > 0 ? canvas.bounds.size : NSSize(width: 1400, height: 1000)
        var pos: [String: CGPoint] = [:]
        for (ti, session) in show.enumerated() {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
            let cOrigin = CanvasLayout.defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size, multi: multi)
            pos["\(session)::\(condId)"] = cOrigin
            pos[condId] = cOrigin
            CanvasLayout.saveSeat(session: session, nodeId: condId, origin: cOrigin)
            for (i, w) in Workers.list(from: entry).enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let o = CanvasLayout.defaultPosition(teamIndex: ti, role: "worker", workerIndex: i, canvas: size, multi: multi)
                pos["\(session)::\(wid)"] = o
                pos[wid] = o
                CanvasLayout.saveSeat(session: session, nodeId: wid, origin: o)
            }
            let ak = CanvasLayout.key(session: session, nodeId: "add", multi: multi)
            pos[ak] = CGPoint(x: cOrigin.x + 200, y: cOrigin.y + 40)
        }
        CanvasLayout.save(session: multi ? nil : show.first, positions: pos, multi: multi)
        refreshCanvas()
        DispatchQueue.main.async { [weak self] in
            self?.fitViewportToNodes()
        }
    }

    /// Magnify + scroll so every seat card is visible with padding.
    private func fitViewportToNodes() {
        guard let scroll = canvasScroll,
              let box = canvas.contentBoundsOfNodes() else {
            canvasScroll?.magnification = 1.0
            return
        }
        let pad: CGFloat = 64
        let target = box.insetBy(dx: -pad, dy: -pad)
        // contentView.bounds.size is already in document coords (post-magnification)
        scroll.magnification = 1.0
        let vis = scroll.contentView.bounds.size
        guard vis.width > 1, vis.height > 1, target.width > 1, target.height > 1 else { return }
        // Prefer 1× if the cluster already fits; only zoom out when needed
        let sx = vis.width / target.width
        let sy = vis.height / target.height
        var mag = min(1.0, min(sx, sy))
        mag = min(scroll.maxMagnification, max(scroll.minMagnification, mag))
        scroll.magnification = mag
        let vis2 = scroll.contentView.bounds.size
        var origin = NSPoint(
            x: target.midX - vis2.width / 2,
            y: target.midY - vis2.height / 2
        )
        let doc = canvas.bounds.size
        let maxX = max(0, doc.width - vis2.width)
        let maxY = max(0, doc.height - vis2.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func frontModel(_ m: AgentNodeModel) {
        // Open re-attaches tmux if the Terminal window was closed (history intact).
        Pong.log("frontModel role=\(m.role) id=\(m.id) session=\(m.session) title=\(m.title)")
        if m.role == "worker" || m.role == "subagent" || m.id.hasPrefix("w") {
            Workers.frontWorker(pair: m.session, workerId: m.id)
        } else if m.role == "conductor" || m.id.hasPrefix("c") {
            Pairing.frontConductor(m.session)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(m.session) }
        }
    }

    /// Rename + neon accent pick for conductor or worker (map primitive, glow, Terminal).
    private func renameSeat(_ m: AgentNodeModel) {
        // Subagents are mapped to "worker" by map/canvas callers; also accept raw subagent.
        let isConductor = m.role == "conductor"
        let isAgent = m.role == "worker" || m.role == "subagent"
        guard isConductor || isAgent else { return }
        NSApp.activate(ignoringOtherApps: true)

        let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
        let existingColors: TerminalTheme.Colors? = {
            if isConductor { return TerminalTheme.Colors.from(entry["colors"]) }
            let ws = Workers.list(from: entry)
            return TerminalTheme.Colors.from(ws.first(where: { ($0["id"] as? String) == m.id })?["colors"])
        }()
        var selectedNeonId = PongNeonCatalog.matching(existingColors)?.id
            ?? (isConductor ? "plasma" : "magenta")

        let a = NSAlert()
        a.messageText = isConductor ? "Rename orchestrator" : "Rename agent"
        a.informativeText = "Display name + neon accent for the map cube, plane glow, and Terminal."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let field = NSTextField(frame: NSRect(x: 0, y: 68, width: 320, height: 24))
        field.stringValue = m.title
        field.placeholderString = isConductor ? "e.g. Grok Build" : "e.g. Claude · Auth"
        box.addSubview(field)

        let swatchLabel = NSTextField(labelWithString: "Neon accent")
        swatchLabel.font = PongTheme.labelFont(10)
        swatchLabel.textColor = PongTheme.textSecondary
        swatchLabel.frame = NSRect(x: 0, y: 48, width: 320, height: 14)
        box.addSubview(swatchLabel)

        let chipRow = NSStackView(frame: NSRect(x: 0, y: 8, width: 320, height: 34))
        chipRow.orientation = .horizontal
        chipRow.spacing = 8
        chipRow.alignment = .centerY
        var chipButtons: [NSButton] = []
        let chipSize: CGFloat = 24
        for sw in PongNeonCatalog.all {
            let b = NSButton(frame: NSRect(x: 0, y: 0, width: chipSize, height: chipSize))
            b.title = ""
            b.image = nil
            b.imagePosition = .imageOnly
            b.bezelStyle = .shadowlessSquare
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.wantsLayer = true
            b.layer?.masksToBounds = true
            b.layer?.cornerRadius = chipSize / 2
            b.layer?.backgroundColor = sw.highlightNS.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            b.toolTip = sw.name
            b.identifier = NSUserInterfaceItemIdentifier(sw.id)
            b.target = NeonChipTarget.shared
            b.action = #selector(NeonChipTarget.chipPressed(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: chipSize).isActive = true
            b.heightAnchor.constraint(equalToConstant: chipSize).isActive = true
            chipRow.addArrangedSubview(b)
            chipButtons.append(b)
        }
        box.addSubview(chipRow)

        func styleChips() {
            for b in chipButtons {
                let on = b.identifier?.rawValue == selectedNeonId
                b.title = ""
                b.imagePosition = .imageOnly
                b.layer?.masksToBounds = true
                b.layer?.cornerRadius = chipSize / 2
                b.layer?.borderColor = (on ? PongSheetChrome.lime.cgColor : NSColor.black.withAlphaComponent(0.35).cgColor)
                b.layer?.borderWidth = on ? 2.5 : 1
                b.layer?.shadowOpacity = 0
            }
        }
        NeonChipTarget.shared.onPick = { id in
            selectedNeonId = id
            styleChips()
        }
        styleChips()

        a.accessoryView = box
        a.window.initialFirstResponder = field
        field.currentEditor()?.selectAll(nil)
        DispatchQueue.main.async { field.selectText(nil) }
        guard a.runModal() == .alertFirstButtonReturn else {
            NeonChipTarget.shared.onPick = nil
            return
        }
        NeonChipTarget.shared.onPick = nil

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !name.isEmpty && name != m.title
        let swatch = PongNeonCatalog.swatch(id: selectedNeonId)
            ?? PongNeonCatalog.all.first!
        // Always persist color on Save (even if name unchanged)
        if nameChanged {
            if isConductor {
                Workers.setConductorLabel(pair: m.session, label: name)
            } else {
                Workers.setWorkerLabel(pair: m.session, workerId: m.id, label: name)
            }
        } else if name.isEmpty {
            return
        }
        let session = m.session
        let seatId = m.id
        let colors = swatch.colors
        DispatchQueue.global(qos: .userInitiated).async {
            if isConductor {
                Workers.setPairColors(session, colors: colors, applyTheme: true)
            } else {
                Workers.setWorkerColors(pair: session, workerId: seatId, colors: colors, applyTheme: true)
            }
            DispatchQueue.main.async {
                let displayName = nameChanged ? name : m.title
                let gid = "\(session)::\(seatId)"
                self.map3D?.applySeatTitle(globalId: gid, title: displayName)
                self.reload()
            }
        }
    }

    /// Live CLI/model switch on a worker seat (2D cards + 3D module share this).
    private func changeSeatModel(_ m: AgentNodeModel) {
        guard m.role != "conductor", m.id != "c1" else {
            let a = NSAlert()
            a.messageText = "Orchestrator model switch"
            a.informativeText = "Changing the orchestrator CLI live is not supported here — restart the team or use Architecture design for a new plan. Workers can switch via CLI on their card."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        let cur = (ws.first(where: { ($0["id"] as? String) == m.id })?["type"] as? String) ?? ""
        let models = WorkerType.all.filter { $0.id != "custom" }

        let pick = NSAlert()
        pick.messageText = "Switch CLI for \(m.title)"
        pick.informativeText = "Current: \(WorkerType.resolved(cur.isEmpty ? "claude" : cur).label). Pick a new AI / CLI for seat \(m.id)."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for t in models {
            popup.addItem(withTitle: t.label)
            popup.lastItem?.representedObject = t.id
            if t.id == cur { popup.select(popup.lastItem) }
        }
        pick.accessoryView = popup
        pick.addButton(withTitle: "Continue")
        pick.addButton(withTitle: "Cancel")
        guard pick.runModal() == .alertFirstButtonReturn else { return }
        guard let newId = popup.selectedItem?.representedObject as? String else { return }
        if newId.lowercased() == cur.lowercased() {
            let same = NSAlert()
            same.messageText = "Already \(WorkerType.resolved(newId).label)"
            same.informativeText = "Pick a different model to switch."
            same.addButton(withTitle: "OK")
            same.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Switch to \(WorkerType.resolved(newId).label)?"
        confirm.informativeText =
            "Seat \(m.id) will restart its agent process in the same terminal window.\n" +
            "Mission role and architecture stay the same; a seat-prime prompt is re-injected."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Switch")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let hist = NSAlert()
        hist.messageText = "Paste previous model history?"
        hist.informativeText =
            "Capture a bounded scrollback from the current session and paste it into the new CLI with a clear header.\n\n" +
            "Yes — last ~200 lines / ~14KB max.\nNo — clean start with seat prime only."
        hist.addButton(withTitle: "Yes, paste history")
        hist.addButton(withTitle: "No")
        hist.addButton(withTitle: "Cancel")
        let histResp = hist.runModal()
        if histResp == .alertThirdButtonReturn { return }
        let includeHistory = histResp == .alertFirstButtonReturn

        let session = m.session
        let seatId = m.id
        PongLoadingOverlay.show(on: window, message: "Switching CLI…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Workers.switchWorkerModel(
                pair: session,
                workerId: seatId,
                newTypeId: newId,
                includeHistory: includeHistory
            )
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                if !result.ok {
                    let err = NSAlert()
                    err.messageText = "Model switch failed"
                    err.informativeText = result.message
                    err.addButton(withTitle: "OK")
                    err.runModal()
                }
                self.reload()
            }
        }
    }

    private func killModel(_ m: AgentNodeModel) {
        if m.role == "worker" || m.id.hasPrefix("w") {
            let a = NSAlert()
            a.messageText = "Remove worker “\(m.title)”?"
            a.informativeText =
                "This closes that seat’s terminal/session.\n" +
                "In-flight jobs for \(m.id) may be lost or stuck.\n\n" +
                "The rest of the team stays running."
            a.alertStyle = .warning
            a.addButton(withTitle: "Remove worker")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            _ = Workers.removeWorker(pair: m.session, workerId: m.id)
            reload()
        } else {
            confirmKillTeam(session: m.session, displayName: m.title)
        }
    }

    /// Kill entire team with hard warnings + optional Save team first.
    private func confirmKillTeam(session: String, displayName: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Terminate team “\(displayName)”?"
        a.informativeText =
            "This will:\n" +
            "• Kill the orchestrator and all worker terminals / tmux sessions\n" +
            "• Drop the live pair from pairs.json\n" +
            "• Lose unsaved chat context in those terminals\n" +
            "• Leave open jobs without a live team\n\n" +
            "Session: \(session)\n\n" +
            "Save the team layout first if you want to spawn it again later."
        a.alertStyle = .critical
        a.addButton(withTitle: "Save team, then terminate")
        a.addButton(withTitle: "Terminate without saving")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            // Save then kill
            let nameAlert = NSAlert()
            nameAlert.messageText = "Save team as…"
            nameAlert.informativeText = "Reusable under Show Teams (workers, crons, brief…)."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = displayName.isEmpty ? session : displayName
            nameAlert.accessoryView = field
            nameAlert.addButton(withTitle: "Save & terminate")
            nameAlert.addButton(withTitle: "Cancel")
            nameAlert.window.initialFirstResponder = field
            guard nameAlert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            _ = SavedTeams.saveFromLivePair(session, teamName: name, options: SavedTeams.SaveOptions())
            Pairing.killPair(session)
            selectedSession = nil
            reload()
        case .alertSecondButtonReturn:
            Pairing.killPair(session)
            selectedSession = nil
            reload()
        default:
            break
        }
    }

    private func addWorker(to session: String) {
        addWorker(to: session, parentId: nil, parentLabel: nil, guide: false)
    }

    /// `parentId` when set: helper under that worker seat (3D HELPERS layer + parent_id).
    private func addWorker(to session: String, parentId: String?, parentLabel: String?, guide: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if let parentLabel {
            a.messageText = "Add helper"
            a.informativeText = "Under “\(parentLabel)” — a helper that reports back to them."
        } else {
            a.messageText = "Add agent"
            a.informativeText = "New teammate next to the boss. You’ll name them next."
        }
        for t in WorkerType.all where t.id != "custom" {
            a.addButton(withTitle: t.label)
        }
        a.addButton(withTitle: "Custom…")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        let types = WorkerType.all.filter { $0.id != "custom" }
        let picked: WorkerType?
        if idx >= 0 && idx < types.count {
            picked = WorkerType.resolved(types[idx].id)
        } else if idx == types.count {
            picked = AppDelegate.pickCustomWorker()
        } else {
            picked = nil
        }
        guard let wt = picked else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let newId = Workers.addWorker(pair: session, type: wt, parentId: parentId)
            DispatchQueue.main.async {
                self.reload()
                if guide, let newId, !newId.isEmpty {
                    AgentGuideTutorial.present(session: session, seatId: newId)
                }
            }
        }
    }
}

// Extend canvas callback — add-sub uses parent worker context
extension PanelController {
    fileprivate func handleAdd(from m: AgentNodeModel) {
        if m.role == "add-sub" {
            let parentId = m.id.replacingOccurrences(of: "add-sub-", with: "")
            let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
            let lab = Workers.list(from: entry).first(where: { ($0["id"] as? String) == parentId })?["label"] as? String
            addWorker(to: m.session, parentId: parentId, parentLabel: lab ?? parentId)
        } else {
            addWorker(to: m.session, parentId: nil, parentLabel: nil)
        }
    }
}

/// Clickable job row on Mission → highlights seat on canvas.
final class MissionJobRow: NSView {
    var session: String = ""
    var workerId: String = ""
    weak var target: AnyObject?
    var action: Selector?

    override func mouseDown(with event: NSEvent) {
        if let t = target, let a = action {
            _ = t.perform(a, with: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Neon swatch chips in rename accessory (fixed catalog only).
final class NeonChipTarget: NSObject {
    static let shared = NeonChipTarget()
    var onPick: ((String) -> Void)?

    @objc func chipPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !id.isEmpty else { return }
        onPick?(id)
    }
}


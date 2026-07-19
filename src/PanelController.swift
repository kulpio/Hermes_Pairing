import AppKit

/// Modern SuperGrok-inspired control panel: resizable chrome, tabs, agent canvas.
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var window: NSWindow?
    private var rootView: NSView!
    private var headerView: NSView!
    private var headerTitle: NSTextField!
    private var headerSub: NSTextField!
    private var headerPill: NSView!
    private var headerLine: NSView!
    private var tabBarView: NSView!
    private var footerView: NSView!
    private var footerLine: NSView!
    private var footerRefresh: NSButton!
    private var footerClose: NSButton!
    private var headerStatus: NSTextField!
    private var liveDot: NSView!
    private var tabTeams: NSButton!
    private var tabMission: NSButton!
    private var tabSetup: NSButton!
    private var bodyHost: NSView!

    // Teams canvas
    private var canvasHost: NSView!
    private var canvasToolbar: NSView!
    private var teamPopup: NSPopUpButton!
    private var fitBtn: NSButton!
    private var addWorkerBtn: NSButton!
    private var newTeamBtn: NSButton!
    private var canvasScroll: NSScrollView!
    private var canvas: AgentCanvasView!
    private var canvasEmptyLabel: NSTextField!

    // Mission
    private var missionScroll: NSScrollView!
    private var missionList: NSView!

    // Setup
    private var setupScroll: NSScrollView!
    private var setupView: NSView!
    private var showTeamsBtn: NSButton?
    private var showTeamsHint: NSTextField?

    private var refreshTimer: Timer?
    private var selectedTab: Tab = .teams
    private var selectedSession: String?
    private let guide = LinkGuideController()

    private let minW: CGFloat = 560
    private let minH: CGFloat = 480
    private let defaultW: CGFloat = 780
    private let defaultH: CGFloat = 640
    /// Clearance under traffic lights when using fullSizeContentView
    private let trafficClearance: CGFloat = 78
    private let titlebarLift: CGFloat = 28
    private let headerH: CGFloat = 56
    private let tabH: CGFloat = 48
    private let footerH: CGFloat = 52
    private let PAD: CGFloat = 16

    enum Tab: Int { case teams = 0, mission = 1, setup = 2 }

    // MARK: - Public

    func show() {
        if window == nil { buildWindow() }
        refreshUI()
        startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshUI() {
        updateHeader()
        updateShowTeamsChrome()
        switch selectedTab {
        case .teams: rebuildCanvas()
        case .mission: rebuildMission()
        case .setup: layoutSetupIfNeeded()
        }
        layoutChrome()
    }

    // MARK: - Shared label helper

    static func label(_ text: String, frame: NSRect, bold: Bool = false,
                      size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? PongTheme.font(size, weight: .semibold) : PongTheme.font(size)
        f.textColor = secondary ? PongTheme.textSecondary : PongTheme.textPrimary
        f.frame = frame
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 6
        f.backgroundColor = .clear
        f.isBezeled = false
        f.drawsBackground = false
        return f
    }

    // MARK: - Window

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultW, height: defaultH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "Pong"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bg
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: minW, height: minH)
        win.setContentSize(NSSize(width: defaultW, height: defaultH))
        win.center()
        win.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: defaultW, height: defaultH))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]
        rootView = root

        buildHeader()
        buildTabs()
        buildBody()
        buildFooter()
        root.addSubview(headerView)
        root.addSubview(tabBarView)
        root.addSubview(bodyHost)
        root.addSubview(footerView)

        win.contentView = root
        window = win
        layoutChrome()
        selectTab(.teams, animated: false)
    }

    func windowDidResize(_ notification: Notification) {
        layoutChrome()
        if selectedTab == .teams {
            // Keep canvas large enough to drag
            let size = canvasContentSize()
            canvas.setFrameSize(size)
            canvas.needsDisplay = true
        }
        if selectedTab == .mission { rebuildMission() }
        if selectedTab == .setup { layoutSetupIfNeeded() }
    }

    private var contentW: CGFloat { rootView?.bounds.width ?? defaultW }
    private var contentH: CGFloat { rootView?.bounds.height ?? defaultH }

    private func layoutChrome() {
        guard let root = rootView else { return }
        let W = root.bounds.width
        let H = root.bounds.height

        // Header sits BELOW traffic lights
        let headerTop = H - titlebarLift - headerH
        headerView.frame = NSRect(x: 0, y: headerTop, width: W, height: headerH)
        layoutHeaderContents(width: W)

        let tabTop = headerTop - tabH
        tabBarView.frame = NSRect(x: PAD, y: tabTop + 6, width: W - 2 * PAD, height: 36)
        layoutTabs(width: W - 2 * PAD)

        footerView.frame = NSRect(x: 0, y: 0, width: W, height: footerH)
        layoutFooter(width: W)

        let bodyY = footerH
        let bodyH = max(120, tabTop - footerH)
        bodyHost.frame = NSRect(x: 0, y: bodyY, width: W, height: bodyH)

        let inset = NSRect(x: PAD, y: 8, width: W - 2 * PAD, height: bodyH - 16)
        canvasHost?.frame = inset
        missionScroll?.frame = inset
        setupScroll?.frame = inset

        if let canvasHost {
            layoutCanvasHost(canvasHost.bounds)
        }
    }

    // MARK: - Header (avoids traffic lights)

    private func buildHeader() {
        headerView = NSView(frame: .zero)
        headerView.wantsLayer = true

        headerTitle = Self.label("Pong", frame: .zero, bold: true, size: 17)
        headerView.addSubview(headerTitle)

        headerSub = Self.label("Orchestration control", frame: .zero, size: 11, secondary: true)
        headerView.addSubview(headerSub)

        headerPill = NSView(frame: .zero)
        PongTheme.applyCard(headerPill)
        headerPill.layer?.cornerRadius = 14
        liveDot = NSView(frame: NSRect(x: 10, y: 10, width: 8, height: 8))
        liveDot.wantsLayer = true
        liveDot.layer?.cornerRadius = 4
        liveDot.layer?.backgroundColor = PongTheme.idle.cgColor
        headerPill.addSubview(liveDot)
        headerStatus = Self.label("Idle", frame: NSRect(x: 24, y: 5, width: 140, height: 18), size: 11, secondary: true)
        headerStatus.lineBreakMode = .byTruncatingTail
        headerStatus.maximumNumberOfLines = 1
        headerPill.addSubview(headerStatus)
        headerView.addSubview(headerPill)

        headerLine = NSView(frame: .zero)
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = PongTheme.border.cgColor
        headerView.addSubview(headerLine)
    }

    private func layoutHeaderContents(width W: CGFloat) {
        // Leave traffic lights alone — content starts at trafficClearance
        let left = trafficClearance
        headerTitle.frame = NSRect(x: left, y: 26, width: 160, height: 22)
        headerSub.frame = NSRect(x: left, y: 8, width: 220, height: 16)
        headerPill.frame = NSRect(x: W - PAD - 176, y: 14, width: 176, height: 28)
        headerLine.frame = NSRect(x: 0, y: 0, width: W, height: 1)
    }

    // MARK: - Tabs

    private func buildTabs() {
        tabBarView = NSView(frame: .zero)
        tabBarView.wantsLayer = true
        tabBarView.layer?.backgroundColor = PongTheme.bgInput.cgColor
        tabBarView.layer?.cornerRadius = 12
        tabBarView.layer?.borderWidth = 1
        tabBarView.layer?.borderColor = PongTheme.border.cgColor

        tabTeams = makeTab("Canvas", tag: 0)
        tabMission = makeTab("Mission", tag: 1)
        tabSetup = makeTab("Setup", tag: 2)
        tabBarView.addSubview(tabTeams)
        tabBarView.addSubview(tabMission)
        tabBarView.addSubview(tabSetup)
    }

    private func layoutTabs(width W: CGFloat) {
        let tw = (W - 8) / 3
        tabTeams.frame = NSRect(x: 4, y: 3, width: tw, height: 30)
        tabMission.frame = NSRect(x: 4 + tw, y: 3, width: tw, height: 30)
        tabSetup.frame = NSRect(x: 4 + 2 * tw, y: 3, width: tw, height: 30)
    }

    private func makeTab(_ title: String, tag: Int) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.tag = tag
        b.target = self
        b.action = #selector(tabPressed(_:))
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textSecondary,
            .font: PongTheme.font(12, weight: .medium),
        ])
        return b
    }

    // MARK: - Body

    private func buildBody() {
        bodyHost = NSView(frame: .zero)
        bodyHost.wantsLayer = true

        // Canvas host
        canvasHost = NSView(frame: .zero)
        canvasToolbar = NSView(frame: .zero)
        canvasToolbar.wantsLayer = true
        teamPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        teamPopup.target = self
        teamPopup.action = #selector(teamPopupChanged(_:))
        teamPopup.bezelStyle = .texturedRounded
        canvasToolbar.addSubview(teamPopup)

        fitBtn = softButton("Fit", #selector(fitCanvasPressed(_:)), .zero)
        canvasToolbar.addSubview(fitBtn)
        addWorkerBtn = softButton("+ Worker", #selector(addWorkerHint(_:)), .zero)
        canvasToolbar.addSubview(addWorkerBtn)
        newTeamBtn = primaryButton("New team", #selector(newPairPressed(_:)), .zero)
        canvasToolbar.addSubview(newTeamBtn)
        canvasHost.addSubview(canvasToolbar)

        canvasScroll = NSScrollView(frame: .zero)
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.borderType = .noBorder
        canvasScroll.drawsBackground = false
        canvasScroll.backgroundColor = .clear
        canvas = AgentCanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        canvas.onFront = { [weak self] session, nodeId in
            self?.canvasFront(session: session, nodeId: nodeId)
        }
        canvas.onKill = { [weak self] session, nodeId in
            self?.canvasKill(session: session, nodeId: nodeId)
        }
        canvas.onOptions = { [weak self] session in
            TeamOptionsSheetController.shared.show(for: session) { self?.refreshUI() }
        }
        canvas.onPerms = { [weak self] session, workerId in
            PermissionsSheetController.shared.show(for: session, workerId: workerId) {
                self?.refreshUI()
            }
        }
        canvasScroll.documentView = canvas
        canvasHost.addSubview(canvasScroll)

        canvasEmptyLabel = Self.label(
            "No teams yet — create one or link terminals in Setup.",
            frame: .zero, size: 12, secondary: true)
        canvasEmptyLabel.alignment = .center
        canvasEmptyLabel.isHidden = true
        canvasHost.addSubview(canvasEmptyLabel)

        bodyHost.addSubview(canvasHost)

        missionScroll = makeScroll()
        missionList = NSView(frame: .zero)
        missionScroll.documentView = missionList
        missionScroll.isHidden = true
        bodyHost.addSubview(missionScroll)

        setupScroll = makeScroll()
        setupView = NSView(frame: .zero)
        setupScroll.documentView = setupView
        setupScroll.isHidden = true
        bodyHost.addSubview(setupScroll)
        buildSetupContent()
    }

    private func layoutCanvasHost(_ bounds: NSRect) {
        let toolH: CGFloat = 40
        canvasToolbar.frame = NSRect(x: 0, y: bounds.height - toolH, width: bounds.width, height: toolH)
        // Toolbar layout
        teamPopup.frame = NSRect(x: 0, y: 6, width: min(220, bounds.width * 0.35), height: 28)
        fitBtn.frame = NSRect(x: bounds.width - 220, y: 4, width: 52, height: 30)
        addWorkerBtn.frame = NSRect(x: bounds.width - 160, y: 4, width: 72, height: 30)
        newTeamBtn.frame = NSRect(x: bounds.width - 80, y: 4, width: 80, height: 30)
        canvasScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - toolH - 4)
        canvasEmptyLabel.frame = NSRect(x: 20, y: bounds.height / 2 - 20, width: bounds.width - 40, height: 40)
        // Clip canvas view with rounded border
        canvasScroll.wantsLayer = true
        canvasScroll.layer?.cornerRadius = 12
        canvasScroll.layer?.borderWidth = 1
        canvasScroll.layer?.borderColor = PongTheme.border.cgColor
    }

    private func makeScroll() -> NSScrollView {
        let s = NSScrollView(frame: .zero)
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = false
        s.autohidesScrollers = true
        s.borderType = .noBorder
        s.drawsBackground = false
        s.scrollerStyle = .overlay
        s.backgroundColor = .clear
        return s
    }

    private func buildSetupContent() {
        let W: CGFloat = 700
        var y: CGFloat = 520
        setupView.setFrameSize(NSSize(width: W, height: y + 20))

        func section(_ t: String) {
            y -= 22
            let l = Self.label(t.uppercased(), frame: NSRect(x: 4, y: y, width: 300, height: 16),
                               size: 10, secondary: true)
            l.font = PongTheme.font(10, weight: .semibold)
            setupView.addSubview(l)
            y -= 8
        }

        section("Start")
        y -= 40
        setupView.addSubview(primaryButton("New team", #selector(newPairPressed(_:)),
            NSRect(x: 0, y: y, width: W - 40, height: 40)))
        y -= 48
        let st = softButton("Show saved teams", #selector(showTeamsPressed(_:)),
            NSRect(x: 0, y: y, width: W - 40, height: 36))
        st.isHidden = true
        setupView.addSubview(st)
        showTeamsBtn = st
        y -= 24
        let hint = Self.label("Open, duplicate, or delete saved team layouts.",
            frame: NSRect(x: 4, y: y, width: W - 48, height: 16), size: 11, secondary: true)
        hint.isHidden = true
        setupView.addSubview(hint)
        showTeamsHint = hint

        y -= 48
        setupView.addSubview(softButton("Link existing terminals", #selector(linkPressed(_:)),
            NSRect(x: 0, y: y, width: W - 40, height: 36)))

        y -= 100
        let tipCard = NSView(frame: NSRect(x: 0, y: y, width: W - 40, height: 110))
        PongTheme.applyCard(tipCard)
        tipCard.addSubview(Self.label("Canvas",
            frame: NSRect(x: 14, y: 80, width: 200, height: 18), bold: true, size: 12))
        tipCard.addSubview(Self.label(
            "Drag agents to rearrange. Double-click or Front to focus a terminal.\nRight-click a node for more actions. Edges show conductor → workers.\nPositions are saved per team.",
            frame: NSRect(x: 14, y: 12, width: tipCard.bounds.width - 28, height: 64),
            size: 11, secondary: true))
        setupView.addSubview(tipCard)

        y -= 100
        let cliCard = NSView(frame: NSRect(x: 0, y: y, width: W - 40, height: 80))
        PongTheme.applyCard(cliCard)
        cliCard.addSubview(Self.label("Control plane",
            frame: NSRect(x: 14, y: 50, width: 200, height: 18), bold: true, size: 12))
        cliCard.addSubview(Self.label(
            "pong check · pong snapshot · pong job create\nJobs are the source of truth; paste is optional.",
            frame: NSRect(x: 14, y: 12, width: cliCard.bounds.width - 28, height: 36),
            size: 11, secondary: true))
        setupView.addSubview(cliCard)
    }

    private func layoutSetupIfNeeded() {
        let w = max(400, (setupScroll?.contentSize.width ?? 600) - 8)
        if abs(setupView.frame.width - w) > 2 {
            // keep content; just width for scroll
            setupView.setFrameSize(NSSize(width: w, height: max(setupView.frame.height, 520)))
        }
    }

    // MARK: - Footer

    private func buildFooter() {
        footerView = NSView(frame: .zero)
        footerView.wantsLayer = true
        footerView.layer?.backgroundColor = PongTheme.bgFooter.cgColor
        footerLine = NSView(frame: .zero)
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = PongTheme.border.cgColor
        footerView.addSubview(footerLine)
        footerRefresh = softButton("Refresh", #selector(refreshPressed(_:)), .zero)
        footerView.addSubview(footerRefresh)
        footerClose = ghostButton("Close", #selector(closePressed(_:)), .zero)
        footerView.addSubview(footerClose)
    }

    private func layoutFooter(width W: CGFloat) {
        footerLine.frame = NSRect(x: 0, y: footerH - 1, width: W, height: 1)
        let half = (W - 2 * PAD - 10) / 2
        footerRefresh.frame = NSRect(x: PAD, y: 11, width: half, height: 30)
        footerClose.frame = NSRect(x: PAD + half + 10, y: 11, width: half, height: 30)
    }

    // MARK: - Buttons

    private func primaryButton(_ title: String, _ sel: Selector, _ frame: NSRect, id: String? = nil) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .rounded
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.accent.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.layer?.shadowColor = PongTheme.accent.cgColor
        b.layer?.shadowOpacity = 0.35
        b.layer?.shadowRadius = 8
        b.layer?.shadowOffset = .zero
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: PongTheme.font(12, weight: .semibold),
        ])
        b.target = self
        b.action = sel
        if let id { b.identifier = NSUserInterfaceItemIdentifier(id) }
        return b
    }

    private func softButton(_ title: String, _ sel: Selector, _ frame: NSRect, id: String? = nil) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .rounded
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongTheme.border.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.font(11, weight: .medium),
        ])
        b.target = self
        b.action = sel
        if let id { b.identifier = NSUserInterfaceItemIdentifier(id) }
        return b
    }

    private func ghostButton(_ title: String, _ sel: Selector, _ frame: NSRect, id: String? = nil) -> NSButton {
        let b = softButton(title, sel, frame, id: id)
        b.layer?.backgroundColor = PongTheme.bgInput.cgColor
        return b
    }

    // MARK: - Tabs

    @objc private func tabPressed(_ sender: NSButton) {
        guard let t = Tab(rawValue: sender.tag) else { return }
        selectTab(t, animated: true)
    }

    private func selectTab(_ tab: Tab, animated: Bool) {
        selectedTab = tab
        styleTab(tabTeams, on: tab == .teams)
        styleTab(tabMission, on: tab == .mission)
        styleTab(tabSetup, on: tab == .setup)
        canvasHost.isHidden = tab != .teams
        missionScroll.isHidden = tab != .mission
        setupScroll.isHidden = tab != .setup
        refreshUI()
    }

    private func styleTab(_ b: NSButton, on: Bool) {
        b.layer?.backgroundColor = (on ? PongTheme.tabSelected : PongTheme.tabIdle).cgColor
        let titles = [0: "Canvas", 1: "Mission", 2: "Setup"]
        let t = titles[b.tag] ?? b.attributedTitle.string
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: on ? PongTheme.textPrimary : PongTheme.textSecondary,
            .font: PongTheme.font(12, weight: on ? .semibold : .medium),
        ])
    }

    // MARK: - Header / polling

    private func updateHeader() {
        let pairs = PairState.listPairs()
        let n = pairs.count
        if n == 0 {
            headerStatus?.stringValue = "Idle"
            liveDot?.layer?.backgroundColor = PongTheme.idle.cgColor
        } else {
            headerStatus?.stringValue = n == 1 ? "1 team live" : "\(n) teams live"
            liveDot?.layer?.backgroundColor = PongTheme.live.cgColor
        }
    }

    private func startPolling() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.updateHeader()
            if self?.selectedTab == .mission { self?.rebuildMission() }
            if self?.selectedTab == .teams { self?.rebuildCanvas(light: true) }
        }
    }

    private func updateShowTeamsChrome() {
        let n = SavedTeams.loadAll().count
        let has = n > 0
        showTeamsBtn?.isHidden = !has
        showTeamsHint?.isHidden = !has
        if has {
            showTeamsBtn?.attributedTitle = NSAttributedString(
                string: "Show saved teams (\(n))",
                attributes: [
                    .foregroundColor: PongTheme.textPrimary,
                    .font: PongTheme.font(12, weight: .medium),
                ])
        }
    }

    // MARK: - Canvas

    private func canvasContentSize() -> NSSize {
        let base = canvasScroll.contentSize
        return NSSize(width: max(1100, base.width + 200), height: max(800, base.height + 200))
    }

    private func rebuildCanvas(light: Bool = false) {
        let pairs = PairState.listPairs()
        // Team popup
        let previous = selectedSession
        teamPopup.removeAllItems()
        if pairs.isEmpty {
            teamPopup.addItem(withTitle: "No teams")
            teamPopup.isEnabled = false
            canvasEmptyLabel.isHidden = false
            canvas.isHidden = true
            selectedSession = nil
            return
        }
        teamPopup.isEnabled = true
        canvasEmptyLabel.isHidden = true
        canvas.isHidden = false
        for p in pairs {
            let entry = PairState.loadPairsDb()[p] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = display.isEmpty ? p : "\(display)  (\(p))"
            teamPopup.addItem(withTitle: title)
            teamPopup.lastItem?.representedObject = p
        }
        if let previous, let idx = pairs.firstIndex(of: previous) {
            teamPopup.selectItem(at: idx)
            selectedSession = previous
        } else {
            teamPopup.selectItem(at: 0)
            selectedSession = pairs[0]
        }
        guard let session = selectedSession else { return }

        let size = canvasContentSize()
        if !light || canvas.frame.size.width < size.width {
            canvas.setFrameSize(size)
        }

        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let saved = CanvasLayout.positions(for: session)
        var models: [AgentNodeModel] = []

        let cond = entry["conductor"] as? [String: Any]
        let condType = (cond?["type"] as? String) ?? "hermes"
        let condLabel = (cond?["label"] as? String) ?? "Conductor"
        let condId = (cond?["id"] as? String) ?? "c1"
        let stowed = (entry["stowed"] as? Bool) == true
        let cOrigin = saved[condId] ?? CanvasLayout.defaultPosition(role: "conductor", index: 0, canvas: size)
        let cAccent = TerminalTheme.Colors.from(entry["colors"])?.asNSColors.hi
            ?? NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.95, alpha: 1)
        let root = (entry["project_root"] as? String) ?? ""
        let brief = (entry["team_brief"] as? String) ?? ""
        let condDetail: String = {
            if !brief.isEmpty { return String(brief.prefix(90)) }
            if !root.isEmpty { return root }
            return "Plans, fans out jobs, verifies claims"
        }()
        models.append(AgentNodeModel(
            id: condId,
            role: "conductor",
            title: condLabel,
            subtitle: "\(condType) · orchestra",
            detail: condDetail,
            status: stowed ? "hidden" : "live",
            accent: cAccent,
            origin: cOrigin
        ))

        let ws = Workers.list(from: entry)
        for (i, w) in ws.enumerated() {
            let wid = (w["id"] as? String) ?? "w\(i + 1)"
            let lab = (w["label"] as? String) ?? wid
            let typ = (w["type"] as? String) ?? "worker"
            let origin = saved[wid] ?? CanvasLayout.defaultPosition(role: "worker", index: i, canvas: size)
            let accent = TerminalTheme.Colors.from(w["colors"])?.asNSColors.hi
                ?? PongTheme.accent
            var status = "idle"
            var detail = "Implements tasks from the conductor"
            if let snap = lastSnapshotCache,
               let teams = snap["teams"] as? [[String: Any]],
               let team = teams.first(where: { ($0["session"] as? String) == session }),
               let workers = team["workers"] as? [[String: Any]],
               let match = workers.first(where: { ($0["id"] as? String) == wid }) {
                status = (match["status_hint"] as? String) ?? status
                let oj = match["open_jobs"] as? Int ?? 0
                if oj > 0 {
                    status = "busy"
                    detail = "\(oj) open job\(oj == 1 ? "" : "s") in queue"
                }
            }
            models.append(AgentNodeModel(
                id: wid,
                role: "worker",
                title: lab,
                subtitle: typ,
                detail: detail,
                status: status,
                accent: accent,
                origin: origin
            ))
        }

        canvas.reload(session: session, models: models)
    }

    private var lastSnapshotCache: [String: Any]?

    @objc private func teamPopupChanged(_ sender: NSPopUpButton) {
        selectedSession = sender.selectedItem?.representedObject as? String
        rebuildCanvas()
    }

    @objc private func fitCanvasPressed(_ sender: NSButton) {
        guard let session = selectedSession else { return }
        // Reset positions to defaults
        let size = canvasContentSize()
        var pos: [String: CGPoint] = [:]
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
        pos[condId] = CanvasLayout.defaultPosition(role: "conductor", index: 0, canvas: size)
        for (i, w) in Workers.list(from: entry).enumerated() {
            let wid = (w["id"] as? String) ?? "w\(i + 1)"
            pos[wid] = CanvasLayout.defaultPosition(role: "worker", index: i, canvas: size)
        }
        CanvasLayout.save(session: session, positions: pos)
        rebuildCanvas()
    }

    @objc private func addWorkerHint(_ sender: NSButton) {
        let a = NSAlert()
        a.messageText = "Add a worker"
        a.informativeText =
            "v1: start a New team with multiple workers, or Link existing terminals.\n\n" +
            "Canvas already shows every worker on the selected team — drag to arrange."
        a.addButton(withTitle: "New team")
        a.addButton(withTitle: "Link terminals")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            newPairPressed(sender)
        } else if r == .alertSecondButtonReturn {
            linkPressed(sender)
        }
    }

    private func canvasFront(session: String, nodeId: String) {
        if nodeId == "c1" || nodeId.hasPrefix("c") {
            // conductor — front whole pair
            DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(session) }
        } else {
            Workers.frontWorker(pair: session, workerId: nodeId)
        }
    }

    private func canvasKill(session: String, nodeId: String) {
        if nodeId == "c1" || !(nodeId.hasPrefix("w")) {
            let alert = NSAlert()
            alert.messageText = "Kill entire team?"
            alert.informativeText = session
            alert.addButton(withTitle: "Kill team")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Pairing.killPair(session)
            refreshUI()
        } else {
            let alert = NSAlert()
            alert.messageText = "Remove worker \(nodeId)?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = Workers.removeWorker(pair: session, workerId: nodeId)
            refreshUI()
        }
    }

    // MARK: - Mission (snapshot)

    private func loadSnapshot() -> [String: Any] {
        let out = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot --compact 2>/dev/null | head -c 500000")
        if let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["contract_version"] != nil {
            lastSnapshotCache = obj
            return obj
        }
        let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if !file.isEmpty { lastSnapshotCache = file }
        return file
    }

    private func rebuildMission() {
        guard let missionList else { return }
        missionList.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(360, missionScroll.contentSize.width > 0 ? missionScroll.contentSize.width : 520)
        let snap = loadSnapshot()
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        let ledger = (snap["ledger"] as? [String: Any]) ?? [:]
        let bridgeOn = (snap["bridge_on"] as? Bool) == true
        let bridge = (snap["bridge"] as? String) ?? ""
        let events = (snap["events_tail"] as? [[String: Any]]) ?? []

        var blocks: [NSView] = []
        var totalH: CGFloat = 12

        // Title row
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 40))
        head.addSubview(Self.label("Workflow dashboard",
            frame: NSRect(x: 0, y: 16, width: 240, height: 20), bold: true, size: 16))
        head.addSubview(Self.label(bridgeOn ? "Bridge live" : "Bridge idle",
            frame: NSRect(x: boxW - 120, y: 18, width: 120, height: 16), size: 11, secondary: true))
        blocks.append(head)
        totalH += 48

        // Metric tiles (2×2 style row)
        let rounds = ledger["rounds"] as? Int ?? 0
        let rate = ledger["accept_rate"] as? Double ?? 0
        let streak = ledger["reject_streak"] as? Int ?? 0
        var openJobs = 0
        var agents = 0
        for t in teams {
            openJobs += (t["jobs"] as? [String: Any]).flatMap { ($0["counts"] as? [String: Any])?["open"] as? Int } ?? 0
            agents += ((t["workers"] as? [[String: Any]])?.count ?? 0) + 1
        }
        let gap: CGFloat = 10
        let tileW = (boxW - gap) / 2
        let metrics = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 148))
        let tiles: [(String, String, String)] = [
            ("Open jobs", "\(openJobs)", "queued · notified · running"),
            ("Accept rate", "\(Int(rate * 100))%", "\(rounds) verdict rounds"),
            ("Agents", "\(agents)", "\(teams.count) team\(teams.count == 1 ? "" : "s")"),
            ("Reject streak", "\(streak)", bridge.isEmpty ? "—" : String(bridge.prefix(28))),
        ]
        for (i, t) in tiles.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = CGFloat(col) * (tileW + gap)
            let y = CGFloat(1 - row) * (70 + gap)
            let tile = NSView(frame: NSRect(x: x, y: y, width: tileW, height: 70))
            PongTheme.applyMetricCard(tile)
            // accent top hairline
            let accent = NSView(frame: NSRect(x: 0, y: 68, width: tileW, height: 2))
            accent.wantsLayer = true
            accent.layer?.backgroundColor = (i == 0 ? PongTheme.accent : (i == 1 ? PongTheme.live : PongTheme.borderStrong)).cgColor
            tile.addSubview(accent)
            tile.addSubview(Self.label(t.0, frame: NSRect(x: 12, y: 44, width: tileW - 24, height: 14), size: 10, secondary: true))
            let val = Self.label(t.1, frame: NSRect(x: 12, y: 18, width: tileW - 24, height: 24), bold: true, size: 22)
            tile.addSubview(val)
            tile.addSubview(Self.label(t.2, frame: NSRect(x: 12, y: 4, width: tileW - 24, height: 12), size: 9, secondary: true))
            metrics.addSubview(tile)
        }
        blocks.append(metrics)
        totalH += 158

        // Recent executions
        let showEvents = Array(events.suffix(6).reversed())
        let execH: CGFloat = 36 + CGFloat(max(showEvents.count, 1)) * 28
        let exec = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: execH))
        PongTheme.applyCard(exec)
        exec.addSubview(Self.label("Recent activity",
            frame: NSRect(x: 14, y: execH - 28, width: 200, height: 18), bold: true, size: 13))
        if showEvents.isEmpty {
            exec.addSubview(Self.label("No events yet — create a job from the conductor.",
                frame: NSRect(x: 14, y: 14, width: boxW - 28, height: 16), size: 11, secondary: true))
        } else {
            var ey = execH - 48
            for e in showEvents {
                let t = (e["type"] as? String) ?? "event"
                let jid = (e["job_id"] as? String) ?? ""
                let st = (e["status"] as? String) ?? (e["verdict"] as? String) ?? ""
                let line = [t, jid, st].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                let row = NSView(frame: NSRect(x: 10, y: ey, width: boxW - 20, height: 24))
                row.wantsLayer = true
                row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                row.layer?.cornerRadius = 8
                let pill = NSView(frame: NSRect(x: 8, y: 6, width: 6, height: 12))
                pill.wantsLayer = true
                pill.layer?.cornerRadius = 3
                pill.layer?.backgroundColor = PongTheme.accent.cgColor
                row.addSubview(pill)
                row.addSubview(Self.label(line,
                    frame: NSRect(x: 22, y: 4, width: boxW - 50, height: 16), size: 10, secondary: true))
                exec.addSubview(row)
                ey -= 28
            }
        }
        blocks.append(exec)
        totalH += execH + 12

        // Per-team open jobs
        for team in teams {
            let session = (team["session"] as? String) ?? "?"
            let display = (team["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let cond = team["conductor"] as? [String: Any]
            let condLabel = (cond?["label"] as? String) ?? "Conductor"
            let jobs = team["jobs"] as? [String: Any] ?? [:]
            let openList = (jobs["open"] as? [[String: Any]]) ?? []
            let openN = (jobs["counts"] as? [String: Any])?["open"] as? Int ?? openList.count
            let workers = (team["workers"] as? [[String: Any]]) ?? []
            let h: CGFloat = 56 + CGFloat(max(openList.count, 1)) * 28 + CGFloat(workers.count) * 16
            let c = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: h))
            PongTheme.applyCard(c, accentBorder: true)
            c.addSubview(Self.label(display,
                frame: NSRect(x: 14, y: h - 26, width: boxW - 40, height: 18), bold: true, size: 13))
            c.addSubview(Self.label("\(condLabel)  ·  \(openN) open  ·  \(workers.count) workers",
                frame: NSRect(x: 14, y: h - 42, width: boxW - 40, height: 14), size: 10, secondary: true))
            var ly = h - 56
            for w in workers.prefix(4) {
                let lab = (w["label"] as? String) ?? "?"
                let hint = (w["status_hint"] as? String) ?? "idle"
                let sk = PongTheme.statusKind(hint)
                ly -= 16
                c.addSubview(Self.label("\(lab)  \(sk.label)",
                    frame: NSRect(x: 14, y: ly, width: boxW - 28, height: 14), size: 10, secondary: true))
            }
            if openList.isEmpty {
                ly -= 28
                c.addSubview(Self.label("No open jobs — pong job create from conductor",
                    frame: NSRect(x: 14, y: ly, width: boxW - 28, height: 18), size: 10, secondary: true))
            } else {
                for j in openList.prefix(6) {
                    ly -= 28
                    let st = (j["status"] as? String) ?? "?"
                    let prev = (j["task_preview"] as? String) ?? (j["id"] as? String) ?? ""
                    let row = NSView(frame: NSRect(x: 10, y: ly, width: boxW - 20, height: 24))
                    row.wantsLayer = true
                    row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                    row.layer?.cornerRadius = 8
                    let sk = PongTheme.statusKind(st)
                    let badge = NSTextField(labelWithString: sk.label)
                    badge.font = PongTheme.font(9, weight: .bold)
                    badge.textColor = sk.color
                    badge.frame = NSRect(x: 8, y: 4, width: 64, height: 16)
                    badge.isBordered = false
                    badge.backgroundColor = .clear
                    row.addSubview(badge)
                    row.addSubview(Self.label(prev,
                        frame: NSRect(x: 78, y: 4, width: boxW - 110, height: 16), size: 10, secondary: true))
                    c.addSubview(row)
                }
            }
            blocks.append(c)
            totalH += h + 12
        }

        let contentH = max(missionScroll.contentSize.height, totalH + 24)
        missionList.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for b in blocks {
            y -= b.frame.height
            b.setFrameOrigin(NSPoint(x: 0, y: y))
            missionList.addSubview(b)
            y -= 10
        }
        let mcv = missionScroll.contentView
        mcv.scroll(to: NSPoint(x: 0, y: max(0, contentH - mcv.bounds.height)))
        missionScroll.reflectScrolledClipView(mcv)
    }

    // MARK: - Actions

    @objc private func showTeamsPressed(_ sender: NSButton) {
        TeamsManagerPanel.shared.show { [weak self] in self?.refreshUI() }
    }

    @objc private func newPairPressed(_ sender: NSButton) {
        guard let (conductor, workers) = AppDelegate.pickTeamLaunch() else {
            refreshUI()
            return
        }
        if workers.isEmpty { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let name = Pairing.startFresh(workers: workers, conductor: conductor)
            usleep(200_000)
            DispatchQueue.main.async {
                self.selectedSession = name
                self.selectTab(.teams, animated: true)
                self.refreshUI()
                Self.showPairPersistTip(name)
            }
        }
    }

    @objc private func linkPressed(_ sender: NSButton) {
        guide.startLink(parent: self)
    }

    @objc private func refreshPressed(_ sender: NSButton) { refreshUI() }

    @objc private func closePressed(_ sender: NSButton) {
        guide.closeGuide()
        refreshTimer?.invalidate()
        refreshTimer = nil
        window?.close()
    }

    static func showPairPersistTip(_ name: String) {
        let flag = Pong.stateDir + "/dont-remind-pair-persist"
        guard !FileManager.default.fileExists(atPath: flag) else { return }
        let label = name.isEmpty ? "this team" : name
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Team stays connected"
        alert.informativeText =
            "“\(label)” stays linked until Kill.\n\n" +
            "Canvas: drag agents, double-click to Front.\n" +
            "Jobs: pong job create · paste optional."
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Don't remind me")
        if alert.runModal() == .alertSecondButtonReturn {
            try? "1\n".write(toFile: flag, atomically: true, encoding: .utf8)
        }
    }
}

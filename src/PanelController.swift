import AppKit

/// Lasting control panel: left rail + primary stage (Canvas · Mission · Setup).
/// Design: docs/UI-VISION.md — orchestration surface, not a list form.
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    // Window
    private var window: NSWindow?
    private var root: NSView!

    // Chrome
    private var topBar: NSView!
    private var brandLabel: NSTextField!
    private var teamPopup: NSPopUpButton!
    private var statusPill: NSView!
    private var statusDot: NSView!
    private var statusText: NSTextField!
    private var refreshBtn: NSButton!

    // Rail
    private var rail: NSView!
    private var railCanvas: NSButton!
    private var railMission: NSButton!
    private var railSetup: NSButton!

    // Stage
    private var stage: NSView!
    private var canvasPage: NSView!
    private var canvasScroll: NSScrollView!
    private var canvas: AgentCanvasView!
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
    private var poll: Timer?
    private let guide = LinkGuideController()

    private let railW: CGFloat = 64
    private let topH: CGFloat = 52
    private let titlebarLift: CGFloat = 30
    private let trafficInset: CGFloat = 76
    private let minSize = NSSize(width: 720, height: 520)
    private let defaultSize = NSSize(width: 960, height: 680)

    enum Destination: Int { case canvas = 0, mission = 1, setup = 2 }

    // MARK: Public

    func show() {
        if window == nil { build() }
        reload()
        startPoll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshUI() { reload() }

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
        win.title = "Pong"
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
        buildRail()
        buildStage()
        root.addSubview(topBar)
        root.addSubview(rail)
        root.addSubview(stage)

        win.contentView = root
        window = win
        layoutAll()
        go(.canvas)
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

        // Rail full height below top bar
        let bodyH = topY
        rail.frame = NSRect(x: 0, y: 0, width: railW, height: bodyH)
        layoutRail(height: bodyH)

        // Stage
        stage.frame = NSRect(x: railW, y: 0, width: W - railW, height: bodyH)
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

        brandLabel = Self.label("Pong", frame: .zero, bold: true, size: 16)
        topBar.addSubview(brandLabel)

        teamPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        teamPopup.target = self
        teamPopup.action = #selector(teamChanged)
        teamPopup.bezelStyle = .texturedRounded
        teamPopup.font = PongTheme.font(12, weight: .medium)
        topBar.addSubview(teamPopup)

        statusPill = NSView(frame: .zero)
        PongTheme.applyCard(statusPill)
        statusPill.layer?.cornerRadius = 14
        statusDot = NSView(frame: NSRect(x: 10, y: 9, width: 8, height: 8))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusPill.addSubview(statusDot)
        statusText = Self.label("Idle", frame: NSRect(x: 24, y: 4, width: 120, height: 18), size: 11, secondary: true)
        statusText.maximumNumberOfLines = 1
        statusText.lineBreakMode = .byTruncatingTail
        statusPill.addSubview(statusText)
        topBar.addSubview(statusPill)

        refreshBtn = iconTextButton("↻", #selector(reloadPressed))
        topBar.addSubview(refreshBtn)

        let line = NSView(frame: .zero)
        line.identifier = NSUserInterfaceItemIdentifier("topline")
        line.wantsLayer = true
        line.layer?.backgroundColor = PongTheme.border.cgColor
        topBar.addSubview(line)
    }

    private func layoutTopBar(width W: CGFloat) {
        let left = trafficInset
        brandLabel.frame = NSRect(x: left, y: 14, width: 64, height: 22)
        teamPopup.frame = NSRect(x: left + 72, y: 12, width: min(240, W * 0.28), height: 28)
        statusPill.frame = NSRect(x: W - 200, y: 12, width: 148, height: 28)
        refreshBtn.frame = NSRect(x: W - 44, y: 12, width: 28, height: 28)
        for v in topBar.subviews where v.identifier?.rawValue == "topline" {
            v.frame = NSRect(x: 0, y: 0, width: W, height: 1)
        }
    }

    // MARK: Rail

    private func buildRail() {
        rail = NSView(frame: .zero)
        rail.wantsLayer = true
        rail.layer?.backgroundColor = PongTheme.bgInput.cgColor

        railCanvas = railButton("◎", "Canvas", tag: 0)
        railMission = railButton("▦", "Mission", tag: 1)
        railSetup = railButton("⚙", "Setup", tag: 2)
        rail.addSubview(railCanvas)
        rail.addSubview(railMission)
        rail.addSubview(railSetup)

        let edge = NSView(frame: .zero)
        edge.identifier = NSUserInterfaceItemIdentifier("railedge")
        edge.wantsLayer = true
        edge.layer?.backgroundColor = PongTheme.border.cgColor
        rail.addSubview(edge)
    }

    private func railButton(_ symbol: String, _ tip: String, tag: Int) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = ""
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.tag = tag
        b.toolTip = tip
        b.target = self
        b.action = #selector(railPressed(_:))
        b.attributedTitle = NSAttributedString(string: symbol, attributes: [
            .foregroundColor: PongTheme.textSecondary,
            .font: PongTheme.font(18, weight: .medium),
            .paragraphStyle: centered(),
        ])
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
        for v in rail.subviews where v.identifier?.rawValue == "railedge" {
            v.frame = NSRect(x: railW - 1, y: 0, width: 1, height: H)
        }
    }

    private func styleRail() {
        styleRailBtn(railCanvas, on: selected == .canvas)
        styleRailBtn(railMission, on: selected == .mission)
        styleRailBtn(railSetup, on: selected == .setup)
    }

    private func styleRailBtn(_ b: NSButton, on: Bool) {
        b.layer?.backgroundColor = (on ? PongTheme.tabSelected : NSColor.clear).cgColor
        let symbols = [0: "◎", 1: "▦", 2: "⚙"]
        let s = symbols[b.tag] ?? "·"
        b.attributedTitle = NSAttributedString(string: s, attributes: [
            .foregroundColor: on ? PongTheme.accent : PongTheme.textSecondary,
            .font: PongTheme.font(18, weight: on ? .semibold : .medium),
            .paragraphStyle: centered(),
        ])
    }

    // MARK: Stage pages

    private func buildStage() {
        stage = NSView(frame: .zero)
        stage.wantsLayer = true
        stage.layer?.backgroundColor = PongTheme.bg.cgColor

        // Canvas page
        canvasPage = NSView(frame: .zero)
        canvasScroll = NSScrollView(frame: .zero)
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.borderType = .noBorder
        canvasScroll.drawsBackground = false
        canvasScroll.backgroundColor = .clear
        canvas = AgentCanvasView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1100))
        canvas.onFront = { [weak self] m in self?.frontModel(m) }
        canvas.onKill = { [weak self] m in self?.killModel(m) }
        canvas.onOptions = { [weak self] m in
            TeamOptionsSheetController.shared.show(for: m.session) { self?.reload() }
        }
        canvas.onPerms = { [weak self] m in
            PermissionsSheetController.shared.show(for: m.session, workerId: m.id) { self?.reload() }
        }
        canvas.onFocus = { m in
            TeamFocusController.shared.show(session: m.session)
        }
        canvas.onAddWorker = { [weak self] m in
            self?.addWorker(to: m.session)
        }
        canvas.onDragStateChanged = { [weak self] dragging in
            self?.canvasDragging = dragging
            self?.canvasScroll.hasVerticalScroller = !dragging
            self?.canvasScroll.hasHorizontalScroller = !dragging
        }
        canvasScroll.documentView = canvas
        canvasPage.addSubview(canvasScroll)

        canvasToolbar = glassBar()
        canvasPage.addSubview(canvasToolbar)
        canvasToolbar.addSubview(pillButton("Fit layout", #selector(fitPressed)))
        canvasToolbar.addSubview(pillButton("Link terminals", #selector(linkPressed)))
        canvasToolbar.addSubview(accentButton("New team", #selector(newTeamPressed)))

        canvasEmpty = emptyState(
            title: "No teams yet",
            body: "Create a team to place a conductor and workers on the canvas.\nYou can also link terminals you already have open.",
            cta: "New team",
            action: #selector(newTeamPressed)
        )
        canvasPage.addSubview(canvasEmpty)
        stage.addSubview(canvasPage)

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
        canvasScroll.frame = b.insetBy(dx: 12, dy: 12)
        canvasScroll.frame.size.height = max(100, b.height - 24)
        // Floating toolbar centered bottom
        let tw: CGFloat = 340
        canvasToolbar.frame = NSRect(x: (b.width - tw) / 2, y: 20, width: tw, height: 44)
        layoutGlassBar(canvasToolbar)
        canvasEmpty.frame = NSRect(x: (b.width - 360) / 2, y: (b.height - 160) / 2, width: 360, height: 160)
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
        v.layer?.backgroundColor = PongTheme.bgElevated.withAlphaComponent(0.92).cgColor
        v.layer?.cornerRadius = 22
        v.layer?.borderWidth = 1
        v.layer?.borderColor = PongTheme.border.cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.35
        v.layer?.shadowRadius = 16
        v.layer?.shadowOffset = CGSize(width: 0, height: -2)
        return v
    }

    private func layoutGlassBar(_ bar: NSView) {
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        guard !buttons.isEmpty else { return }
        let pad: CGFloat = 8
        var x: CGFloat = 12
        for (i, b) in buttons.enumerated() {
            let w: CGFloat = i == buttons.count - 1 ? 100 : 100
            b.frame = NSRect(x: x, y: 8, width: w, height: 28)
            x += w + pad
        }
    }

    // MARK: Navigation

    @objc private func railPressed(_ sender: NSButton) {
        guard let d = Destination(rawValue: sender.tag) else { return }
        go(d)
    }

    private func go(_ d: Destination) {
        selected = d
        styleRail()
        canvasPage.isHidden = d != .canvas
        missionPage.isHidden = d != .mission
        setupPage.isHidden = d != .setup
        reload()
    }

    // MARK: Data reload

    @objc private func reloadPressed() { reload() }

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

    private func startPoll() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.canvasDragging { return }
            self.updateStatus()
            if self.selected == .mission { self.paintMission() }
            if self.selected == .canvas { self.refreshCanvas(light: true) }
        }
    }

    private func updateStatus() {
        let n = PairState.listPairs().count
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
    }

    @objc private func teamChanged() {
        selectedSession = teamPopup.selectedItem?.representedObject as? String
        refreshCanvas()
    }

    // MARK: Canvas

    private func refreshCanvas(light: Bool = false) {
        if canvasDragging { return }
        let pairs = PairState.listPairs()
        canvasEmpty.isHidden = !pairs.isEmpty
        canvasScroll.isHidden = pairs.isEmpty
        canvasToolbar.isHidden = pairs.isEmpty
        guard !pairs.isEmpty else { return }

        let multi = selectedSession == "__all__" || (selectedSession == nil && pairs.count > 1)
        let showPairs: [String] = multi ? pairs : [selectedSession ?? pairs[0]].compactMap { $0 }

        let size = NSSize(
            width: max(1400, canvasScroll.contentSize.width + 400 + CGFloat(max(0, showPairs.count - 1)) * 520),
            height: max(1000, canvasScroll.contentSize.height + 320)
        )
        if !light { canvas.setFrameSize(size) }

        let snap = snapshot()
        var models: [AgentNodeModel] = []
        let posMap = CanvasLayout.positions(for: multi ? nil : showPairs.first)

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
                if !brief.isEmpty { return String(brief.prefix(90)) }
                if !rootPath.isEmpty { return rootPath }
                return "Orchestrates · verifies claims"
            }()
            let cKey = CanvasLayout.key(session: session, nodeId: condId, multi: multi)
            let cOrigin = posMap[cKey] ?? posMap[condId]
                ?? CanvasLayout.defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size, multi: multi)
            let cAccent = TerminalTheme.Colors.from(entry["colors"])?.asNSColors.hi ?? PongTheme.blue
            models.append(AgentNodeModel(
                session: session, id: condId, role: "conductor",
                title: condLabel, subtitle: "\(condType) · orchestrator",
                detail: detail, status: stowed ? "hidden" : "live",
                teamLabel: multi ? display : "",
                accent: cAccent, origin: cOrigin
            ))

            let ws = Workers.list(from: entry)
            for (i, w) in ws.enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let lab = (w["label"] as? String) ?? wid
                let typ = (w["type"] as? String) ?? "worker"
                var status = "idle"
                var wdetail = "Implements assigned work"
                if let teams = snap?["teams"] as? [[String: Any]],
                   let team = teams.first(where: { ($0["session"] as? String) == session }),
                   let workers = team["workers"] as? [[String: Any]],
                   let match = workers.first(where: { ($0["id"] as? String) == wid }) {
                    status = (match["status_hint"] as? String) ?? status
                    let oj = match["open_jobs"] as? Int ?? 0
                    if oj > 0 { status = "busy"; wdetail = "\(oj) open job\(oj == 1 ? "" : "s")" }
                }
                let wKey = CanvasLayout.key(session: session, nodeId: wid, multi: multi)
                let origin = posMap[wKey] ?? posMap[wid]
                    ?? CanvasLayout.defaultPosition(teamIndex: ti, role: "worker", workerIndex: i, canvas: size, multi: multi)
                let accent = TerminalTheme.Colors.from(w["colors"])?.asNSColors.hi ?? PongTheme.magenta
                models.append(AgentNodeModel(
                    session: session, id: wid, role: "worker",
                    title: lab, subtitle: typ, detail: wdetail, status: status,
                    teamLabel: multi ? display : "",
                    accent: accent, origin: origin
                ))
            }

            // + add worker handle near orchestrator
            let addId = "add"
            let addKey = CanvasLayout.key(session: session, nodeId: addId, multi: multi)
            let addOrigin = posMap[addKey]
                ?? CGPoint(x: cOrigin.x + 200, y: cOrigin.y + 40)
            models.append(AgentNodeModel(
                session: session, id: addId, role: "add",
                title: "+", subtitle: "worker", detail: "Add worker",
                status: "idle", teamLabel: "", accent: PongTheme.magenta, origin: addOrigin
            ))
        }

        canvas.reload(models: models, multiTeam: multi)
    }

    // MARK: - Mission dashboard

    private func snapshot() -> [String: Any]? {
        let out = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot --compact 2>/dev/null | head -c 500000")
        if let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["contract_version"] != nil {
            lastSnapshot = obj
            return obj
        }
        let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if !file.isEmpty { lastSnapshot = file; return file }
        return lastSnapshot
    }

    private func paintMission() {
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
            yCursor += h + 14
        }

        // Header
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 48))
        head.addSubview(Self.label("Mission", frame: NSRect(x: 0, y: 20, width: 200, height: 24), bold: true, size: 22))
        let bridgeLbl = Self.label(bridgeOn ? "Control plane connected" : "No active bridge",
            frame: NSRect(x: 0, y: 2, width: boxW, height: 16), size: 12, secondary: true)
        head.addSubview(bridgeLbl)
        push(head, 48)

        // Metrics 4-up
        var openJobs = 0, agentCount = 0
        for t in teams {
            openJobs += (t["jobs"] as? [String: Any]).flatMap { ($0["counts"] as? [String: Any])?["open"] as? Int } ?? 0
            agentCount += 1 + ((t["workers"] as? [[String: Any]])?.count ?? 0)
        }
        let rounds = ledger["rounds"] as? Int ?? 0
        let rate = Int(((ledger["accept_rate"] as? Double) ?? 0) * 100)
        let streak = ledger["reject_streak"] as? Int ?? 0
        let metricsH: CGFloat = 100
        let metrics = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: metricsH))
        let titles = ["Open jobs", "Accept rate", "Agents", "Reject streak"]
        let values = ["\(openJobs)", "\(rate)%", "\(agentCount)", "\(streak)"]
        let subs = ["in flight", "\(rounds) rounds", "\(teams.count) teams", "current"]
        let gap: CGFloat = 12
        let tw = (boxW - gap * 3) / 4
        for i in 0..<4 {
            let tile = NSView(frame: NSRect(x: CGFloat(i) * (tw + gap), y: 0, width: tw, height: metricsH))
            PongTheme.applyFloating(tile)
            tile.layer?.cornerRadius = 14
            let top = NSView(frame: NSRect(x: 0, y: metricsH - 3, width: tw, height: 3))
            top.wantsLayer = true
            let accentBar: NSColor = [PongTheme.blue, PongTheme.magenta, PongTheme.blue, PongTheme.orange][i]
            top.layer?.backgroundColor = accentBar.cgColor
            top.layer?.cornerRadius = 1
            tile.addSubview(top)
            tile.addSubview(Self.label(titles[i], frame: NSRect(x: 14, y: 70, width: tw - 28, height: 14), size: 10, secondary: true))
            tile.addSubview(Self.label(values[i], frame: NSRect(x: 14, y: 32, width: tw - 28, height: 32), bold: true, size: 26))
            tile.addSubview(Self.label(subs[i], frame: NSRect(x: 14, y: 12, width: tw - 28, height: 14), size: 10, secondary: true))
            metrics.addSubview(tile)
        }
        push(metrics, metricsH)

        // Activity
        let show = Array(events.suffix(8).reversed())
        let actH: CGFloat = 44 + CGFloat(max(show.count, 1)) * 32
        let act = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: actH))
        PongTheme.applyFloating(act)
        act.addSubview(Self.label("Recent activity", frame: NSRect(x: 16, y: actH - 32, width: 200, height: 18), bold: true, size: 14))
        if show.isEmpty {
            act.addSubview(Self.label("Jobs and verdicts will appear here.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 16), size: 12, secondary: true))
        } else {
            var ey = actH - 52
            for e in show {
                let t = (e["type"] as? String) ?? "event"
                let extra = [(e["job_id"] as? String), (e["status"] as? String), (e["verdict"] as? String)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let row = NSView(frame: NSRect(x: 12, y: ey, width: boxW - 24, height: 28))
                row.wantsLayer = true
                row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                row.layer?.cornerRadius = 8
                let dot = NSView(frame: NSRect(x: 10, y: 10, width: 7, height: 7))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3.5
                dot.layer?.backgroundColor = PongTheme.accent.cgColor
                row.addSubview(dot)
                row.addSubview(Self.label("\(t)  \(extra)",
                    frame: NSRect(x: 26, y: 6, width: boxW - 60, height: 16), size: 11, secondary: true))
                act.addSubview(row)
                ey -= 32
            }
        }
        push(act, actH)

        // Teams job boards
        for team in teams {
            let session = (team["session"] as? String) ?? "?"
            let display = (team["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let openList = ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            let workers = (team["workers"] as? [[String: Any]]) ?? []
            let condLabel = ((team["conductor"] as? [String: Any])?["label"] as? String) ?? "Conductor"
            let h: CGFloat = 64 + CGFloat(max(openList.count, 1)) * 30 + 8
            let card = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: h))
            PongTheme.applyCard(card, accentBorder: openList.isEmpty == false)
            card.addSubview(Self.label(display, frame: NSRect(x: 16, y: h - 28, width: boxW - 40, height: 18), bold: true, size: 14))
            card.addSubview(Self.label("\(condLabel) · \(workers.count) workers · \(openList.count) open",
                frame: NSRect(x: 16, y: h - 46, width: boxW - 40, height: 14), size: 11, secondary: true))
            var ly = h - 64
            if openList.isEmpty {
                card.addSubview(Self.label("Queue empty",
                    frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 16), size: 12, secondary: true))
            } else {
                for j in openList.prefix(8) {
                    ly -= 30
                    let st = (j["status"] as? String) ?? "?"
                    let prev = (j["task_preview"] as? String) ?? ""
                    let sk = PongTheme.statusKind(st)
                    let row = NSView(frame: NSRect(x: 12, y: ly, width: boxW - 24, height: 26))
                    row.wantsLayer = true
                    row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                    row.layer?.cornerRadius = 8
                    let badge = NSTextField(labelWithString: sk.label)
                    badge.font = PongTheme.font(9, weight: .bold)
                    badge.textColor = sk.color
                    badge.isBordered = false
                    badge.backgroundColor = .clear
                    badge.frame = NSRect(x: 10, y: 5, width: 70, height: 16)
                    row.addSubview(badge)
                    row.addSubview(Self.label(prev, frame: NSRect(x: 86, y: 5, width: boxW - 130, height: 16), size: 11, secondary: true))
                    card.addSubview(row)
                }
            }
            push(card, h)
        }

        if teams.isEmpty {
            let empty = emptyState(title: "Nothing to measure yet",
                                   body: "Start a team on the canvas. Jobs and verdicts will show up here.",
                                   cta: "Go to canvas", action: #selector(goCanvas))
            empty.frame = NSRect(x: 0, y: 0, width: min(400, boxW), height: 150)
            push(empty, 150)
        }

        let contentH = max(missionScroll.contentSize.height, yCursor + 40)
        missionBody.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for (v, h) in blocks {
            y -= h
            v.setFrameOrigin(NSPoint(x: 0, y: y))
            v.setFrameSize(NSSize(width: v.frame.width == 0 ? boxW : v.frame.width, height: h))
            // fix empty width
            if v.frame.width < boxW && !(v.subviews.isEmpty && h == 150) {
                // metrics/act already sized
            }
            missionBody.addSubview(v)
            y -= 14
        }
        let cv = missionScroll.contentView
        cv.scroll(to: NSPoint(x: 0, y: max(0, contentH - cv.bounds.height)))
        missionScroll.reflectScrolledClipView(cv)
    }

    @objc private func goCanvas() { go(.canvas) }

    // MARK: Setup

    private func paintSetup() {
        setupBody.subviews.forEach { $0.removeFromSuperview() }
        let W: CGFloat = max(420, setupScroll.contentSize.width > 20 ? setupScroll.contentSize.width - 8 : 480)
        var y: CGFloat = 520
        setupBody.setFrameSize(NSSize(width: W, height: y))

        let title = Self.label("Setup", frame: NSRect(x: 0, y: y - 36, width: 200, height: 28), bold: true, size: 22)
        setupBody.addSubview(title)
        y -= 56
        setupBody.addSubview(Self.label("Start a team or connect terminals you already use.",
            frame: NSRect(x: 0, y: y, width: W - 20, height: 18), size: 13, secondary: true))
        y -= 36

        let card1 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "New team",
            body: "Pick a conductor (Grok recommended) and workers. Opens real terminal sessions on a shared canvas.",
            button: "Create team",
            action: #selector(newTeamPressed)
        )
        setupBody.addSubview(card1)
        y -= 136

        let card2 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "Link terminals",
            body: "Point Pong at windows that are already running — keep model, chat, and resume as-is.",
            button: "Link…",
            action: #selector(linkPressed)
        )
        setupBody.addSubview(card2)
        y -= 136

        let n = SavedTeams.loadAll().count
        if n > 0 {
            let card3 = actionCard(
                frame: NSRect(x: 0, y: y - 100, width: W - 20, height: 100),
                title: "Saved teams",
                body: "\(n) saved layout\(n == 1 ? "" : "s"). Open, duplicate, or delete.",
                button: "Manage",
                action: #selector(showTeamsPressed)
            )
            setupBody.addSubview(card3)
            y -= 118
        }

        let note = NSView(frame: NSRect(x: 0, y: y - 80, width: W - 20, height: 80))
        PongTheme.applyCard(note)
        note.addSubview(Self.label("Control plane", frame: NSRect(x: 16, y: 48, width: 200, height: 16), bold: true, size: 12))
        note.addSubview(Self.label("pong snapshot · pong job create · pong check\nJobs are authoritative; canvas is how you see the team.",
            frame: NSRect(x: 16, y: 12, width: W - 52, height: 36), size: 11, secondary: true))
        setupBody.addSubview(note)
    }

    private func actionCard(frame: NSRect, title: String, body: String, button: String, action: Selector) -> NSView {
        let v = NSView(frame: frame)
        PongTheme.applyFloating(v)
        // Stacked: title (top) → body → button (bottom-right) — no overlap
        let titleL = Self.label(title, frame: NSRect(x: 20, y: frame.height - 36, width: frame.width - 40, height: 22), bold: true, size: 15)
        v.addSubview(titleL)
        let bodyL = Self.label(body, frame: NSRect(x: 20, y: 48, width: frame.width - 140, height: frame.height - 92), size: 12, secondary: true)
        bodyL.maximumNumberOfLines = 3
        v.addSubview(bodyL)
        let b = accentButton(button, action)
        b.frame = NSRect(x: frame.width - 124, y: 16, width: 104, height: 32)
        v.addSubview(b)
        return v
    }

    // MARK: Buttons

    private func accentButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.accent.cgColor
        b.layer?.cornerRadius = 10
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: PongTheme.font(12, weight: .semibold),
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
        b.layer?.backgroundColor = PongTheme.bgHover.cgColor
        b.layer?.cornerRadius = 10
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongTheme.border.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.font(11, weight: .medium),
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
        guard let (conductor, workers) = AppDelegate.pickTeamLaunch() else { return }
        guard !workers.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let name = Pairing.startFresh(workers: workers, conductor: conductor)
            usleep(200_000)
            DispatchQueue.main.async {
                self.selectedSession = name
                self.go(.canvas)
                Self.showPairPersistTip(name)
            }
        }
    }

    @objc private func linkPressed() {
        guide.startLink(parent: self)
    }

    @objc private func showTeamsPressed() {
        TeamsManagerPanel.shared.show { [weak self] in self?.reload() }
    }

    @objc private func fitPressed() {
        let multi = selectedSession == "__all__"
        let pairs = PairState.listPairs()
        let show = multi ? pairs : [selectedSession].compactMap { $0 }.filter { $0 != "__all__" }
        guard !show.isEmpty else { return }
        let size = canvas.bounds.size.width > 0 ? canvas.bounds.size : NSSize(width: 1400, height: 1000)
        var pos: [String: CGPoint] = [:]
        for (ti, session) in show.enumerated() {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
            let ck = CanvasLayout.key(session: session, nodeId: condId, multi: multi)
            let cOrigin = CanvasLayout.defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size, multi: multi)
            pos[ck] = cOrigin
            if !multi { pos[condId] = cOrigin }
            for (i, w) in Workers.list(from: entry).enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let wk = CanvasLayout.key(session: session, nodeId: wid, multi: multi)
                let o = CanvasLayout.defaultPosition(teamIndex: ti, role: "worker", workerIndex: i, canvas: size, multi: multi)
                pos[wk] = o
                if !multi { pos[wid] = o }
            }
            let ak = CanvasLayout.key(session: session, nodeId: "add", multi: multi)
            pos[ak] = CGPoint(x: cOrigin.x + 200, y: cOrigin.y + 40)
        }
        CanvasLayout.save(session: multi ? nil : show.first, positions: pos, multi: multi)
        refreshCanvas()
    }

    private func frontModel(_ m: AgentNodeModel) {
        if m.role == "worker" || m.id.hasPrefix("w") {
            Workers.frontWorker(pair: m.session, workerId: m.id)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(m.session) }
        }
    }

    private func killModel(_ m: AgentNodeModel) {
        if m.role == "worker" || m.id.hasPrefix("w") {
            let a = NSAlert()
            a.messageText = "Remove worker \(m.id)?"
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            _ = Workers.removeWorker(pair: m.session, workerId: m.id)
            reload()
        } else {
            let a = NSAlert()
            a.messageText = "Kill team?"
            a.informativeText = m.session
            a.addButton(withTitle: "Kill")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            Pairing.killPair(m.session)
            selectedSession = nil
            reload()
        }
    }

    private func addWorker(to session: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Add worker"
        a.informativeText = "Launch a new worker CLI into this team."
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
            _ = Workers.addWorker(pair: session, type: wt)
            DispatchQueue.main.async { self.reload() }
        }
    }
}


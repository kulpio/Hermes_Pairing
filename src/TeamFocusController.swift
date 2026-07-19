import AppKit

/// Floating inspector: team activity without replacing the live terminal.
final class TeamFocusController: NSObject {
    static let shared = TeamFocusController()

    private var window: NSWindow?
    private var session: String = ""
    private var body: NSView!
    private var scroll: NSScrollView!
    private let W: CGFloat = 380
    private let H: CGFloat = 480

    func show(session: String) {
        self.session = session
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "Team focus"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = PongTheme.bg
        win.minSize = NSSize(width: 320, height: 360)
        win.setFrameAutosaveName("PongTeamFocus")

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]

        scroll = NSScrollView(frame: root.bounds.insetBy(dx: 12, dy: 36))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        body = NSView(frame: NSRect(x: 0, y: 0, width: W - 24, height: 400))
        scroll.documentView = body
        root.addSubview(scroll)

        win.contentView = root
        window = win
    }

    private func reload() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(300, (scroll.contentSize.width > 0 ? scroll.contentSize.width : W - 24))
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
        let cond = entry["conductor"] as? [String: Any]
        let condLabel = (cond?["label"] as? String) ?? "Orchestrator"
        let workers = Workers.list(from: entry)

        // Snapshot slice
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let teamSnap = ((snap["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == session }
        let openJobs = ((teamSnap?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let events = ((snap["events_tail"] as? [[String: Any]]) ?? [])
            .filter { ($0["session"] as? String) == session || $0["session"] == nil }
            .suffix(12).reversed()

        var y: CGFloat = 20
        var blocks: [NSView] = []

        // Header card
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 100))
        PongTheme.applyFloating(head)
        head.addSubview(PanelController.label(display,
            frame: NSRect(x: 16, y: 64, width: boxW - 32, height: 22), bold: true, size: 16))
        head.addSubview(PanelController.label("\(condLabel) · \(workers.count) workers · \(openJobs.count) open jobs",
            frame: NSRect(x: 16, y: 44, width: boxW - 32, height: 16), size: 11, secondary: true))
        let openAll = makeBtn("Open orchestrator", #selector(openOrch), filled: true)
        openAll.frame = NSRect(x: 16, y: 12, width: 140, height: 28)
        head.addSubview(openAll)
        let refresh = makeBtn("Refresh", #selector(refreshPressed), filled: false)
        refresh.frame = NSRect(x: 164, y: 12, width: 80, height: 28)
        head.addSubview(refresh)
        blocks.append(head)
        y += 114

        // Current queue
        let qH: CGFloat = 40 + CGFloat(max(openJobs.count, 1)) * 30
        let queue = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: qH))
        PongTheme.applyFloating(queue)
        queue.addSubview(PanelController.label("Current actions",
            frame: NSRect(x: 16, y: qH - 28, width: 200, height: 18), bold: true, size: 13))
        if openJobs.isEmpty {
            queue.addSubview(PanelController.label("No open jobs — orchestrator is idle or waiting.",
                frame: NSRect(x: 16, y: 14, width: boxW - 32, height: 16), size: 11, secondary: true))
        } else {
            var ly = qH - 48
            for j in openJobs.prefix(8) {
                let st = (j["status"] as? String) ?? "?"
                let prev = (j["task_preview"] as? String) ?? (j["id"] as? String) ?? ""
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
                badge.frame = NSRect(x: 8, y: 5, width: 64, height: 16)
                row.addSubview(badge)
                row.addSubview(PanelController.label(prev,
                    frame: NSRect(x: 78, y: 5, width: boxW - 110, height: 16), size: 10, secondary: true))
                queue.addSubview(row)
                ly -= 30
            }
        }
        blocks.append(queue)
        y += qH + 14

        // Agents
        let aH: CGFloat = 36 + CGFloat(workers.count + 1) * 40
        let agents = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: aH))
        PongTheme.applyFloating(agents)
        agents.addSubview(PanelController.label("Orchestra",
            frame: NSRect(x: 16, y: aH - 28, width: 200, height: 18), bold: true, size: 13))
        var ay = aH - 48
        // conductor row
        let crow = agentRow(boxW: boxW, y: ay, title: condLabel, sub: "orchestrator", id: "orch")
        agents.addSubview(crow)
        ay -= 40
        for w in workers {
            let wid = (w["id"] as? String) ?? "?"
            let lab = (w["label"] as? String) ?? wid
            let typ = (w["type"] as? String) ?? ""
            let row = agentRow(boxW: boxW, y: ay, title: lab, sub: typ, id: wid)
            agents.addSubview(row)
            ay -= 40
        }
        blocks.append(agents)
        y += aH + 14

        // Recent
        let evList = Array(events)
        let eH: CGFloat = 36 + CGFloat(max(evList.count, 1)) * 28
        let recent = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: eH))
        PongTheme.applyFloating(recent)
        recent.addSubview(PanelController.label("Last actions",
            frame: NSRect(x: 16, y: eH - 28, width: 200, height: 18), bold: true, size: 13))
        if evList.isEmpty {
            recent.addSubview(PanelController.label("No recent events for this team yet.",
                frame: NSRect(x: 16, y: 12, width: boxW - 32, height: 16), size: 11, secondary: true))
        } else {
            var ey = eH - 48
            for e in evList {
                let t = (e["type"] as? String) ?? "event"
                let extra = [(e["job_id"] as? String), (e["status"] as? String), (e["verdict"] as? String)]
                    .compactMap { $0 }.joined(separator: " · ")
                recent.addSubview(PanelController.label("\(t)  \(extra)",
                    frame: NSRect(x: 16, y: ey, width: boxW - 32, height: 16), size: 10, secondary: true))
                ey -= 28
            }
        }
        blocks.append(recent)
        y += eH + 20

        let contentH = max(scroll.contentSize.height, y)
        body.setFrameSize(NSSize(width: boxW, height: contentH))
        var cy = contentH - 8
        for b in blocks {
            cy -= b.frame.height
            b.setFrameOrigin(NSPoint(x: 0, y: cy))
            body.addSubview(b)
            cy -= 14
        }
        window?.title = "Focus · \(display)"
    }

    private func agentRow(boxW: CGFloat, y: CGFloat, title: String, sub: String, id: String) -> NSView {
        let row = NSView(frame: NSRect(x: 12, y: y, width: boxW - 24, height: 34))
        row.wantsLayer = true
        row.layer?.backgroundColor = PongTheme.bgInput.cgColor
        row.layer?.cornerRadius = 10
        row.addSubview(PanelController.label(title,
            frame: NSRect(x: 12, y: 14, width: 140, height: 16), bold: true, size: 12))
        row.addSubview(PanelController.label(sub,
            frame: NSRect(x: 12, y: 2, width: 140, height: 12), size: 9, secondary: true))
        let b = makeBtn("Terminal", #selector(openAgent(_:)), filled: false)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: boxW - 120, y: 5, width: 80, height: 24)
        row.addSubview(b)
        return row
    }

    private func makeBtn(_ title: String, _ sel: Selector, filled: Bool) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        if filled {
            b.layer?.backgroundColor = PongTheme.blue.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white, .font: PongTheme.font(11, weight: .semibold),
            ])
        } else {
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.border.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textPrimary, .font: PongTheme.font(10, weight: .medium),
            ])
        }
        b.target = self
        b.action = sel
        return b
    }

    @objc private func openOrch() {
        DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(self.session) }
    }

    @objc private func openAgent(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "orch" {
            openOrch()
        } else {
            Workers.frontWorker(pair: session, workerId: id)
        }
    }

    @objc private func refreshPressed() { reload() }
}

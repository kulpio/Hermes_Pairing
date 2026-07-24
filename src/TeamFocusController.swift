import AppKit

/// Floating team inspector — digests control-plane activity into a readable task flow.
final class TeamFocusController: NSObject {
    static let shared = TeamFocusController()

    private var window: NSWindow?
    private var session: String = ""
    private var body: NSView!
    private var scroll: NSScrollView!
    private let W: CGFloat = 440
    private let H: CGFloat = 580

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
        win.minSize = NSSize(width: 380, height: 420)
        win.setFrameAutosaveName("PongTeamFocus")

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]

        scroll = NSScrollView(frame: root.bounds.insetBy(dx: 14, dy: 40))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        body = NSView(frame: NSRect(x: 0, y: 0, width: W - 28, height: 500))
        scroll.documentView = body
        root.addSubview(scroll)

        win.contentView = root
        window = win
    }

    private func reload() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(340, scroll.contentSize.width > 20 ? scroll.contentSize.width - 4 : W - 28)

        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
        let cond = entry["conductor"] as? [String: Any]
        let condLabel = (cond?["label"] as? String) ?? "Orchestrator"
        let condType = (cond?["type"] as? String) ?? ""
        let workers = Workers.list(from: entry)
        let brief = (entry["team_brief"] as? String) ?? ""
        let rootPath = (entry["project_root"] as? String) ?? ""

        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let teamSnap = ((snap["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == session }
        let openJobs = ((teamSnap?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let counts = (teamSnap?["jobs"] as? [String: Any])?["counts"] as? [String: Any] ?? [:]
        let recentJobs = ((teamSnap?["jobs"] as? [String: Any])?["recent"] as? [[String: Any]]) ?? []
        let events = ((snap["events_tail"] as? [[String: Any]]) ?? [])
            .filter { ($0["session"] as? String) == session || $0["session"] == nil }

        let ledger = snap["ledger"] as? [String: Any] ?? [:]
        let rejectStreak = ledger["reject_streak"] as? Int ?? 0

        // Derive stage of pipeline
        let stage = digestStage(openJobs: openJobs, workers: workers, events: events, rejectStreak: rejectStreak)

        var blocks: [NSView] = []
        var total: CGFloat = 12

        // —— Header ——
        let headH: CGFloat = brief.isEmpty && rootPath.isEmpty ? 108 : 128
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: headH))
        PongTheme.applyFloating(head)
        head.addSubview(PanelController.label(display,
            frame: NSRect(x: 16, y: headH - 34, width: boxW - 32, height: 22), bold: true, size: 17))
        head.addSubview(PanelController.label("\(condLabel)\(condType.isEmpty ? "" : " · \(condType)") · \(workers.count) worker\(workers.count == 1 ? "" : "s")",
            frame: NSRect(x: 16, y: headH - 54, width: boxW - 32, height: 16), size: 11, secondary: true))
        if !brief.isEmpty {
            head.addSubview(PanelController.label(String(brief.prefix(120)),
                frame: NSRect(x: 16, y: 44, width: boxW - 32, height: 28), size: 11, secondary: true))
        } else if !rootPath.isEmpty {
            head.addSubview(PanelController.label(rootPath,
                frame: NSRect(x: 16, y: 48, width: boxW - 32, height: 16), size: 10, secondary: true))
        }
        let openOrch = btn("Open orchestrator", #selector(openOrch), filled: true)
        openOrch.frame = NSRect(x: 16, y: 12, width: 130, height: 28)
        head.addSubview(openOrch)
        let newJob = btn("New job", #selector(createJobPressed), filled: true)
        newJob.frame = NSRect(x: 154, y: 12, width: 88, height: 28)
        head.addSubview(newJob)
        let ref = btn("Refresh", #selector(refreshPressed), filled: false)
        ref.frame = NSRect(x: 250, y: 12, width: 72, height: 28)
        head.addSubview(ref)
        blocks.append(head)
        total += headH + 14

        // —— Flow digest (story) ——
        let story = flowStory(stage: stage, openCount: openJobs.count, workers: workers, rejectStreak: rejectStreak)
        let storyH: CGFloat = 72
        let storyCard = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: storyH))
        PongTheme.applyFloating(storyCard)
        let accent = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: storyH))
        accent.wantsLayer = true
        accent.layer?.backgroundColor = stage.color.cgColor
        storyCard.addSubview(accent)
        storyCard.addSubview(PanelController.label("What’s happening",
            frame: NSRect(x: 16, y: 46, width: boxW - 32, height: 14), size: 10, secondary: true))
        storyCard.addSubview(PanelController.label(story,
            frame: NSRect(x: 16, y: 12, width: boxW - 36, height: 34), bold: true, size: 13))
        blocks.append(storyCard)
        total += storyH + 14

        // —— Pipeline stages ——
        let stages = pipelineStages(openJobs: openJobs, events: events, rejectStreak: rejectStreak)
        let pipeH: CGFloat = 88
        let pipe = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: pipeH))
        PongTheme.applyFloating(pipe)
        pipe.addSubview(PanelController.label("Task flow",
            frame: NSRect(x: 14, y: pipeH - 26, width: 120, height: 16), bold: true, size: 12))
        let labels = ["Plan", "Assign", "Build", "Verify", "Done"]
        let gap: CGFloat = 6
        let sw = (boxW - 28 - gap * 4) / 5
        for (i, lab) in labels.enumerated() {
            let st = stages[i]
            let x = 14 + CGFloat(i) * (sw + gap)
            let cell = NSView(frame: NSRect(x: x, y: 12, width: sw, height: 46))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 10
            cell.layer?.backgroundColor = st.active ? st.color.withAlphaComponent(0.18).cgColor : PongTheme.bgInput.cgColor
            cell.layer?.borderWidth = st.active ? 1.5 : 1
            cell.layer?.borderColor = st.active ? st.color.cgColor : PongTheme.border.cgColor
            let t = PanelController.label(lab, frame: NSRect(x: 4, y: 22, width: sw - 8, height: 14), bold: st.active, size: 10)
            t.alignment = .center
            if st.active { t.textColor = st.color }
            cell.addSubview(t)
            let sub = PanelController.label(st.caption, frame: NSRect(x: 2, y: 6, width: sw - 4, height: 12), size: 8, secondary: true)
            sub.alignment = .center
            cell.addSubview(sub)
            pipe.addSubview(cell)
            if i < labels.count - 1 {
                let arrow = PanelController.label("→", frame: NSRect(x: x + sw - 2, y: 24, width: gap + 4, height: 14), size: 10, secondary: true)
                pipe.addSubview(arrow)
            }
        }
        blocks.append(pipe)
        total += pipeH + 14

        // —— In flight jobs (digest) ——
        let jobRows = max(openJobs.count, 1)
        let qH: CGFloat = 44 + CGFloat(jobRows) * 52
        let queue = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: qH))
        PongTheme.applyFloating(queue)
        queue.addSubview(PanelController.label("In flight",
            frame: NSRect(x: 16, y: qH - 28, width: 160, height: 18), bold: true, size: 13))
        queue.addSubview(PanelController.label("\(openJobs.count) open · \(counts["done"] as? Int ?? 0) done",
            frame: NSRect(x: boxW - 140, y: qH - 26, width: 124, height: 14), size: 10, secondary: true))
        if openJobs.isEmpty {
            queue.addSubview(PanelController.label("Queue empty. Orchestrator can plan next work or wait for human.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 28), size: 12, secondary: true))
        } else {
            var ly = qH - 48
            for j in openJobs.prefix(6) {
                let st = (j["status"] as? String) ?? "queued"
                let prev = (j["task_preview"] as? String) ?? (j["id"] as? String) ?? ""
                let worker = (j["worker_label"] as? String) ?? (j["worker"] as? String) ?? "?"
                let sk = PongTheme.statusKind(st)
                let row = NSView(frame: NSRect(x: 12, y: ly - 44, width: boxW - 24, height: 48))
                row.wantsLayer = true
                row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                row.layer?.cornerRadius = 12
                row.layer?.borderWidth = 1
                row.layer?.borderColor = sk.soft.cgColor
                let badge = pill(sk.label, color: sk.color, soft: sk.soft)
                badge.frame = NSRect(x: 10, y: 26, width: 72, height: 18)
                row.addSubview(badge)
                row.addSubview(PanelController.label("→ \(worker)",
                    frame: NSRect(x: 90, y: 26, width: boxW - 130, height: 16), size: 10, secondary: true))
                row.addSubview(PanelController.label(prev,
                    frame: NSRect(x: 12, y: 6, width: boxW - 48, height: 16), size: 11))
                queue.addSubview(row)
                ly -= 52
            }
        }
        blocks.append(queue)
        total += qH + 14

        // —— Orchestra ——
        let aH: CGFloat = 40 + CGFloat(workers.count + 1) * 44
        let orch = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: aH))
        PongTheme.applyFloating(orch)
        orch.addSubview(PanelController.label("Orchestra",
            frame: NSRect(x: 16, y: aH - 28, width: 160, height: 18), bold: true, size: 13))
        var ay = aH - 52
        orch.addSubview(agentRow(boxW: boxW, y: ay, title: condLabel, sub: "orchestrator · plans & verifies",
                                  id: "orch", accent: PongTheme.blue))
        ay -= 44
        for w in workers {
            let wid = (w["id"] as? String) ?? "?"
            let lab = (w["label"] as? String) ?? wid
            let typ = (w["type"] as? String) ?? "worker"
            var hint = "ready"
            if let ws = teamSnap?["workers"] as? [[String: Any]],
               let match = ws.first(where: { ($0["id"] as? String) == wid }) {
                hint = (match["status_hint"] as? String) ?? hint
            }
            orch.addSubview(agentRow(boxW: boxW, y: ay, title: lab, sub: "\(typ) · \(hint)",
                                      id: wid, accent: PongTheme.magenta))
            ay -= 44
        }
        blocks.append(orch)
        total += aH + 14

        // —— Timeline (digested events) ——
        let digested = digestEvents(Array(events.suffix(10).reversed()))
        let tH: CGFloat = 40 + CGFloat(max(digested.count, 1)) * 36
        let time = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: tH))
        PongTheme.applyFloating(time)
        time.addSubview(PanelController.label("Recent flow",
            frame: NSRect(x: 16, y: tH - 28, width: 160, height: 18), bold: true, size: 13))
        if digested.isEmpty {
            time.addSubview(PanelController.label("No activity yet. When jobs run, steps show up here.",
                frame: NSRect(x: 16, y: 12, width: boxW - 32, height: 16), size: 11, secondary: true))
        } else {
            var ey = tH - 48
            for (i, line) in digested.enumerated() {
                let dot = NSView(frame: NSRect(x: 18, y: ey + 6, width: 8, height: 8))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = line.color.cgColor
                time.addSubview(dot)
                if i < digested.count - 1 {
                    let stem = NSView(frame: NSRect(x: 21, y: ey - 24, width: 2, height: 28))
                    stem.wantsLayer = true
                    stem.layer?.backgroundColor = PongTheme.border.cgColor
                    time.addSubview(stem)
                }
                time.addSubview(PanelController.label(line.text,
                    frame: NSRect(x: 36, y: ey, width: boxW - 52, height: 28), size: 11, secondary: false))
                ey -= 36
            }
        }
        blocks.append(time)
        total += tH + 20

        // Recently completed (if any)
        if !recentJobs.isEmpty {
            let rH: CGFloat = 36 + CGFloat(min(recentJobs.count, 4)) * 24
            let rec = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: rH))
            PongTheme.applyFloating(rec)
            rec.addSubview(PanelController.label("Recently finished",
                frame: NSRect(x: 16, y: rH - 26, width: 180, height: 16), bold: true, size: 12))
            var ry = rH - 44
            for j in recentJobs.prefix(4) {
                let st = (j["status"] as? String) ?? "done"
                let prev = (j["task_preview"] as? String) ?? ""
                rec.addSubview(PanelController.label("\(st) · \(prev)",
                    frame: NSRect(x: 16, y: ry, width: boxW - 32, height: 16), size: 10, secondary: true))
                ry -= 24
            }
            blocks.append(rec)
            total += rH + 14
        }

        let contentH = max(scroll.contentSize.height, total)
        body.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for b in blocks {
            y -= b.frame.height
            b.setFrameOrigin(NSPoint(x: 0, y: y))
            body.addSubview(b)
            y -= 14
        }
        window?.title = "Focus · \(display)"
    }

    // MARK: Digest helpers

    private struct StageInfo {
        let name: String
        let color: NSColor
        let summary: String
    }

    private func digestStage(openJobs: [[String: Any]], workers: [[String: Any]],
                             events: [[String: Any]], rejectStreak: Int) -> StageInfo {
        if rejectStreak >= 2 {
            return StageInfo(name: "human", color: PongTheme.orange,
                             summary: "Reject streak \(rejectStreak) — review claims or help the orchestrator.")
        }
        let statuses = openJobs.compactMap { $0["status"] as? String }
        if statuses.contains(where: { $0 == "human_takeover" }) {
            return StageInfo(name: "human", color: PongTheme.orange,
                             summary: "A worker is in human takeover — open that terminal.")
        }
        if statuses.contains(where: { $0 == "running" || $0 == "notified" }) {
            return StageInfo(name: "build", color: PongTheme.magenta,
                             summary: "Workers are building. Orchestrator waits on claims.")
        }
        if statuses.contains(where: { $0 == "queued" }) {
            return StageInfo(name: "assign", color: PongTheme.blue,
                             summary: "Jobs queued — waiting for workers to pick up.")
        }
        if events.contains(where: { ($0["type"] as? String) == "job.claim" || ($0["verdict"] as? String) != nil }) {
            return StageInfo(name: "verify", color: PongTheme.blue,
                             summary: "Recent claims/verdicts — orchestrator is verifying.")
        }
        return StageInfo(name: "plan", color: PongTheme.idle,
                         summary: "Idle. Orchestrator can plan the next slice of work.")
    }

    private func flowStory(stage: StageInfo, openCount: Int, workers: [[String: Any]], rejectStreak: Int) -> String {
        stage.summary
    }

    private struct PipeCell { let active: Bool; let caption: String; let color: NSColor }

    private func pipelineStages(openJobs: [[String: Any]], events: [[String: Any]], rejectStreak: Int) -> [PipeCell] {
        let statuses = Set(openJobs.compactMap { $0["status"] as? String })
        let hasOpen = !openJobs.isEmpty
        let building = statuses.contains("running") || statuses.contains("notified")
        let queued = statuses.contains("queued")
        let human = statuses.contains("human_takeover") || rejectStreak >= 2
        let verifying = events.contains { ($0["type"] as? String)?.contains("claim") == true || ($0["type"] as? String) == "verdict" }
        let doneRecently = events.contains { ($0["verdict"] as? String) == "accept" || ($0["status"] as? String) == "done" }

        return [
            PipeCell(active: !hasOpen && !verifying, caption: human ? "—" : (hasOpen ? "ok" : "now"), color: PongTheme.blue),
            PipeCell(active: queued, caption: queued ? "\(openJobs.count)" : "—", color: PongTheme.blue),
            PipeCell(active: building || human, caption: human ? "you" : (building ? "live" : "—"), color: human ? PongTheme.orange : PongTheme.magenta),
            PipeCell(active: verifying && !building, caption: verifying ? "check" : "—", color: PongTheme.blue),
            PipeCell(active: doneRecently && !hasOpen, caption: doneRecently ? "ok" : "—", color: PongTheme.live),
        ]
    }

    private struct DigestLine { let text: String; let color: NSColor }

    private func digestEvents(_ events: [[String: Any]]) -> [DigestLine] {
        events.compactMap { e -> DigestLine? in
            guard let t = e["type"] as? String, !t.isEmpty else { return nil }
            switch t {
            case "job.created":
                return DigestLine(text: "Job created · \(e["worker"] as? String ?? "worker")", color: PongTheme.blue)
            case "job.dispatch":
                return DigestLine(text: "Dispatched to worker · \(e["status"] as? String ?? "")", color: PongTheme.blue)
            case "job.status":
                let st = e["status"] as? String ?? "?"
                let sk = PongTheme.statusKind(st)
                return DigestLine(text: "Status → \(st)", color: sk.color)
            case "job.claim":
                return DigestLine(text: "Worker filed a claim — ready to verify", color: PongTheme.magenta)
            case "verdict":
                let v = e["verdict"] as? String ?? "?"
                let c: NSColor = v == "accept" ? PongTheme.live : (v == "reject" ? PongTheme.orange : PongTheme.danger)
                return DigestLine(text: "Verdict: \(v)", color: c)
            default:
                return DigestLine(text: t, color: PongTheme.textSecondary)
            }
        }
    }

    private func agentRow(boxW: CGFloat, y: CGFloat, title: String, sub: String, id: String, accent: NSColor) -> NSView {
        let row = NSView(frame: NSRect(x: 12, y: y, width: boxW - 24, height: 38))
        row.wantsLayer = true
        row.layer?.backgroundColor = PongTheme.bgInput.cgColor
        row.layer?.cornerRadius = 10
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 38))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = accent.cgColor
        row.addSubview(bar)
        row.addSubview(PanelController.label(title,
            frame: NSRect(x: 14, y: 16, width: 160, height: 16), bold: true, size: 12))
        row.addSubview(PanelController.label(sub,
            frame: NSRect(x: 14, y: 2, width: 200, height: 12), size: 9, secondary: true))
        let b = btn("Terminal", #selector(openAgent(_:)), filled: false)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: boxW - 118, y: 7, width: 78, height: 24)
        row.addSubview(b)
        return row
    }

    private func pill(_ text: String, color: NSColor, soft: NSColor) -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        v.layer?.backgroundColor = soft.cgColor
        let l = NSTextField(labelWithString: text)
        l.font = PongTheme.font(9, weight: .bold)
        l.textColor = color
        l.alignment = .center
        l.isBordered = false
        l.backgroundColor = .clear
        l.frame = NSRect(x: 0, y: 1, width: 72, height: 16)
        v.addSubview(l)
        return v
    }

    private func btn(_ title: String, _ sel: Selector, filled: Bool) -> NSButton {
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

    /// Create a control-plane job for a worker on this team (no paste required).
    @objc private func createJobPressed() {
        NSApp.activate(ignoringOtherApps: true)
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        guard !ws.isEmpty else {
            let a = NSAlert()
            a.messageText = "No workers"
            a.informativeText = "Add a worker seat before creating a job."
            a.runModal()
            return
        }

        let a = NSAlert()
        a.messageText = "New job"
        a.informativeText = "Assign work to a worker seat. Job file is source of truth (--no-paste)."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 36, width: 280, height: 26), pullsDown: false)
        for w in ws {
            let id = (w["id"] as? String) ?? "?"
            let lab = (w["label"] as? String) ?? id
            pop.addItem(withTitle: "\(id) · \(lab)")
            pop.lastItem?.representedObject = id
        }
        let task = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        task.placeholderString = "Task (acceptance optional — add after first line)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
        box.addSubview(pop)
        box.addSubview(task)
        a.accessoryView = box
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = task
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let workerId = (pop.selectedItem?.representedObject as? String) ?? "w1"
        let body = task.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = body
                .replacingOccurrences(of: "'", with: "'\\''")
                .replacingOccurrences(of: "\n", with: "\\n")
            let out = Pong.sh(
                "export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; " +
                "export PONG_SESSION=\(self.session) HERMES_PONG_SESSION=\(self.session); " +
                "pong job create --worker \(workerId) --no-paste --task '\(escaped)' 2>&1 | tail -5"
            )
            Pong.log("focus job create worker=\(workerId) out=\(out.prefix(200))")
            DispatchQueue.main.async {
                self.reload()
                PanelController.shared.refreshUI()
                let done = NSAlert()
                done.messageText = "Job created"
                done.informativeText = out.isEmpty
                    ? "Assigned to \(workerId). Check Mission or 3D flow labels."
                    : String(out.prefix(400))
                done.runModal()
            }
        }
    }
}

// MARK: - Human ask protocol (Deny / Accept once / Always accept)

/// A question from the orchestrator (or a job) waiting on the human.
struct HumanAsk: Equatable {
    let id: String
    let session: String
    let question: String
    let source: String       // c1 / worker id / "orchestrator"
    let jobId: String?
}

/// Structured human-console turn (JSONL under human/<session>/chat.jsonl).
struct HumanChatMessage: Equatable {
    enum Kind: String {
        case fromYou = "from_you"
        case fromOrch = "from_orch"
        case ask = "ask"
        case status = "status"
    }

    let id: String
    let kind: Kind
    let text: String
    let ts: TimeInterval
    let jobId: String?
    let seatId: String?
    let files: [String]

    func asDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "text": text,
            "ts": ts,
        ]
        if let jobId, !jobId.isEmpty { d["job_id"] = jobId }
        if let seatId, !seatId.isEmpty { d["seat_id"] = seatId }
        if !files.isEmpty { d["files"] = files }
        return d
    }

    static func fromDict(_ d: [String: Any]) -> HumanChatMessage? {
        guard let kindRaw = d["kind"] as? String,
              let kind = Kind(rawValue: kindRaw),
              let text = d["text"] as? String else { return nil }
        let id = (d["id"] as? String) ?? UUID().uuidString
        let ts = (d["ts"] as? Double) ?? Date().timeIntervalSince1970
        let files = (d["files"] as? [String]) ?? []
        return HumanChatMessage(
            id: id,
            kind: kind,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            ts: ts,
            jobId: d["job_id"] as? String,
            seatId: d["seat_id"] as? String,
            files: files
        )
    }
}

enum HumanAskDecision: String {
    case deny
    case acceptOnce = "accept_once"
    case alwaysAccept = "always_accept"

    var title: String {
        switch self {
        case .deny: return "Deny"
        case .acceptOnce: return "Accept once"
        case .alwaysAccept: return "Always accept"
        }
    }

    /// Message pasted into the orchestrator pane.
    var replyText: String {
        switch self {
        case .deny:
            return "HUMAN DECISION: DENY — do not proceed with the requested action."
        case .acceptOnce:
            return "HUMAN DECISION: ACCEPT ONCE — proceed with this action only; ask again next time."
        case .alwaysAccept:
            return "HUMAN DECISION: ALWAYS ACCEPT — proceed, and do not ask again for elevated actions this session (full access)."
        }
    }
}

// MARK: - Human console (YOU cube on the map)

/// Unified place to talk to orchestrators and answer “needs you” without Terminal hunting.
final class HumanConsoleController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = HumanConsoleController()

    private var window: NSWindow?
    private var session = ""
    private var sessionPop: NSPopUpButton!
    private var inboxView: NSTextView!
    private var inputView: NSTextView!
    private var statusLabel: NSTextField!
    /// Pending-ask chrome (hidden when idle).
    private var askBar: NSView!
    private var askQuestionLabel: NSTextField!
    private var denyBtn: NSButton!
    private var acceptOnceBtn: NSButton!
    private var alwaysBtn: NSButton!
    private var currentAsk: HumanAsk?
    private let W: CGFloat = 520
    private let H: CGFloat = 600

    func show(session: String) {
        self.session = session
        if window == nil { build() }
        reloadSessions()
        reloadInbox()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputView)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "You · Human console"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = PongTheme.bg
        win.minSize = NSSize(width: 420, height: 460)
        win.setFrameAutosaveName("PongHumanConsole")
        win.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "YOU")
        title.font = PongTheme.font(18, weight: .bold)
        title.textColor = PongTheme.amber
        title.frame = NSRect(x: 20, y: H - 48, width: 80, height: 24)
        title.autoresizingMask = [.minYMargin]
        root.addSubview(title)

        let sub = NSTextField(labelWithString: "Talk to the orchestrator · answer asks · no Terminal hunting")
        sub.font = PongTheme.font(11)
        sub.textColor = PongTheme.textSecondary
        sub.frame = NSRect(x: 100, y: H - 46, width: W - 120, height: 20)
        sub.autoresizingMask = [.minYMargin, .width]
        root.addSubview(sub)

        sessionPop = NSPopUpButton(frame: NSRect(x: 20, y: H - 82, width: min(280, W - 40), height: 26), pullsDown: false)
        sessionPop.target = self
        sessionPop.action = #selector(sessionChanged)
        sessionPop.autoresizingMask = [.minYMargin]
        root.addSubview(sessionPop)

        // Pending ask bar — Deny / Accept once / Always accept
        askBar = NSView(frame: NSRect(x: 20, y: H - 200, width: W - 40, height: 100))
        askBar.wantsLayer = true
        askBar.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.04, alpha: 0.95).cgColor
        askBar.layer?.cornerRadius = 10
        askBar.layer?.borderWidth = 1
        askBar.layer?.borderColor = PongTheme.amber.withAlphaComponent(0.45).cgColor
        askBar.autoresizingMask = [.minYMargin, .width]
        askBar.isHidden = true

        let askHead = NSTextField(labelWithString: "ORCHESTRATOR ASKS")
        askHead.font = PongTheme.labelFont(10)
        askHead.textColor = PongTheme.amber
        askHead.frame = NSRect(x: 12, y: 74, width: 200, height: 14)
        askBar.addSubview(askHead)

        askQuestionLabel = NSTextField(wrappingLabelWithString: "")
        askQuestionLabel.font = PongTheme.font(12, weight: .medium)
        askQuestionLabel.textColor = PongTheme.textPrimary
        askQuestionLabel.maximumNumberOfLines = 3
        askQuestionLabel.frame = NSRect(x: 12, y: 36, width: W - 64, height: 38)
        askQuestionLabel.autoresizingMask = [.width]
        askBar.addSubview(askQuestionLabel)

        denyBtn = NSButton(title: "Deny", target: self, action: #selector(denyPressed))
        denyBtn.bezelStyle = .rounded
        denyBtn.frame = NSRect(x: 12, y: 8, width: 88, height: 26)
        askBar.addSubview(denyBtn)

        acceptOnceBtn = NSButton(title: "Accept once", target: self, action: #selector(acceptOncePressed))
        acceptOnceBtn.bezelStyle = .rounded
        acceptOnceBtn.frame = NSRect(x: 108, y: 8, width: 110, height: 26)
        askBar.addSubview(acceptOnceBtn)

        alwaysBtn = NSButton(title: "Always accept", target: self, action: #selector(alwaysPressed))
        alwaysBtn.bezelStyle = .rounded
        alwaysBtn.frame = NSRect(x: 226, y: 8, width: 120, height: 26)
        alwaysBtn.toolTip = "Allow elevated actions for the rest of this session without asking again"
        askBar.addSubview(alwaysBtn)

        root.addSubview(askBar)

        // Inbox
        let inLab = NSTextField(labelWithString: "FROM TEAM  ·  asks & human-needed jobs")
        inLab.font = PongTheme.labelFont(10)
        inLab.textColor = PongTheme.textTertiary
        inLab.frame = NSRect(x: 20, y: H - 224, width: 300, height: 14)
        inLab.autoresizingMask = [.minYMargin]
        root.addSubview(inLab)

        let inScroll = NSScrollView(frame: NSRect(x: 20, y: 168, width: W - 40, height: H - 350))
        inScroll.hasVerticalScroller = true
        inScroll.borderType = .noBorder
        inScroll.drawsBackground = true
        inScroll.backgroundColor = PongTheme.bgElevated
        inScroll.autoresizingMask = [.width, .height]
        inScroll.identifier = NSUserInterfaceItemIdentifier("humanInboxScroll")
        inboxView = NSTextView(frame: inScroll.bounds)
        inboxView.isEditable = false
        inboxView.isSelectable = true
        inboxView.font = PongTheme.mono(11)
        inboxView.textColor = PongTheme.textPrimary
        inboxView.backgroundColor = PongTheme.bgElevated
        inboxView.textContainerInset = NSSize(width: 10, height: 10)
        inScroll.documentView = inboxView
        root.addSubview(inScroll)

        // Compose
        let outLab = NSTextField(labelWithString: "TO ORCHESTRATOR  ·  prompt or answer")
        outLab.font = PongTheme.labelFont(10)
        outLab.textColor = PongTheme.textTertiary
        outLab.frame = NSRect(x: 20, y: 140, width: 300, height: 14)
        outLab.autoresizingMask = [.maxYMargin]
        root.addSubview(outLab)

        let outScroll = NSScrollView(frame: NSRect(x: 20, y: 52, width: W - 40, height: 84))
        outScroll.hasVerticalScroller = true
        outScroll.borderType = .lineBorder
        outScroll.drawsBackground = true
        outScroll.backgroundColor = PongTheme.bgInput
        outScroll.autoresizingMask = [.width, .maxYMargin]
        inputView = NSTextView(frame: outScroll.bounds)
        inputView.isEditable = true
        inputView.font = PongTheme.font(12)
        inputView.textColor = PongTheme.textPrimary
        inputView.backgroundColor = PongTheme.bgInput
        inputView.textContainerInset = NSSize(width: 8, height: 8)
        inputView.delegate = self
        outScroll.documentView = inputView
        root.addSubview(outScroll)

        let send = NSButton(title: "Send to orchestrator", target: self, action: #selector(sendPressed))
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        send.frame = NSRect(x: W - 200, y: 14, width: 180, height: 28)
        send.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(send)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refresh.bezelStyle = .rounded
        refresh.frame = NSRect(x: 20, y: 14, width: 80, height: 28)
        refresh.autoresizingMask = [.maxYMargin]
        root.addSubview(refresh)

        let openOrch = NSButton(title: "Open terminal…", target: self, action: #selector(openOrchPressed))
        openOrch.bezelStyle = .rounded
        openOrch.frame = NSRect(x: 108, y: 14, width: 120, height: 28)
        openOrch.autoresizingMask = [.maxYMargin]
        root.addSubview(openOrch)

        statusLabel = NSTextField(labelWithString: "⌘↩ to send · lands in orchestrator pane + log")
        statusLabel.font = PongTheme.font(10)
        statusLabel.textColor = PongTheme.textTertiary
        statusLabel.frame = NSRect(x: 240, y: 18, width: 200, height: 16)
        statusLabel.autoresizingMask = [.maxYMargin]
        root.addSubview(statusLabel)

        win.contentView = root
        window = win
    }

    private func reloadSessions() {
        let pairs = PairState.listPairs()
        sessionPop.removeAllItems()
        for p in pairs {
            let entry = PairState.loadPairsDb()[p] as? [String: Any] ?? [:]
            let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? p
            sessionPop.addItem(withTitle: name)
            sessionPop.lastItem?.representedObject = p
            if p == session { sessionPop.select(sessionPop.lastItem) }
        }
        if sessionPop.numberOfItems == 0 {
            sessionPop.addItem(withTitle: "(no teams)")
        }
    }

    private func reloadInbox() {
        var lines: [String] = []
        lines.append("Session  \(session)")
        lines.append(String(repeating: "─", count: 48))

        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let team = ((snap["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == session }
        let openJobs = ((team?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let workers = (team?["workers"] as? [[String: Any]]) ?? []

        var asks: [String] = []
        for w in workers {
            let h = ((w["status_hint"] as? String) ?? "").lowercased()
            let id = (w["id"] as? String) ?? "?"
            let lab = (w["label"] as? String) ?? id
            if h.contains("human") || h.contains("takeover") || h.contains("ask") {
                asks.append("• \(lab) (\(id)) needs you — \(w["status_hint"] as? String ?? h)")
            }
        }
        for j in openJobs {
            let st = ((j["status"] as? String) ?? "").lowercased()
            if st.contains("human") || st.contains("ask") {
                let prev = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? (j["id"] as? String) ?? "job"
                let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
                asks.append("• Job \(j["id"] as? String ?? "?") · \(wid) · \(st)\n  \(String(prev.prefix(160)))")
            }
        }

        // Pending structured ask (or synthesized from jobs/workers)
        currentAsk = Self.loadPendingAsk(session: session)
        updateAskBar()

        if asks.isEmpty && currentAsk == nil {
            lines.append("")
            lines.append("No open asks. You can still send a prompt to the orchestrator below.")
        } else {
            lines.append("")
            lines.append("NEEDS YOU")
            if let ask = currentAsk {
                lines.append("• \(ask.source): \(ask.question)")
            }
            lines.append(contentsOf: asks)
        }

        // Prior human messages
        let log = Self.logPath(session: session)
        if let data = try? String(contentsOfFile: log, encoding: .utf8), !data.isEmpty {
            lines.append("")
            lines.append("RECENT (you → orch)")
            lines.append(String(data.suffix(1200)))
        }

        inboxView.string = lines.joined(separator: "\n")
        if currentAsk != nil {
            statusLabel.stringValue = "Decision required · Deny / Accept once / Always accept"
            statusLabel.textColor = PongTheme.amber
        } else if asks.isEmpty {
            statusLabel.stringValue = "Ready · ⌘↩ send"
            statusLabel.textColor = PongTheme.textTertiary
        } else {
            statusLabel.stringValue = "\(asks.count) open ask(s) · reply below or use buttons"
            statusLabel.textColor = PongTheme.amber
        }
    }

    private func updateAskBar() {
        guard let askBar else { return }
        if let ask = currentAsk {
            askBar.isHidden = false
            askQuestionLabel.stringValue = ask.question
            // Nudge inbox under the ask bar
            if let scroll = window?.contentView?.subviews.first(where: {
                $0 is NSScrollView && ($0 as? NSScrollView)?.documentView === inboxView
            }) as? NSScrollView {
                let h = window?.contentView?.bounds.height ?? H
                scroll.frame = NSRect(x: 20, y: 168, width: (window?.contentView?.bounds.width ?? W) - 40, height: h - 350)
            }
        } else {
            askBar.isHidden = true
            if let scroll = window?.contentView?.subviews.first(where: {
                $0 is NSScrollView && ($0 as? NSScrollView)?.documentView === inboxView
            }) as? NSScrollView {
                let h = window?.contentView?.bounds.height ?? H
                // Expand inbox when no ask bar
                scroll.frame = NSRect(x: 20, y: 168, width: (window?.contentView?.bounds.width ?? W) - 40, height: h - 250)
            }
        }
    }

    @objc private func sessionChanged() {
        if let s = sessionPop.selectedItem?.representedObject as? String {
            session = s
            reloadInbox()
        }
    }

    @objc private func refreshPressed() { reloadInbox() }

    @objc private func openOrchPressed() {
        DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(self.session) }
    }

    @objc private func denyPressed() { respond(.deny) }
    @objc private func acceptOncePressed() { respond(.acceptOnce) }
    @objc private func alwaysPressed() { respond(.alwaysAccept) }

    private func respond(_ decision: HumanAskDecision) {
        guard !session.isEmpty else { return }
        statusLabel.stringValue = "Sending \(decision.title)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.respondToAsk(session: self.session, decision: decision)
            DispatchQueue.main.async {
                self.statusLabel.stringValue = ok
                    ? "\(decision.title) sent · \(Date().formatted(date: .omitted, time: .shortened))"
                    : "Could not deliver decision"
                self.statusLabel.textColor = ok ? PongTheme.amber : PongTheme.danger
                self.reloadInbox()
            }
        }
    }

    @objc private func sendPressed() {
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !session.isEmpty else { return }

        statusLabel.stringValue = "Sending…"
        let payload = text
        inputView.string = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.deliver(session: self.session, text: payload)
            DispatchQueue.main.async {
                self.statusLabel.stringValue = ok
                    ? "Sent to orchestrator · \(Date().formatted(date: .omitted, time: .shortened))"
                    : "Send failed — is the team session live?"
                self.statusLabel.textColor = ok ? PongTheme.amber : PongTheme.danger
                self.reloadInbox()
            }
        }
    }

    // MARK: - Pending ask files

    static func humanDir(session: String) -> String {
        Pong.stateDir + "/human/\(session)"
    }

    static func pendingAskPath(session: String) -> String {
        humanDir(session: session) + "/pending_ask.json"
    }

    static func lastResponsePath(session: String) -> String {
        humanDir(session: session) + "/last_response.json"
    }

    /// Strip agent dumps / job wrappers — show only the question text in the human panel.
    static func questionOnly(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer explicit "Question:" / "Ask:" lines
        for line in t.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            let lower = s.lowercased()
            if lower.hasPrefix("question:") || lower.hasPrefix("ask:") || lower.hasPrefix("q:") {
                let cut = s.firstIndex(of: ":").map { s.index(after: $0) } ?? s.startIndex
                let body = String(s[cut...]).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { return String(body.prefix(400)) }
            }
        }
        // Drop common dump markers
        for marker in ["##WORKER_DONE##", "##CLAUDE_DONE##", "Acceptance:", "CLAIM:", "```"] {
            if let r = t.range(of: marker) {
                t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // First paragraph only
        if let para = t.components(separatedBy: "\n\n").first {
            t = para.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.count > 400 {
            t = String(t.prefix(400))
            if let sp = t.lastIndex(of: " ") { t = String(t[..<sp]) + "…" }
        }
        return t.isEmpty ? "Team needs your input." : t
    }

    /// Load explicit pending_ask.json, else synthesize from open human jobs / worker hints.
    static func loadPendingAsk(session: String) -> HumanAsk? {
        guard !session.isEmpty else { return nil }
        let path = pendingAskPath(session: session)
        let file = Pong.loadJSON(path)
        if let q = file["question"] as? String, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HumanAsk(
                id: (file["id"] as? String) ?? "ask-\(session)",
                session: session,
                question: questionOnly(q),
                source: (file["source"] as? String) ?? "orchestrator",
                jobId: file["job_id"] as? String
            )
        }

        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let team = ((snap["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == session }
        let openJobs = ((team?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        for j in openJobs {
            let st = ((j["status"] as? String) ?? "").lowercased()
            let takeover = (j["human_takeover"] as? Bool) == true
            if st.contains("human") || st.contains("ask") || takeover {
                let prev = (j["task_preview"] as? String)
                    ?? (j["human_question"] as? String)
                    ?? (j["task"] as? String)
                    ?? "Job needs your decision"
                let jid = (j["id"] as? String) ?? "job"
                let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "team"
                return HumanAsk(
                    id: "job-\(jid)",
                    session: session,
                    question: questionOnly(prev),
                    source: wid,
                    jobId: jid
                )
            }
        }
        for w in (team?["workers"] as? [[String: Any]]) ?? [] {
            let h = ((w["status_hint"] as? String) ?? "").lowercased()
            if h.contains("human") || h.contains("takeover") || h.contains("ask") {
                let id = (w["id"] as? String) ?? "w"
                let lab = (w["label"] as? String) ?? id
                // Prefer a short question field if present; never dump full status essays
                let detail = (w["human_question"] as? String)
                    ?? (w["ask"] as? String)
                    ?? "needs your input"
                return HumanAsk(
                    id: "seat-\(id)",
                    session: session,
                    question: questionOnly("\(lab): \(detail)"),
                    source: id,
                    jobId: nil
                )
            }
        }
        return nil
    }

    /// Write a structured ask (for agents / bridge). Overwrites previous pending ask.
    @discardableResult
    static func postAsk(session: String, question: String, source: String = "orchestrator",
                        jobId: String? = nil) -> Bool {
        guard !session.isEmpty, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let dir = humanDir(session: session)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var dict: [String: Any] = [
            "id": "ask-\(Int(Date().timeIntervalSince1970))",
            "session": session,
            "question": question.trimmingCharacters(in: .whitespacesAndNewlines),
            "source": source,
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let jobId { dict["job_id"] = jobId }
        Pong.writeJSON(pendingAskPath(session: session), dict)
        return true
    }

    /// Apply Deny / Accept once / Always accept: deliver reply, clear pending, update policy if needed.
    @discardableResult
    static func respondToAsk(session: String, decision: HumanAskDecision) -> Bool {
        let ask = loadPendingAsk(session: session)
        var reply = decision.replyText
        if let ask {
            reply += "\n\nRe: \(ask.question)"
            if let jid = ask.jobId { reply += "\nJob: \(jid)" }
        }
        let ok = deliver(session: session, text: reply)

        // Persist decision for agents to poll
        let dir = humanDir(session: session)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var resp: [String: Any] = [
            "decision": decision.rawValue,
            "session": session,
            "at": ISO8601DateFormatter().string(from: Date()),
            "reply": reply,
        ]
        if let ask {
            resp["ask_id"] = ask.id
            resp["question"] = ask.question
            if let jid = ask.jobId { resp["job_id"] = jid }
        }
        Pong.writeJSON(lastResponsePath(session: session), resp)

        // Clear pending file
        try? FileManager.default.removeItem(atPath: pendingAskPath(session: session))

        if decision == .alwaysAccept {
            // Session policy: stop ask-each gate
            var perms = PairState.permissions(for: session)
            perms["ask_each"] = false
            perms["always_accept"] = true
            perms["custom_prompt"] =
                "Human chose ALWAYS ACCEPT for this session. Proceed with elevated actions " +
                "without re-asking unless something is irreversible/destructive outside policy."
            PairState.savePairState(session, permissions: perms)
        } else if decision == .deny {
            // If tied to a job, mark rejected when possible
            if let jid = ask?.jobId, !jid.isEmpty {
                let q = jid.replacingOccurrences(of: "'", with: "'\\''")
                _ = Pong.sh("""
                    export PATH="$HOME/bin:/opt/homebrew/bin:$PATH"
                    pong job status --session '\(session)' '\(q)' rejected 2>/dev/null || true
                    """)
            }
        } else if decision == .acceptOnce {
            if let jid = ask?.jobId, !jid.isEmpty {
                let q = jid.replacingOccurrences(of: "'", with: "'\\''")
                _ = Pong.sh("""
                    export PATH="$HOME/bin:/opt/homebrew/bin:$PATH"
                    pong job status --session '\(session)' '\(q)' running 2>/dev/null || true
                    """)
            }
        }
        return ok
    }

    static func cardsPath(session: String) -> String {
        humanDir(session: session) + "/chat.jsonl"
    }

    /// Append a structured card (interactive console). Also keeps free-text log for agents.
    @discardableResult
    static func appendCard(session: String, kind: HumanChatMessage.Kind, text: String,
                           jobId: String? = nil, seatId: String? = nil, files: [String] = []) -> HumanChatMessage {
        let msg = HumanChatMessage(
            id: "m-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))",
            kind: kind,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            ts: Date().timeIntervalSince1970,
            jobId: jobId,
            seatId: seatId,
            files: files
        )
        let dir = humanDir(session: session)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = cardsPath(session: session)
        if let data = try? JSONSerialization.data(withJSONObject: msg.asDict()),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        return msg
    }

    /// Load structured cards (newest last). Cap to last N for UI.
    static func loadCards(session: String, limit: Int = 80) -> [HumanChatMessage] {
        let path = cardsPath(session: session)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8), !raw.isEmpty else {
            // Migrate: seed from free-text log if present (one-time light parse)
            return seedCardsFromLog(session: session)
        }
        var out: [HumanChatMessage] = []
        for line in raw.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = HumanChatMessage.fromDict(obj) else { continue }
            out.append(msg)
        }
        if out.count > limit { out = Array(out.suffix(limit)) }
        return out
    }

    /// Best-effort parse of legacy console.log into a few from_you cards.
    private static func seedCardsFromLog(session: String) -> [HumanChatMessage] {
        let path = logPath(session: session)
        guard let data = try? String(contentsOfFile: path, encoding: .utf8), !data.isEmpty else {
            return []
        }
        var cards: [HumanChatMessage] = []
        let chunks = data.components(separatedBy: "—— YOU ·")
        for chunk in chunks.dropFirst().suffix(12) {
            let body = chunk
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst() // timestamp line remainder
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let files = body.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- /") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespaces)) }
            let text = questionOnly(body)
            cards.append(HumanChatMessage(
                id: "seed-\(cards.count)-\(session.hashValue)",
                kind: .fromYou,
                text: String(text.prefix(500)),
                ts: Date().timeIntervalSince1970 - Double(12 - cards.count),
                jobId: nil,
                seatId: nil,
                files: files
            ))
        }
        // Persist seed so we don't re-parse every poll
        if !cards.isEmpty {
            for c in cards {
                _ = appendCard(session: session, kind: c.kind, text: c.text, files: c.files)
            }
        }
        return loadCards(session: session, limit: 80)
    }

    /// Paste into conductor tmux pane + append human log (unified path).
    @discardableResult
    static func deliver(session: String, text: String) -> Bool {
        let header = "\n—— YOU · \(ISO8601DateFormatter().string(from: Date())) ——\n"
        let body = header + text + "\n"
        // Structured card for interactive UI
        var files: [String] = []
        if text.contains("Attached files:") {
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- /") || t.hasPrefix("- ~/") {
                    files.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        _ = appendCard(session: session, kind: .fromYou, text: text, files: files)

        // Free-text log (agents / outbox)
        let path = logPath(session: session)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(body.utf8))
            try? h.close()
        } else {
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // Also write outbox agents can read
        let outbox = Pong.stateDir + "/human/\(session)/outbox.md"
        try? FileManager.default.createDirectory(
            atPath: (outbox as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? body.write(toFile: outbox, atomically: true, encoding: .utf8)

        // Deliver into orchestrator pane — prefer registered c1 pane_id (survives view sessions)
        TmuxScroll.apply(session: session)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pong-human-\(UUID().uuidString).txt")
        do {
            try body.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("human console write tmp fail: \(error)")
            return false
        }
        let paneId = Self.conductorPaneId(session: session)
        // Prefer immutable pane id; fall back to window 0 of base session
        let target = paneId.isEmpty ? "\(session):0" : paneId
        let q = tmp.path.replacingOccurrences(of: "'", with: "'\\''")
        // load-buffer from file → paste → Enter twice (Grok/Claude often need a real submit)
        let out = Pong.sh("""
            tmux has-session -t '\(session)' 2>/dev/null || exit 1
            tmux load-buffer -b pong_human '\(q)' || exit 2
            tmux paste-buffer -b pong_human -d -t '\(target)' || exit 3
            sleep 0.12
            tmux send-keys -t '\(target)' Enter
            sleep 0.08
            tmux send-keys -t '\(target)' C-m
            sleep 0.05
            tmux send-keys -t '\(target)' Enter
            echo OK
            """)
        try? FileManager.default.removeItem(at: tmp)
        Pong.log("human console deliver session=\(session) target=\(target) out=\(out.prefix(120))")
        return out.contains("OK")
    }

    /// Registered conductor pane_id (`c1` / hermes) or empty.
    private static func conductorPaneId(session: String) -> String {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        if let cond = entry["conductor"] as? [String: Any],
           let pid = cond["pane_id"] as? String, !pid.isEmpty {
            return pid
        }
        // panes.json via pong routing (file)
        let path = Pong.stateDir + "/sessions/\(session)/panes.json"
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["c1", "hermes"] {
                if let row = obj[key] as? [String: Any],
                   let pid = row["pane_id"] as? String, !pid.isEmpty {
                    return pid
                }
            }
        }
        // Live query window 0
        let live = Pong.sh("tmux display-message -p -t '\(session):0' '#{pane_id}' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return live.hasPrefix("%") ? live : ""
    }

    static func logPath(session: String) -> String {
        Pong.stateDir + "/human/\(session)/console.log"
    }

    /// Clear chat history for one team only (not other sessions).
    static func clearHistory(session: String) {
        let path = logPath(session: session)
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        let outbox = Pong.stateDir + "/human/\(session)/outbox.md"
        try? "".write(toFile: outbox, atomically: true, encoding: .utf8)
        try? "".write(toFile: cardsPath(session: session), atomically: true, encoding: .utf8)
        Pong.log("human console cleared session=\(session)")
    }
}

import AppKit
import Foundation

// MARK: - Cron schedule (who does what · when)

/// Persistent per-team cron definitions. Stored at `~/.pong/cron-schedules.json`.
enum CronSchedule {
    struct Job: Equatable {
        var id: String
        var name: String
        /// What the owner agent should actually do when this fires.
        var task: String
        /// Human cadence label, e.g. "every 15m", "daily 04:00"
        var cadence: String
        /// Interval seconds for next-run math (0 = use clock phase only)
        var intervalSec: TimeInterval
        /// Seconds-from-midnight phase for daily jobs; also used as stagger for intervals
        var phaseSec: TimeInterval
        /// Seat id on the team (c1, w1, …) — owner that fires the job
        var ownerId: String
        var enabled: Bool

        func asDict() -> [String: Any] {
            [
                "id": id, "name": name, "task": task, "cadence": cadence,
                "interval_sec": intervalSec, "phase_sec": phaseSec,
                "owner_id": ownerId, "enabled": enabled,
            ]
        }

        static func from(_ d: [String: Any]) -> Job? {
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            let id = (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(UUID().uuidString.prefix(8)).lowercased()
            let task = (d["task"] as? String)
                ?? (d["prompt"] as? String)
                ?? (d["description"] as? String)
                ?? ""
            return Job(
                id: id,
                name: name,
                task: task,
                cadence: (d["cadence"] as? String) ?? "hourly",
                intervalSec: (d["interval_sec"] as? Double)
                    ?? Double("\(d["interval_sec"] ?? 3600)") ?? 3600,
                phaseSec: (d["phase_sec"] as? Double)
                    ?? Double("\(d["phase_sec"] ?? 0)") ?? 0,
                ownerId: (d["owner_id"] as? String) ?? "c1",
                enabled: (d["enabled"] as? Bool) ?? true
            )
        }

        /// Next fire date after `from`.
        func nextRun(after from: Date = Date()) -> Date {
            guard enabled else { return from.addingTimeInterval(365 * 86400) }
            if intervalSec >= 86400 - 1 {
                // Daily (or longer): next day at phaseSec from midnight local
                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day], from: from)
                comps.hour = 0; comps.minute = 0; comps.second = 0
                let midnight = cal.date(from: comps) ?? from
                var candidate = midnight.addingTimeInterval(phaseSec)
                if candidate <= from {
                    candidate = candidate.addingTimeInterval(86400)
                }
                return candidate
            }
            if intervalSec <= 0 { return from.addingTimeInterval(3600) }
            // Interval jobs: align to epoch + phase
            let t = from.timeIntervalSince1970
            let base = floor((t - phaseSec) / intervalSec) * intervalSec + phaseSec
            var next = base + intervalSec
            if next <= t { next += intervalSec }
            return Date(timeIntervalSince1970: next)
        }

        var ownerTag: String {
            let o = ownerId.lowercased()
            if o.hasPrefix("c") { return "ORCH \(ownerId.uppercased())" }
            if o.hasPrefix("w") { return "AGT \(ownerId.uppercased())" }
            return ownerId.uppercased()
        }
    }

    private static var path: String { Pong.stateDir + "/cron-schedules.json" }

    static func load(session: String) -> [Job] {
        let db = Pong.loadJSON(path)
        if let arr = db[session] as? [[String: Any]] {
            let jobs = arr.compactMap { Job.from($0) }
            if !jobs.isEmpty { return jobs }
        }
        return defaultJobs(session: session)
    }

    static func save(session: String, jobs: [Job]) {
        var db = Pong.loadJSON(path)
        db[session] = jobs.map { $0.asDict() }
        db["updated"] = Date().timeIntervalSince1970
        Pong.writeJSON(path, db)
    }

    static func defaultJobs(session: String) -> [Job] {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
        let workers = Workers.list(from: entry)
        let w1 = (workers.first?["id"] as? String) ?? "w1"
        let w2 = workers.count > 1 ? ((workers[1]["id"] as? String) ?? "w2") : w1
        let wSub = workers.last(where: {
            (($0["parent_id"] as? String) ?? "").isEmpty == false
        })?["id"] as? String

        return [
            Job(id: "perimeter", name: "Perimeter sweep",
                task: "Quick health check of open jobs, stuck seats, and route errors. Report anything that needs human or reassignment.",
                cadence: "every 15m",
                intervalSec: 15 * 60, phaseSec: 0, ownerId: condId, enabled: true),
            Job(id: "snapshot", name: "Snapshot",
                task: "Summarize team state: open jobs, last verdicts, reject streak. Keep it to 5 bullets.",
                cadence: "every 30m",
                intervalSec: 30 * 60, phaseSec: 120, ownerId: condId, enabled: true),
            Job(id: "telemetry", name: "Telemetry sync",
                task: "Pull latest control-plane events and note anomalies (failures, route refused, long runtime).",
                cadence: "every 1h",
                intervalSec: 3600, phaseSec: 300, ownerId: w2, enabled: true),
            Job(id: "audit", name: "Log audit",
                task: "Review recent job claims for weak evidence or scope drift. Flag anything that should have been rejected.",
                cadence: "every 6h",
                intervalSec: 6 * 3600, phaseSec: 600, ownerId: wSub ?? w1, enabled: true),
            Job(id: "warmup", name: "Model warmup",
                task: "Open your seat, confirm tool access, and reply READY with model + cwd. Do not start product work.",
                cadence: "daily 04:00",
                intervalSec: 86400, phaseSec: 4 * 3600, ownerId: w1, enabled: true),
        ]
    }

    static func accent(forOwnerId ownerId: String, seats: [Seat3D]) -> NSColor {
        if let s = seats.first(where: { $0.id == ownerId }) {
            switch s.role {
            case "conductor": return PongTheme.blue
            case "subagent": return PongTheme.violet
            case "human": return PongTheme.amber
            default: return PongTheme.magenta
            }
        }
        let o = ownerId.lowercased()
        if o.hasPrefix("c") { return PongTheme.blue }
        if o.contains("sub") { return PongTheme.violet }
        return PongTheme.magenta
    }
}

/// Invisible full-row hit target so clicking a job opens edit (not only the Edit button).
private final class CronJobRowButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Cron manager sheet (add / edit jobs)

final class CronManagerSheet: NSObject {
    static let shared = CronManagerSheet()
    private var window: NSWindow?
    private var session = ""
    private var jobs: [CronSchedule.Job] = []
    private var seats: [Seat3D] = []
    private var onDone: (() -> Void)?
    private var listBox: NSView!
    private var scroll: NSScrollView!

    func show(session: String, seats: [Seat3D], preselectJobId: String? = nil, onDone: @escaping () -> Void) {
        self.session = session
        self.seats = seats.filter { $0.role != "human" }
        self.onDone = onDone
        self.jobs = CronSchedule.load(session: session)
        build()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadList()
        // Map ruler click: open editor preselected on that job
        if let pid = preselectJobId, let idx = jobs.firstIndex(where: { $0.id == pid }) {
            DispatchQueue.main.async { [weak self] in
                _ = self?.editJobAt(idx, isNew: false)
            }
        }
    }

    private func build() {
        let w: CGFloat = 520
        let h: CGFloat = 480
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Cron · schedule"
        win.center()
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bg

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        win.contentView = root

        let title = NSTextField(labelWithString: "CRON MANAGER")
        title.font = PongTheme.font(16, weight: .semibold)
        title.textColor = PongTheme.textPrimary
        title.frame = NSRect(x: 20, y: h - 40, width: 280, height: 22)
        root.addSubview(title)

        let sub = NSTextField(labelWithString: "Who runs what · cadence · timeline order")
        sub.font = PongTheme.font(11)
        sub.textColor = PongTheme.textSecondary
        sub.frame = NSRect(x: 20, y: h - 58, width: 360, height: 16)
        root.addSubview(sub)

        scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: w - 32, height: h - 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        listBox = NSView(frame: .zero)
        scroll.documentView = listBox
        root.addSubview(scroll)

        let add = NSButton(title: "+ Job", target: self, action: #selector(addJob))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: 16, y: 16, width: 80, height: 28)
        root.addSubview(add)

        let defaults = NSButton(title: "Restore defaults", target: self, action: #selector(restoreDefaults))
        defaults.bezelStyle = .rounded
        defaults.frame = NSRect(x: 104, y: 16, width: 130, height: 28)
        root.addSubview(defaults)

        let done = NSButton(title: "Done", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: w - 100, y: 16, width: 80, height: 28)
        root.addSubview(done)

        window = win
    }

    private func reloadList() {
        listBox.subviews.forEach { $0.removeFromSuperview() }
        let rowH: CGFloat = 64
        let W = max(scroll.contentSize.width - 8, 460)
        var y: CGFloat = 8
        let sorted = jobs.sorted { $0.nextRun() < $1.nextRun() }
        for (i, job) in sorted.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: W, height: rowH - 6))
            row.wantsLayer = true
            row.layer?.backgroundColor = PongTheme.bgElevated.cgColor
            row.layer?.cornerRadius = 6
            row.layer?.borderWidth = 1
            row.layer?.borderColor = PongTheme.border.cgColor

            let accent = CronSchedule.accent(forOwnerId: job.ownerId, seats: seats)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: rowH - 6))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = accent.cgColor
            row.addSubview(bar)

            let name = NSTextField(labelWithString: job.name)
            name.font = PongTheme.font(13, weight: .semibold)
            name.textColor = PongTheme.textPrimary
            name.frame = NSRect(x: 14, y: 36, width: 220, height: 18)
            row.addSubview(name)

            let ownerSeat = seats.first(where: { $0.id == job.ownerId })
            let ownerLabel = ownerSeat?.title ?? job.ownerTag
            let taskPreview = job.task.isEmpty ? "(no task yet)" : String(job.task.prefix(56))
            let meta = NSTextField(labelWithString: "\(job.cadence)  ·  → \(ownerLabel)  ·  \(taskPreview)")
            meta.font = PongTheme.mono(10)
            meta.textColor = PongTheme.textSecondary
            meta.lineBreakMode = .byTruncatingTail
            meta.frame = NSRect(x: 14, y: 10, width: max(200, W - 220), height: 14)
            row.addSubview(meta)

            let nf = DateFormatter()
            nf.dateFormat = "HH:mm"
            let next = NSTextField(labelWithString: "NEXT \(nf.string(from: job.nextRun()))")
            next.font = PongTheme.mono(10, weight: .semibold)
            next.textColor = accent
            next.alignment = .right
            next.frame = NSRect(x: W - 200, y: 32, width: 100, height: 16)
            row.addSubview(next)

            let jobIdx = jobs.firstIndex(where: { $0.id == job.id }) ?? i
            let edit = NSButton(title: "Edit", target: self, action: #selector(editJob(_:)))
            edit.bezelStyle = .rounded
            edit.isBordered = true
            edit.tag = jobIdx
            edit.frame = NSRect(x: W - 100, y: 18, width: 48, height: 26)
            row.addSubview(edit)

            let del = NSButton(title: "✕", target: self, action: #selector(deleteJob(_:)))
            del.bezelStyle = .rounded
            del.isBordered = true
            del.tag = jobIdx
            del.frame = NSRect(x: W - 48, y: 18, width: 32, height: 26)
            row.addSubview(del)

            // Click row (outside buttons) to edit
            let hit = CronJobRowButton(frame: NSRect(x: 0, y: 0, width: W - 110, height: rowH - 6))
            hit.isBordered = false
            hit.title = ""
            hit.tag = jobIdx
            hit.target = self
            hit.action = #selector(editJob(_:))
            hit.wantsLayer = true
            hit.layer?.backgroundColor = NSColor.clear.cgColor
            row.addSubview(hit, positioned: .below, relativeTo: name)

            row.setFrameOrigin(NSPoint(x: 4, y: y))
            listBox.addSubview(row)
            y += rowH
        }
        listBox.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 8, scroll.contentSize.height))
        // Flip so top jobs are at top of scroll
        if let doc = scroll.documentView {
            doc.frame = listBox.frame
        }
    }

    @objc private func addJob() {
        let owners = seats.map { $0.id }
        let owner = owners.first ?? "c1"
        appendAndEdit(ownerId: owner)
    }

    /// From map `+` menu: open manager with a new job owned by this seat.
    func addJobForOwner(session: String, ownerId: String, seats: [Seat3D], onDone: @escaping () -> Void) {
        show(session: session, seats: seats, onDone: onDone)
        // Defer so the sheet is on-screen before the edit alert.
        DispatchQueue.main.async { [weak self] in
            self?.appendAndEdit(ownerId: ownerId)
        }
    }

    private func appendAndEdit(ownerId: String) {
        let ownerSeat = seats.first(where: { $0.id == ownerId })
        let ownerName = ownerSeat?.title ?? ownerId
        jobs.append(CronSchedule.Job(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            name: "New job",
            task: "Describe what \(ownerName) should do when this fires…",
            cadence: "every 1h",
            intervalSec: 3600,
            phaseSec: 0,
            ownerId: ownerId,
            enabled: true
        ))
        let idx = jobs.count - 1
        // Only persist after the user confirms the edit alert — cancel drops the stub.
        if editJobAt(idx, isNew: true) {
            persist()
            reloadList()
        } else {
            if jobs.indices.contains(idx) { jobs.remove(at: idx) }
            reloadList()
        }
    }

    @objc private func restoreDefaults() {
        jobs = CronSchedule.defaultJobs(session: session)
        persist()
        reloadList()
    }

    @objc private func editJob(_ sender: NSButton) {
        _ = editJobAt(sender.tag, isNew: false)
    }

    /// Returns true if the user saved. For `isNew`, caller owns persist (so cancel leaves no stub).
    @discardableResult
    private func editJobAt(_ idx: Int, isNew: Bool) -> Bool {
        guard jobs.indices.contains(idx) else { return false }
        var j = jobs[idx]
        let ownerSeat = seats.first(where: { $0.id == j.ownerId })
        let ownerName = ownerSeat?.title ?? j.ownerId

        let a = NSAlert()
        a.messageText = isNew ? "New cron job" : "Edit cron job"
        a.informativeText =
            "This task is delivered to the owner agent when it fires.\n" +
            "Owner: \(ownerName) (\(j.ownerId)) — change owner below if needed."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 210))

        let nameL = NSTextField(labelWithString: "Name")
        nameL.font = PongTheme.mono(10)
        nameL.textColor = PongTheme.textTertiary
        nameL.frame = NSRect(x: 0, y: 188, width: 120, height: 14)
        box.addSubview(nameL)
        let nameF = NSTextField(frame: NSRect(x: 0, y: 162, width: 380, height: 24))
        nameF.stringValue = j.name
        nameF.placeholderString = "Short job name"
        box.addSubview(nameF)

        let taskL = NSTextField(labelWithString: "Task for the owner agent")
        taskL.font = PongTheme.mono(10)
        taskL.textColor = PongTheme.textTertiary
        taskL.frame = NSRect(x: 0, y: 140, width: 280, height: 14)
        box.addSubview(taskL)
        let taskScroll = NSScrollView(frame: NSRect(x: 0, y: 72, width: 380, height: 64))
        taskScroll.hasVerticalScroller = true
        taskScroll.borderType = .bezelBorder
        taskScroll.autohidesScrollers = true
        let taskF = NSTextView(frame: NSRect(x: 0, y: 0, width: 364, height: 64))
        taskF.string = j.task
        taskF.font = PongTheme.font(12)
        taskF.isRichText = false
        taskF.drawsBackground = true
        taskF.backgroundColor = PongTheme.bgInput
        taskF.textColor = PongTheme.textPrimary
        taskF.isEditable = true
        taskF.isSelectable = true
        taskScroll.documentView = taskF
        box.addSubview(taskScroll)

        let cadL = NSTextField(labelWithString: "Cadence")
        cadL.font = PongTheme.mono(10)
        cadL.textColor = PongTheme.textTertiary
        cadL.frame = NSRect(x: 0, y: 50, width: 100, height: 14)
        box.addSubview(cadL)
        let cadF = NSTextField(frame: NSRect(x: 0, y: 26, width: 180, height: 24))
        cadF.stringValue = j.cadence
        cadF.placeholderString = "every 15m · daily 04:00"
        box.addSubview(cadF)

        let ownL = NSTextField(labelWithString: "Owner seat")
        ownL.font = PongTheme.mono(10)
        ownL.textColor = PongTheme.textTertiary
        ownL.frame = NSRect(x: 190, y: 50, width: 100, height: 14)
        box.addSubview(ownL)
        let ownPop = NSPopUpButton(frame: NSRect(x: 190, y: 26, width: 100, height: 24), pullsDown: false)
        let seatIds = seats.map(\.id)
        if seatIds.isEmpty {
            ownPop.addItem(withTitle: j.ownerId.isEmpty ? "c1" : j.ownerId)
        } else {
            for seat in seats {
                let title = "\(seat.id) · \(seat.title)"
                ownPop.addItem(withTitle: title)
                ownPop.lastItem?.representedObject = seat.id
            }
            if let ix = seats.firstIndex(where: { $0.id == j.ownerId }) {
                ownPop.selectItem(at: ix)
            }
        }
        box.addSubview(ownPop)

        let minL = NSTextField(labelWithString: "Every (min)")
        minL.font = PongTheme.mono(10)
        minL.textColor = PongTheme.textTertiary
        minL.frame = NSRect(x: 300, y: 50, width: 80, height: 14)
        box.addSubview(minL)
        let minF = NSTextField(frame: NSRect(x: 300, y: 26, width: 80, height: 24))
        minF.stringValue = "\(max(1, Int(j.intervalSec / 60)))"
        minF.placeholderString = "min"
        box.addSubview(minF)

        a.accessoryView = box
        a.window.initialFirstResponder = nameF
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        j.name = nameF.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        j.task = taskF.string.trimmingCharacters(in: .whitespacesAndNewlines)
        j.cadence = cadF.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let oid = ownPop.selectedItem?.representedObject as? String, !oid.isEmpty {
            j.ownerId = oid
        } else if let t = ownPop.titleOfSelectedItem, !t.isEmpty {
            // fallback: first token before ·
            j.ownerId = t.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? j.ownerId
        }
        if let m = Int(minF.stringValue), m > 0 {
            j.intervalSec = TimeInterval(m * 60)
            if j.cadence.lowercased().hasPrefix("daily") == false && j.intervalSec < 86400 {
                // keep user's cadence text if they typed one; else synthesize
                if j.cadence.isEmpty || j.cadence == "hourly" {
                    j.cadence = m >= 60 ? "every \(m / 60)h" : "every \(m)m"
                }
            }
        }
        if j.name.isEmpty { j.name = "Job" }
        if j.ownerId.isEmpty { j.ownerId = "c1" }
        if j.task.isEmpty {
            j.task = "Run scheduled work for \(j.name)."
        }
        jobs[idx] = j
        if !isNew {
            persist()
            reloadList()
        }
        return true
    }

    @objc private func deleteJob(_ sender: NSButton) {
        let idx = sender.tag
        guard jobs.indices.contains(idx) else { return }
        jobs.remove(at: idx)
        persist()
        reloadList()
    }

    private func persist() {
        CronSchedule.save(session: session, jobs: jobs)
    }

    @objc private func donePressed() {
        persist()
        window?.orderOut(nil)
        onDone?()
    }
}

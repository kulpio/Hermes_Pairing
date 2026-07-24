import AppKit

/// Borderless / floating sheets must opt into key-window status or NSTextField
/// never receives a field editor — typing silently fails.
final class PongKeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Editable field that always accepts focus (avoids stack-view first-responder quirks).
final class PongTypingField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// 30-second team create — big recipes, almost no jargon.
/// Replaces the long wizard as the default “New team” path.
enum QuickTeamBuilder {
    private static var window: NSPanel?
    private static var root: NSView?
    private static var step = 0
    private static var recipe: Recipe = .pair
    private static var nameField: NSTextField?
    /// Durable team name — survives re-renders when model chips are tapped.
    private static var teamNameDraft = "My team"
    /// Orchestrator AI (ConductorType ids: grok / claude / hermes).
    private static var conductorType = "grok"
    /// Per-seat worker AI, sized to `recipe.workerCount`.
    private static var workerTypes: [String] = ["claude", "claude"]
    private static var completion: (() -> Void)?
    private static var statusLabel: NSTextField?
    /// Focus name field only once when entering step 1 (not after every chip re-render).
    private static var focusedNameOnStep1 = false

    private static let pillW: CGFloat = 440
    private static var pillH: CGFloat = 360

    private static let workerModelIds = ["claude", "grok", "codex", "hermes"]
    /// Match ConductorType.all (exclude custom).
    private static let conductorModelIds = ["grok", "claude", "hermes"]

    enum Recipe: String {
        case solo   // boss + 1 coder
        case pair   // boss + coder + reviewer
        case squad  // boss + coder + reviewer + operator

        var title: String {
            switch self {
            case .solo: return "Solo"
            case .pair: return "Pair"
            case .squad: return "Squad"
            }
        }

        var blurb: String {
            switch self {
            case .solo: return "You + one builder"
            case .pair: return "Builder + checker"
            case .squad: return "Builder + checker + runner"
            }
        }

        var emoji: String {
            switch self {
            case .solo: return "①"
            case .pair: return "②"
            case .squad: return "③"
            }
        }

        var workerCount: Int {
            switch self {
            case .solo: return 1
            case .pair: return 2
            case .squad: return 3
            }
        }

        var roles: [String] {
            switch self {
            case .solo: return [MissionRole.coder.rawValue]
            case .pair: return [MissionRole.coder.rawValue, MissionRole.reviewer.rawValue]
            case .squad: return [
                MissionRole.coder.rawValue,
                MissionRole.reviewer.rawValue,
                MissionRole.`operator`.rawValue,
            ]
            }
        }

        var labels: [String] {
            switch self {
            case .solo: return ["Builder"]
            case .pair: return ["Builder", "Checker"]
            case .squad: return ["Builder", "Checker", "Runner"]
            }
        }
    }

    static func present(completion: (() -> Void)? = nil) {
        self.completion = completion
        step = 0
        recipe = .pair
        teamNameDraft = "My team"
        conductorType = "grok"
        workerTypes = Array(repeating: "claude", count: recipe.workerCount)
        focusedNameOnStep1 = false

        if let w = window {
            render()
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeKey()
            return
        }

        let win = PongKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: pillW, height: pillH),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = false
        win.hidesOnDeactivate = false
        // false while typing — background drag steals clicks from the name field
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.title = "New team"
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        container.wantsLayer = true
        container.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        container.layer?.cornerRadius = 28
        container.layer?.borderWidth = 1
        container.layer?.borderColor = PongTheme.line.withAlphaComponent(0.4).cgColor
        container.layer?.masksToBounds = true
        win.contentView = NSView(frame: container.bounds)
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView?.addSubview(container)
        container.autoresizingMask = [.width, .height]
        root = container

        let close = NSButton(frame: NSRect(x: pillW - 36, y: pillH - 32, width: 22, height: 22))
        close.bezelStyle = .inline
        close.isBordered = false
        close.title = "✕"
        close.font = PongTheme.font(12, weight: .medium)
        close.contentTintColor = PongTheme.textTertiary
        close.target = QuickTeamTarget.shared
        close.action = #selector(QuickTeamTarget.dismiss)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(close)

        window = win
        render()
        if let screen = NSScreen.main {
            var f = win.frame
            f.origin.x = screen.visibleFrame.midX - f.width / 2
            f.origin.y = screen.visibleFrame.midY - f.height / 2
            win.setFrame(f, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeKey()
        Pong.log("QuickTeamBuilder present")
    }

    /// Pull live field text into durable draft before any re-render that destroys the field.
    private static func syncNameDraftFromField() {
        guard let nameField else { return }
        // Prefer raw stringValue so mid-edit spaces aren't stripped until launch.
        teamNameDraft = nameField.stringValue
    }

    private static func resolvedTeamName() -> String {
        syncNameDraftFromField()
        let t = teamNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "My team" : t
    }

    /// Resize workerTypes to recipe.workerCount, keeping previous choices where possible.
    private static func resizeWorkerTypes() {
        let n = recipe.workerCount
        if workerTypes.count == n { return }
        if workerTypes.count < n {
            let pad = Array(repeating: "claude", count: n - workerTypes.count)
            workerTypes.append(contentsOf: pad)
        } else {
            workerTypes = Array(workerTypes.prefix(n))
        }
    }

    private static func focusNameFieldOnce() {
        guard step == 1, !focusedNameOnStep1, let nameField, let window else { return }
        focusedNameOnStep1 = true
        // Layout must settle before the field editor attaches
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            window.makeFirstResponder(nameField)
            // Select-all only on first entry so user can replace default quickly
            nameField.currentEditor()?.selectAll(nil)
        }
    }

    private static func resize(h: CGFloat) {
        pillH = h
        guard let win = window, let root else { return }
        var f = win.frame
        let old = f.height
        f.size.height = h
        f.origin.y += (old - h)
        win.setFrame(f, display: true, animate: true)
        root.frame = NSRect(x: 0, y: 0, width: pillW, height: h)
        root.layer?.cornerRadius = 28
        // Keep close button pinned after resize
        if let close = root.subviews.first(where: { ($0 as? NSButton)?.title == "✕" }) {
            close.frame = NSRect(x: pillW - 36, y: h - 32, width: 22, height: 22)
        }
    }

    private static func clear() {
        guard let root else { return }
        for v in root.subviews {
            if let b = v as? NSButton, b.title == "✕" { continue }
            v.removeFromSuperview()
        }
    }

    private static func step1Height() -> CGFloat {
        // Base + per worker AI row
        let base: CGFloat = 340
        let perWorker: CGFloat = 52
        return base + CGFloat(recipe.workerCount) * perWorker
    }

    private static func render() {
        clear()
        guard let root else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        if step == 0 {
            resize(h: 380)
            stack.addArrangedSubview(title("New team"))
            stack.addArrangedSubview(sub("Pick a shape. 10 seconds."))

            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            for r in [Recipe.solo, .pair, .squad] {
                row.addArrangedSubview(recipeCard(r))
            }
            stack.addArrangedSubview(row)

            stack.addArrangedSubview(primary("Continue", #selector(QuickTeamTarget.next)))
            stack.addArrangedSubview(ghost("Advanced wizard…", #selector(QuickTeamTarget.advanced)))
        } else if step == 1 {
            resize(h: step1Height())
            stack.addArrangedSubview(title(recipe.title + " team"))
            stack.addArrangedSubview(sub(recipe.blurb + " · Boss plans. Agents build."))

            let name = field("Team name", teamNameDraft.isEmpty ? "My team" : teamNameDraft)
            nameField = name
            stack.addArrangedSubview(name)

            // Orchestrator AI (same step/window as team name)
            stack.addArrangedSubview(rowLabel("Orchestrator AI"))
            let orchRow = NSStackView()
            orchRow.orientation = .horizontal
            orchRow.spacing = 6
            for id in conductorModelIds {
                orchRow.addArrangedSubview(modelChip(id: id, selected: id == conductorType, action: #selector(QuickTeamTarget.pickConductor(_:))))
            }
            stack.addArrangedSubview(orchRow)

            // Per-seat worker AI rows
            for (i, lab) in recipe.labels.enumerated() {
                let type = i < workerTypes.count ? workerTypes[i] : "claude"
                stack.addArrangedSubview(rowLabel("\(lab) AI"))
                let seatRow = NSStackView()
                seatRow.orientation = .horizontal
                seatRow.spacing = 6
                for id in workerModelIds {
                    seatRow.addArrangedSubview(
                        modelChip(
                            id: id,
                            selected: id == type,
                            action: #selector(QuickTeamTarget.pickWorker(_:)),
                            tag: i
                        )
                    )
                }
                stack.addArrangedSubview(seatRow)
            }

            // Roster preview — each seat with its chosen AI
            var lines: [String] = ["· Orchestrator (\(displayName(conductorType)))"]
            for (i, lab) in recipe.labels.enumerated() {
                let t = i < workerTypes.count ? workerTypes[i] : "claude"
                lines.append("· \(lab) (\(displayName(t)))")
            }
            stack.addArrangedSubview(sub(lines.joined(separator: "\n")))

            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 10
            nav.addArrangedSubview(ghost("Back", #selector(QuickTeamTarget.back)))
            nav.addArrangedSubview(primary("Launch 🚀", #selector(QuickTeamTarget.launch)))
            stack.addArrangedSubview(nav)

            let st = sub("")
            statusLabel = st
            stack.addArrangedSubview(st)

            focusNameFieldOnce()
        } else {
            resize(h: 220)
            stack.addArrangedSubview(title("Starting…"))
            let st = sub("Opening terminals · locking roles · drawing the road")
            statusLabel = st
            stack.addArrangedSubview(st)
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        root.layoutSubtreeIfNeeded()
    }

    private static func title(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = PongTheme.font(18, weight: .semibold)
        l.textColor = PongTheme.textPrimary
        l.alignment = .center
        return l
    }

    private static func sub(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = PongTheme.font(12)
        l.textColor = PongTheme.textSecondary
        l.alignment = .center
        l.preferredMaxLayoutWidth = pillW - 48
        l.maximumNumberOfLines = 8
        return l
    }

    private static func rowLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = PongTheme.font(11, weight: .semibold)
        l.textColor = PongTheme.textTertiary
        l.alignment = .center
        return l
    }

    private static func recipeCard(_ r: Recipe) -> NSButton {
        let on = r == recipe
        let b = NSButton(title: "\(r.emoji)\n\(r.title)\n\(r.blurb)", target: QuickTeamTarget.shared, action: #selector(QuickTeamTarget.pickRecipe(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(r.rawValue)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 16
        b.layer?.backgroundColor = (on ? PongSheetChrome.lime : PongTheme.bgHover).cgColor
        b.layer?.borderWidth = on ? 0 : 1
        b.layer?.borderColor = PongTheme.line.cgColor
        b.attributedTitle = NSAttributedString(string: "\(r.emoji)  \(r.title)\n\(r.blurb)", attributes: [
            .foregroundColor: on ? NSColor.black : PongTheme.textPrimary,
            .font: PongTheme.font(12, weight: .semibold),
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                p.lineSpacing = 2
                return p
            }(),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 112).isActive = true
        b.heightAnchor.constraint(equalToConstant: 88).isActive = true
        return b
    }

    private static func modelChip(
        id: String,
        selected: Bool,
        action: Selector,
        tag: Int = 0
    ) -> NSButton {
        let label = displayName(id)
        let b = NSButton(title: label, target: QuickTeamTarget.shared, action: action)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.tag = tag
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.layer?.backgroundColor = (selected ? PongSheetChrome.lime : PongTheme.bgHover).cgColor
        b.attributedTitle = NSAttributedString(string: label, attributes: [
            .foregroundColor: selected ? NSColor.black : PongTheme.textPrimary,
            .font: PongTheme.font(11, weight: .semibold),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 68).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private static func displayName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "grok": return "Grok"
        case "codex": return "Codex"
        case "hermes": return "Hermes"
        default: return id
        }
    }

    private static func field(_ ph: String, _ val: String) -> NSTextField {
        let f = PongTypingField(string: val)
        f.placeholderString = ph
        f.font = PongTheme.font(14)
        f.isBordered = false
        f.isBezeled = false
        f.isEditable = true
        f.isSelectable = true
        f.isEnabled = true
        f.drawsBackground = true
        f.backgroundColor = PongTheme.bgInput
        f.textColor = PongTheme.textPrimary
        f.focusRingType = .exterior
        f.refusesFirstResponder = false
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.wantsLayer = true
        f.layer?.cornerRadius = 12
        f.layer?.backgroundColor = PongTheme.bgInput.cgColor
        // Inset text inside the rounded field
        if let cell = f.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
        }
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: pillW - 56).isActive = true
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return f
    }

    private static func primary(_ t: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: QuickTeamTarget.shared, action: sel)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 16
        b.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        b.layer?.masksToBounds = true
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(14, weight: .semibold),
        ])
        // Return still launches, but do not steal focus from the name field on click
        b.keyEquivalent = "\r"
        b.refusesFirstResponder = true
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 160).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private static func ghost(_ t: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: QuickTeamTarget.shared, action: sel)
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = PongTheme.font(11)
        b.contentTintColor = PongTheme.textTertiary
        return b
    }

    // MARK: Actions

    fileprivate static func pickRecipe(_ id: String) {
        syncNameDraftFromField()
        recipe = Recipe(rawValue: id) ?? .pair
        resizeWorkerTypes()
        render()
    }

    fileprivate static func pickConductor(_ id: String) {
        syncNameDraftFromField()
        conductorType = id
        render()
    }

    fileprivate static func pickWorker(seat: Int, id: String) {
        syncNameDraftFromField()
        resizeWorkerTypes()
        if seat >= 0, seat < workerTypes.count {
            workerTypes[seat] = id
        }
        render()
    }

    fileprivate static func goNext() {
        syncNameDraftFromField()
        step = 1
        resizeWorkerTypes()
        focusedNameOnStep1 = false
        render()
    }

    fileprivate static func goBack() {
        syncNameDraftFromField()
        step = 0
        focusedNameOnStep1 = false
        render()
    }

    fileprivate static func launch() {
        let teamName = resolvedTeamName()
        teamNameDraft = teamName
        resizeWorkerTypes()
        step = 2
        render()

        var types = workerTypes
        while types.count < recipe.workerCount { types.append("claude") }
        if types.count > recipe.workerCount {
            types = Array(types.prefix(recipe.workerCount))
        }

        let plan = AppAIMutator.FirstTeamPlan(
            teamName: teamName,
            projectRoot: "",
            teamBrief: "\(recipe.title) team — \(recipe.blurb)",
            conductorId: conductorType,
            workerTypes: types,
            missionRoles: recipe.roles,
            workerLabels: recipe.labels
        )
        Pong.log("QuickTeamBuilder.launch name=\(teamName) conductor=\(conductorType) workers=\(types.joined(separator: ","))")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppAIMutator.apply([.createFirstTeam(plan: plan)])
            if let sess = result.session {
                TerminalTheme.applyPair(sess)
            }
            DispatchQueue.main.async {
                if result.failed.isEmpty {
                    close()
                    PanelController.shared.refreshUI()
                    PanelController.shared.ensure3DVisible()
                    AppAIChatBubble.shared.attachIfNeeded()
                    AppAIChatBubble.shared.nudge("Team live · \(teamName)")
                    MapCoachMarks.presentIfNeeded()
                    completion?()
                } else {
                    statusLabel?.stringValue = result.failed.map(\.1).joined(separator: "\n")
                    step = 1
                    focusedNameOnStep1 = false
                    render()
                }
            }
        }
    }

    fileprivate static func openAdvanced() {
        close()
        // Old multi-step wizard for power users
        guard let (conductor, workers) = AppDelegate.pickTeamLaunch() else {
            completion?()
            return
        }
        TeamInstallWizard.shared.run(conductor: conductor, workers: workers, onFinish: { plan in
            DispatchQueue.global(qos: .userInitiated).async {
                let name = Pairing.startFresh(
                    workers: plan.workers.map(\.type),
                    conductor: plan.conductor
                )
                usleep(300_000)
                TeamWizardApply.apply(plan, session: name)
                usleep(400_000)
                TerminalTheme.applyPair(name)
                DispatchQueue.main.async {
                    PanelController.showPairPersistTip(name)
                    PanelController.shared.refreshUI()
                    completion?()
                }
            }
        }, onCancel: {
            completion?()
        })
    }

    fileprivate static func close() {
        window?.close()
        window = nil
        root = nil
        nameField = nil
        focusedNameOnStep1 = false
    }

    fileprivate static func dismiss() {
        syncNameDraftFromField()
        close()
        completion?()
    }
}

final class QuickTeamTarget: NSObject {
    static let shared = QuickTeamTarget()

    @objc func next() { QuickTeamBuilder.goNext() }
    @objc func back() { QuickTeamBuilder.goBack() }
    @objc func launch() { QuickTeamBuilder.launch() }
    @objc func dismiss() { QuickTeamBuilder.dismiss() }
    @objc func advanced() { QuickTeamBuilder.openAdvanced() }

    @objc func pickRecipe(_ sender: NSButton) {
        QuickTeamBuilder.pickRecipe(sender.identifier?.rawValue ?? "pair")
    }

    @objc func pickConductor(_ sender: NSButton) {
        QuickTeamBuilder.pickConductor(sender.identifier?.rawValue ?? "grok")
    }

    @objc func pickWorker(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "claude"
        QuickTeamBuilder.pickWorker(seat: sender.tag, id: id)
    }
}

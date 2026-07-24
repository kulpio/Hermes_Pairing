import AppKit

/// Elegant pill-shaped CyberPong Guide — short steps, essential only.
/// Flow: welcome → AI pick → login Terminal → first team → done.
enum AppAIOnboarding {
    private static var window: NSPanel?
    private static var root: NSView?
    private static var step = 0
    private static var selectedProvider: AppAISettings.Provider = .named("grok")
    private static var teamNameField: NSTextField?
    private static var briefField: NSTextField?
    private static var reviewerOn = true
    private static var statusLabel: NSTextField?
    private static var pillW: CGFloat = 400
    private static var pillH: CGFloat = 300

    static var isPresenting: Bool { window?.isVisible == true }

    static func presentIfNeeded(force: Bool = false) {
        if !force, AppAISettings.onboardingComplete, AppAISettings.providerId != nil {
            return
        }
        present()
    }

    static func present() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeKey()
            return
        }
        step = 0
        selectedProvider = AppAISettings.provider ?? .named("grok")

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
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.title = "CyberPong Guide"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        container.wantsLayer = true
        container.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        container.layer?.cornerRadius = 28
        container.layer?.borderWidth = 1
        container.layer?.borderColor = PongTheme.line.withAlphaComponent(0.45).cgColor
        container.layer?.masksToBounds = true
        // Soft outer glow
        win.contentView = NSView(frame: container.bounds)
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView?.addSubview(container)
        container.autoresizingMask = [.width, .height]
        root = container

        // Close affordance
        let close = NSButton(frame: NSRect(x: pillW - 36, y: pillH - 32, width: 22, height: 22))
        close.bezelStyle = .inline
        close.isBordered = false
        close.title = "✕"
        close.font = PongTheme.font(12, weight: .medium)
        close.contentTintColor = PongTheme.textTertiary
        close.target = AppAIOnboardingTarget.shared
        close.action = #selector(AppAIOnboardingTarget.dismiss)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(close)

        window = win
        renderStep()
        positionNearPanel()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeKey()
        Pong.log("AppAIOnboarding pill present")
    }

    private static func positionNearPanel() {
        guard let win = window, let screen = NSScreen.main else { return }
        // Center-right so 3D map stays visible
        var f = win.frame
        f.origin.x = screen.visibleFrame.midX + 80
        f.origin.y = screen.visibleFrame.midY - f.height / 2
        // Clamp
        f.origin.x = min(f.origin.x, screen.visibleFrame.maxX - f.width - 24)
        f.origin.y = max(screen.visibleFrame.minY + 40, f.origin.y)
        win.setFrame(f, display: true)
    }

    private static func resizePill(height: CGFloat) {
        pillH = height
        guard let win = window, let root else { return }
        var f = win.frame
        let oldH = f.height
        f.size.height = height
        f.size.width = pillW
        f.origin.y += (oldH - height) // keep top stable-ish
        win.setFrame(f, display: true, animate: true)
        root.frame = NSRect(x: 0, y: 0, width: pillW, height: height)
        root.layer?.cornerRadius = min(28, height / 2.4)
    }

    private static func clearBody() {
        guard let root else { return }
        for v in root.subviews {
            if let b = v as? NSButton, b.title == "✕" { continue }
            v.removeFromSuperview()
        }
    }

    private static func titleLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = PongTheme.font(16, weight: .semibold)
        l.textColor = PongTheme.textPrimary
        l.alignment = .center
        return l
    }

    private static func subLabel(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = PongTheme.font(12)
        l.textColor = PongTheme.textSecondary
        l.alignment = .center
        l.preferredMaxLayoutWidth = pillW - 48
        l.maximumNumberOfLines = 3
        return l
    }

    private static func primaryBtn(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: AppAIOnboardingTarget.shared, action: sel)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 16
        b.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        b.layer?.masksToBounds = true
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(13, weight: .semibold),
        ])
        b.keyEquivalent = "\r"
        // Explicit size so title never overflows the lime pill
        let w = max(96, CGFloat(title.count) * 8.5 + 28)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: min(200, w)).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    private static func ghostBtn(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: AppAIOnboardingTarget.shared, action: sel)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongTheme.line.cgColor
        b.layer?.masksToBounds = true
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.font(12, weight: .medium),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 80).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    private static func dots(active: Int, total: Int = 5) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        for i in 0..<total {
            let d = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
            d.wantsLayer = true
            d.layer?.cornerRadius = 3
            d.layer?.backgroundColor = (i == active
                ? PongSheetChrome.lime
                : PongTheme.lineSoft).cgColor
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: i == active ? 14 : 6).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            row.addArrangedSubview(d)
        }
        return row
    }

    private static func renderStep() {
        clearBody()
        guard let root else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        switch step {
        case 0: // welcome
            resizePill(height: 260)
            stack.addArrangedSubview(dots(active: 0))
            stack.addArrangedSubview(titleLabel("CyberPong"))
            stack.addArrangedSubview(subLabel("Mission control for AI teams.\nPick a guide · build your first team."))
            stack.addArrangedSubview(primaryBtn("Start", #selector(AppAIOnboardingTarget.next)))
        case 1: // provider
            resizePill(height: 320)
            stack.addArrangedSubview(dots(active: 1))
            stack.addArrangedSubview(titleLabel("Your guide AI"))
            stack.addArrangedSubview(subLabel("Used only inside CyberPong."))
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for p in AppAISettings.Provider.all {
                let b = pillChoice(p)
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 10
            nav.addArrangedSubview(ghostBtn("Back", #selector(AppAIOnboardingTarget.back)))
            nav.addArrangedSubview(primaryBtn("Continue", #selector(AppAIOnboardingTarget.next)))
            stack.addArrangedSubview(nav)
        case 2: // login
            resizePill(height: 320)
            stack.addArrangedSubview(dots(active: 2))
            stack.addArrangedSubview(titleLabel("Sign in · \(selectedProvider.label)"))
            stack.addArrangedSubview(subLabel("Terminal opens to log in / pick a model.\nAfter sign-in it’s safe to close that window.\nPrefer: tap I’m signed in — we close it for you."))
            stack.addArrangedSubview(primaryBtn("Open \(selectedProvider.label)", #selector(AppAIOnboardingTarget.openLogin)))
            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 10
            nav.addArrangedSubview(ghostBtn("Back", #selector(AppAIOnboardingTarget.back)))
            nav.addArrangedSubview(primaryBtn("I’m signed in", #selector(AppAIOnboardingTarget.confirmLogin)))
            stack.addArrangedSubview(nav)
            let st = subLabel("")
            st.stringValue = ""
            statusLabel = st
            stack.addArrangedSubview(st)
        case 3: // first team → hand off to 30s Quick Team (same UX as New team)
            resizePill(height: 280)
            stack.addArrangedSubview(dots(active: 3))
            stack.addArrangedSubview(titleLabel("First team"))
            stack.addArrangedSubview(subLabel("Pick Solo, Pair, or Squad — under 30 seconds.\n(Advanced wizard is optional later.)"))
            stack.addArrangedSubview(primaryBtn("Build team", #selector(AppAIOnboardingTarget.createTeam)))
            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 10
            nav.addArrangedSubview(ghostBtn("Back", #selector(AppAIOnboardingTarget.back)))
            stack.addArrangedSubview(nav)
        case 4: // creating
            resizePill(height: 200)
            stack.addArrangedSubview(dots(active: 4))
            stack.addArrangedSubview(titleLabel("Launching…"))
            let st = subLabel("Roles · architecture road · terminals")
            statusLabel = st
            stack.addArrangedSubview(st)
        default: // done
            resizePill(height: 240)
            stack.addArrangedSubview(dots(active: 4))
            stack.addArrangedSubview(titleLabel("You’re live"))
            stack.addArrangedSubview(subLabel("Map chat · bottom-right sparkle.\nRoles stay locked on every job."))
            stack.addArrangedSubview(primaryBtn("Open map", #selector(AppAIOnboardingTarget.finish)))
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
    }

    private static func pillChoice(_ p: AppAISettings.Provider) -> NSButton {
        let selected = p.id == selectedProvider.id
        let b = NSButton(title: p.label, target: AppAIOnboardingTarget.shared, action: #selector(AppAIOnboardingTarget.pickProvider(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(p.id)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 18
        b.layer?.backgroundColor = (selected ? PongSheetChrome.lime : PongTheme.bgHover).cgColor
        b.attributedTitle = NSAttributedString(string: p.label, attributes: [
            .foregroundColor: selected ? NSColor.black : PongTheme.textPrimary,
            .font: PongTheme.font(12, weight: .semibold),
        ])
        b.toolTip = p.blurb
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 96).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    private static func field(_ placeholder: String, _ value: String) -> NSTextField {
        let f = PongTypingField(string: value)
        f.placeholderString = placeholder
        f.font = PongTheme.font(14)
        f.isBordered = false
        f.isBezeled = false
        f.isEditable = true
        f.isSelectable = true
        f.isEnabled = true
        f.drawsBackground = true
        f.backgroundColor = PongTheme.bgInput
        f.textColor = PongTheme.textPrimary
        f.refusesFirstResponder = false
        f.wantsLayer = true
        f.layer?.cornerRadius = 12
        f.layer?.backgroundColor = PongTheme.bgInput.cgColor
        f.focusRingType = .exterior
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: pillW - 56).isActive = true
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return f
    }

    // MARK: - Actions

    fileprivate static func goNext() {
        if step == 1 {
            AppAISettings.setProvider(selectedProvider)
        }
        step += 1
        renderStep()
    }

    fileprivate static func goBack() {
        step = max(0, step - 1)
        renderStep()
    }

    fileprivate static func selectProvider(id: String) {
        selectedProvider = AppAISettings.Provider.named(id)
        AppAISettings.setProvider(selectedProvider)
        renderStep()
    }

    fileprivate static func openLogin() {
        AppAISettings.setProvider(selectedProvider)
        statusLabel?.stringValue = "Opening Terminal…"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppAIRuntime.openLoginTerminal(provider: selectedProvider)
            DispatchQueue.main.async {
                statusLabel?.stringValue = "Sign in there · safe to close after · or tap I’m signed in"
            }
        }
    }

    fileprivate static func confirmLogin() {
        statusLabel?.stringValue = "Closing Terminal · enabling headless…"
        AppAIRuntime.completeLogin { ok, msg in
            statusLabel?.stringValue = msg
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    step = 3
                    renderStep()
                }
            }
        }
    }

    fileprivate static func setReviewer(_ on: Bool) { reviewerOn = on }

    fileprivate static func runCreateTeam() {
        // Close pill and use the same 30s Quick Team builder as “New team”
        dismiss()
        AppAISettings.markOnboardingComplete()
        QuickTeamBuilder.present {
            PanelController.shared.refreshUI()
            PanelController.shared.ensure3DVisible()
            AppAIChatBubble.shared.attachIfNeeded()
            AppAIChatBubble.shared.nudge("Team live. Ask me anything.")
            MapCoachMarks.presentIfNeeded()
        }
    }

    fileprivate static func closeDone() {
        window?.close()
        window = nil
        root = nil
        PanelController.shared.show()
        PanelController.shared.ensure3DVisible()
        PanelController.shared.refreshUI()
        AppAIChatBubble.shared.attachIfNeeded()
        AppAIChatBubble.shared.nudge("Guide ready · hover the sparkle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MapCoachMarks.presentIfNeeded()
        }
        Pong.log("AppAIOnboarding finished")
    }

    fileprivate static func dismiss() {
        AppAIRuntime.closeLoginTerminal()
        window?.close()
        window = nil
        root = nil
    }
}

final class AppAIOnboardingTarget: NSObject {
    static let shared = AppAIOnboardingTarget()

    @objc func next() { AppAIOnboarding.goNext() }
    @objc func back() { AppAIOnboarding.goBack() }
    @objc func finish() { AppAIOnboarding.closeDone() }
    @objc func dismiss() { AppAIOnboarding.dismiss() }

    @objc func pickProvider(_ sender: NSButton) {
        AppAIOnboarding.selectProvider(id: sender.identifier?.rawValue ?? "grok")
    }

    @objc func openLogin() { AppAIOnboarding.openLogin() }
    @objc func confirmLogin() { AppAIOnboarding.confirmLogin() }
    @objc func createTeam() { AppAIOnboarding.runCreateTeam() }
    @objc func toggleReviewer(_ sender: NSButton) {
        AppAIOnboarding.setReviewer(sender.state == .on)
    }
}

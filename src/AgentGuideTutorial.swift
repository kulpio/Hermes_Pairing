import AppKit
import QuartzCore

/// Guided walkthrough after adding an agent: rename → options → links → cron → MCP.
enum AgentGuideTutorial {
    private static var window: NSWindow?
    private static var step = 0
    private static var session = ""
    private static var seatId = ""
    private static var root: NSView?

    private static let steps: [(title: String, body: String)] = [
        (
            "Name your agents",
            "How do you want to name them?\n"
                + "Tip: use job names — Coder, Reviewer, Ops — not model names.\n"
                + "Click the seat → pencil / Rename."
        ),
        (
            "Options & permissions",
            "Each agent can have its own rules.\n"
                + "Open the seat → Opts or Policy.\n"
                + "You can ban MCP tools, network, or limit to the project folder."
        ),
        (
            "Add more agents",
            "Use the + pad next to a seat (or under a coder for a helper).\n"
                + "Plus beside the boss = new teammate.\n"
                + "Plus under a coder = helper that reports to them."
        ),
        (
            "Draw the road",
            "Open Architecture.\n"
                + "Boss gives work → agent.\n"
                + "Agent sends result back → boss.\n"
                + "Helpers hang under their parent. Drag links so they stick."
        ),
        (
            "Timers & tools",
            "Cron = scheduled jobs for one agent.\n"
                + "MCP tools can be limited to ONE model (e.g. only Hermes).\n"
                + "Check Setup → Access for who has tools, env, and bans."
        ),
    ]

    static func present(session: String, seatId: String) {
        self.session = session
        self.seatId = seatId
        step = 0
        if window == nil { buildWindow() }
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pulseHighlight()
    }

    private static func buildWindow() {
        let w: CGFloat = 360
        let h: CGFloat = 220
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        box.layer?.cornerRadius = 22
        box.layer?.borderWidth = 1
        box.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.45).cgColor
        win.contentView = NSView(frame: box.bounds)
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView?.addSubview(box)
        box.autoresizingMask = [.width, .height]
        root = box
        window = win
        if let screen = NSScreen.main {
            var f = win.frame
            f.origin.x = screen.visibleFrame.midX - w / 2
            f.origin.y = screen.visibleFrame.minY + 80
            win.setFrame(f, display: true)
        }
    }

    private static func render() {
        guard let root else { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        let s = steps[min(step, steps.count - 1)]

        let title = NSTextField(labelWithString: s.title)
        title.font = PongTheme.font(15, weight: .semibold)
        title.textColor = PongTheme.textPrimary
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: s.body)
        body.font = PongTheme.font(12)
        body.textColor = PongTheme.textSecondary
        body.alignment = .center
        body.preferredMaxLayoutWidth = 300
        body.translatesAutoresizingMaskIntoConstraints = false

        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 5
        dots.translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<steps.count {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 3
            d.layer?.backgroundColor = (i == step ? PongSheetChrome.lime : PongTheme.lineSoft).cgColor
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: i == step ? 12 : 6).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(d)
        }

        let next = NSButton(title: step + 1 >= steps.count ? "Done" : "Next",
                            target: AgentGuideTarget.shared,
                            action: #selector(AgentGuideTarget.next))
        stylePrimary(next)
        let skip = NSButton(title: "Skip", target: AgentGuideTarget.shared, action: #selector(AgentGuideTarget.skip))
        styleGhost(skip)

        let nav = NSStackView(views: [skip, next])
        nav.orientation = .horizontal
        nav.spacing = 10
        nav.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [dots, title, body, nav])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        pulseHighlight()
    }

    private static func stylePrimary(_ b: NSButton) {
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: NSColor.black, .font: PongTheme.font(12, weight: .semibold),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 88).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private static func styleGhost(_ b: NSButton) {
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongTheme.line.cgColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: PongTheme.textPrimary, .font: PongTheme.font(12),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 72).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    /// Soft pulse on map selection for the new seat.
    private static func pulseHighlight() {
        NotificationCenter.default.post(
            name: .agentGuideHighlight,
            object: nil,
            userInfo: ["session": session, "seatId": seatId, "step": step]
        )
    }

    fileprivate static func goNext() {
        if step + 1 >= steps.count {
            close()
            return
        }
        step += 1
        render()
    }

    fileprivate static func close() {
        window?.close()
        window = nil
        root = nil
        NotificationCenter.default.post(name: .agentGuideHighlight, object: nil, userInfo: ["clear": true])
    }
}

extension Notification.Name {
    static let agentGuideHighlight = Notification.Name("PongAgentGuideHighlight")
}

final class AgentGuideTarget: NSObject {
    static let shared = AgentGuideTarget()
    @objc func next() { AgentGuideTutorial.goNext() }
    @objc func skip() { AgentGuideTutorial.close() }
}

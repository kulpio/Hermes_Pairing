import AppKit
import QuartzCore

/// Minimalist Guide chat on the 3D map — FAB that grows on hover / nudge.
/// On disconnect: shows reconnect strip → login Terminal → headless again.
final class AppAIChatBubble: NSView {
    static let shared = AppAIChatBubble()

    private let fab = NSButton(frame: .zero)
    private let panel = NSView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "GUIDE")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let input = NSTextField(frame: .zero)
    private let sendBtn = NSButton(frame: .zero)
    private let nudgeChip = NSTextField(labelWithString: "")
    /// Disconnect / reconnect strip above the input
    private let reconnectBar = NSView(frame: .zero)
    private let reconnectLabel = NSTextField(wrappingLabelWithString: "")
    private let reconnectBtn = NSButton(frame: .zero)
    /// Coach / Apply action strip (ghost seats, spawn sub, chat intents)
    private let actionBar = NSView(frame: .zero)
    private let actionLabel = NSTextField(wrappingLabelWithString: "")
    private let actionBtn = NSButton(frame: .zero)
    private let actionBtn2 = NSButton(frame: .zero)
    private var actionHandler: (() -> Void)?
    private var secondaryHandler: (() -> Void)?
    private var pendingIntents: [AppAIMutator.Intent] = []
    private var expanded = false
    private var hovering = false
    private var busy = false
    private var attachedTo: NSView?
    private var nudgeHideWork: DispatchWorkItem?
    /// reconnectIdle | awaitingSignIn | connecting
    private var reconnectPhase: ReconnectPhase = .hidden
    /// Cap transcript so Guide never becomes a novel.
    private let maxTranscriptChars = 6_000

    private enum ReconnectPhase {
        case hidden
        case needsReconnect
        case awaitingSignIn
        case connecting
    }

    /// Collapsed FAB size · expanded panel
    private let fabSize: CGFloat = 44
    private let panelW: CGFloat = 300
    private let panelH: CGFloat = 380
    private let pad: CGFloat = 16
    private let reconnectBarH: CGFloat = 80
    private let actionBarH: CGFloat = 72

    private override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func attachIfNeeded(to host: NSView? = nil) {
        let target = host ?? PanelController.shared.mapHostView()
        guard let target else { return }
        if attachedTo === target, superview === target { layoutInHost(); return }
        removeFromSuperview()
        attachedTo = target
        target.addSubview(self)
        layoutInHost()
        isHidden = false
        target.addSubview(self, positioned: .above, relativeTo: nil)
        // If already offline from a prior session, offer reconnect when first attached
        if !AppAIRuntime.isHeadlessReady, AppAISettings.providerId != nil {
            showDisconnected(
                userFacing: "Guide is offline. Open sign-in Terminal, then tap I’m signed in (safe to close that window after).",
                expand: false
            )
        }
    }

    func layoutInHost() {
        guard let host = superview else { return }
        let w = host.bounds.width
        if expanded {
            frame = NSRect(
                x: w - panelW - pad,
                y: pad + 36,
                width: panelW,
                height: panelH
            )
            panel.isHidden = false
            fab.isHidden = true
            nudgeChip.isHidden = true
        } else {
            let grow: CGFloat = (hovering ? 6 : 0)
            let s = fabSize + grow
            frame = NSRect(
                x: w - s - pad,
                y: pad + 36,
                width: s + (nudgeChip.isHidden ? 0 : 160),
                height: max(s, nudgeChip.isHidden ? s : 52)
            )
            panel.isHidden = true
            fab.isHidden = false
            fab.frame = NSRect(x: frame.width - s, y: 0, width: s, height: s)
            fab.layer?.cornerRadius = s / 2
        }
        autoresizingMask = [.minXMargin, .maxYMargin]
    }

    private func build() {
        fab.bezelStyle = .inline
        fab.isBordered = false
        fab.wantsLayer = true
        fab.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        fab.layer?.borderWidth = 1
        fab.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.55).cgColor
        fab.layer?.cornerRadius = fabSize / 2
        fab.layer?.shadowColor = PongSheetChrome.lime.cgColor
        fab.layer?.shadowOpacity = 0.35
        fab.layer?.shadowRadius = 10
        fab.layer?.shadowOffset = .zero
        fab.toolTip = "CyberPong Guide"
        fab.target = self
        fab.action = #selector(toggleExpand)
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            fab.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Guide")?
                .withSymbolConfiguration(cfg)
            fab.contentTintColor = PongSheetChrome.lime
            fab.imagePosition = .imageOnly
        } else {
            fab.title = "✦"
        }
        addSubview(fab)

        nudgeChip.isHidden = true
        nudgeChip.font = PongTheme.font(11, weight: .medium)
        nudgeChip.textColor = PongTheme.textPrimary
        nudgeChip.backgroundColor = .clear
        nudgeChip.isBezeled = false
        nudgeChip.drawsBackground = false
        nudgeChip.lineBreakMode = .byTruncatingTail
        addSubview(nudgeChip)

        panel.wantsLayer = true
        panel.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = PongTheme.line.withAlphaComponent(0.4).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.45
        panel.layer?.shadowRadius = 16
        panel.isHidden = true
        addSubview(panel)

        titleLabel.font = PongTheme.labelFont(10)
        titleLabel.textColor = PongSheetChrome.limeDim
        panel.addSubview(titleLabel)

        let close = NSButton(title: "✕", target: self, action: #selector(collapse))
        close.bezelStyle = .inline
        close.isBordered = false
        close.font = PongTheme.font(11)
        close.contentTintColor = PongTheme.textTertiary
        close.frame = NSRect(x: panelW - 28, y: panelH - 28, width: 20, height: 20)
        close.identifier = NSUserInterfaceItemIdentifier("close")
        panel.addSubview(close)

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.font = PongTheme.font(12)
        transcript.textColor = PongTheme.textPrimary
        transcript.backgroundColor = .clear
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = transcript
        panel.addSubview(scroll)

        // Reconnect strip
        reconnectBar.wantsLayer = true
        reconnectBar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        reconnectBar.layer?.cornerRadius = 10
        reconnectBar.layer?.borderWidth = 1
        reconnectBar.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        reconnectBar.isHidden = true
        panel.addSubview(reconnectBar)

        reconnectLabel.font = PongTheme.font(11)
        reconnectLabel.textColor = PongTheme.textPrimary
        reconnectLabel.maximumNumberOfLines = 3
        reconnectLabel.isEditable = false
        reconnectLabel.isBezeled = false
        reconnectLabel.drawsBackground = false
        reconnectBar.addSubview(reconnectLabel)

        reconnectBtn.bezelStyle = .inline
        reconnectBtn.isBordered = false
        reconnectBtn.wantsLayer = true
        reconnectBtn.layer?.cornerRadius = 8
        reconnectBtn.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        reconnectBtn.target = self
        reconnectBtn.action = #selector(reconnectPressed)
        styleReconnectButton(title: "Reconnect")
        reconnectBar.addSubview(reconnectBtn)

        // Coach Apply strip
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = PongSheetChrome.lime.withAlphaComponent(0.10).cgColor
        actionBar.layer?.cornerRadius = 10
        actionBar.layer?.borderWidth = 1
        actionBar.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.35).cgColor
        actionBar.isHidden = true
        panel.addSubview(actionBar)

        actionLabel.font = PongTheme.font(11)
        actionLabel.textColor = PongTheme.textPrimary
        actionLabel.maximumNumberOfLines = 2
        actionLabel.isEditable = false
        actionLabel.isBezeled = false
        actionLabel.drawsBackground = false
        actionBar.addSubview(actionLabel)

        actionBtn.bezelStyle = .inline
        actionBtn.isBordered = false
        actionBtn.wantsLayer = true
        actionBtn.layer?.cornerRadius = 8
        actionBtn.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        actionBtn.target = self
        actionBtn.action = #selector(actionPressed)
        styleActionButton(title: "Apply")
        actionBar.addSubview(actionBtn)

        actionBtn2.bezelStyle = .inline
        actionBtn2.isBordered = false
        actionBtn2.wantsLayer = true
        actionBtn2.layer?.cornerRadius = 8
        actionBtn2.layer?.backgroundColor = PongTheme.bgHover.cgColor
        actionBtn2.layer?.borderWidth = 1
        actionBtn2.layer?.borderColor = PongTheme.border.cgColor
        actionBtn2.target = self
        actionBtn2.action = #selector(secondaryActionPressed)
        actionBtn2.isHidden = true
        actionBar.addSubview(actionBtn2)

        input.placeholderString = "Ask Guide…"
        input.font = PongTheme.font(12)
        input.isBordered = false
        input.wantsLayer = true
        input.layer?.cornerRadius = 10
        input.layer?.backgroundColor = PongTheme.bgInput.cgColor
        input.focusRingType = .none
        input.target = self
        input.action = #selector(send)
        panel.addSubview(input)

        sendBtn.bezelStyle = .inline
        sendBtn.isBordered = false
        sendBtn.wantsLayer = true
        sendBtn.layer?.cornerRadius = 10
        sendBtn.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        sendBtn.attributedTitle = NSAttributedString(string: "↑", attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(14, weight: .bold),
        ])
        sendBtn.target = self
        sendBtn.action = #selector(send)
        panel.addSubview(sendBtn)

        let track = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        fab.addTrackingArea(track)

        appendLocal("Guide · ask about this team or map.")
    }

    private func styleReconnectButton(title: String) {
        reconnectBtn.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(11, weight: .semibold),
        ])
    }

    private func styleActionButton(title: String) {
        actionBtn.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(11, weight: .semibold),
        ])
    }

    override func layout() {
        super.layout()
        if expanded {
            panel.frame = bounds
            titleLabel.frame = NSRect(x: 14, y: panelH - 28, width: 160, height: 16)
            let reconOn = !reconnectBar.isHidden
            let actOn = !actionBar.isHidden
            let reconH: CGFloat = reconOn ? reconnectBarH : 0
            let actH: CGFloat = actOn ? actionBarH : 0
            let gap: CGFloat = (reconOn || actOn) ? 6 : 0
            let bottomChrome = reconH + actH + (reconOn && actOn ? 6 : 0) + gap
            scroll.frame = NSRect(
                x: 8, y: 48 + bottomChrome,
                width: panelW - 16,
                height: max(60, panelH - 84 - bottomChrome)
            )
            var yBar: CGFloat = 44
            if reconOn {
                reconnectBar.frame = NSRect(x: 10, y: yBar, width: panelW - 20, height: reconnectBarH)
                reconnectLabel.frame = NSRect(x: 10, y: 30, width: panelW - 40, height: 36)
                reconnectBtn.frame = NSRect(x: 10, y: 6, width: 168, height: 24)
                yBar += reconnectBarH + 6
            }
            if actOn {
                actionBar.frame = NSRect(x: 10, y: yBar, width: panelW - 20, height: actionBarH)
                actionLabel.frame = NSRect(x: 10, y: 36, width: panelW - 40, height: 28)
                actionBtn.frame = NSRect(x: 10, y: 6, width: 120, height: 24)
                if !actionBtn2.isHidden {
                    actionBtn2.frame = NSRect(x: 136, y: 6, width: 110, height: 24)
                }
            }
            input.frame = NSRect(x: 10, y: 10, width: panelW - 52, height: 30)
            sendBtn.frame = NSRect(x: panelW - 38, y: 10, width: 28, height: 30)
            if let close = panel.subviews.first(where: { $0.identifier?.rawValue == "close" }) {
                close.frame = NSRect(x: panelW - 28, y: panelH - 28, width: 20, height: 20)
            }
        } else if !nudgeChip.isHidden {
            let s = fab.frame.width
            nudgeChip.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: bounds.width - s - 10, height: 16)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !expanded {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                layoutInHost()
            }
            pulseFab(strong: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !expanded {
            layoutInHost()
            pulseFab(strong: false)
        }
    }

    private func pulseFab(strong: Bool) {
        fab.layer?.shadowOpacity = strong ? 0.7 : 0.35
        fab.layer?.shadowRadius = strong ? 14 : 10
    }

    @objc private func toggleExpand() {
        expanded = true
        layoutInHost()
        needsLayout = true
        layout()
        window?.makeFirstResponder(input)
    }

    @objc private func collapse() {
        expanded = false
        layoutInHost()
    }

    /// Expand Guide and seed a cron-creation conversation (chat-first schedule path).
    func beginCronWizard(session: String?, ownerHint: String? = nil, seatLabels: [String] = []) {
        attachIfNeeded()
        expanded = true
        layoutInHost()
        let sess = session ?? PairState.listPairs().first ?? "(current team)"
        let seats = seatLabels.isEmpty ? "c1 / w1…" : seatLabels.joined(separator: ", ")
        let ownerLine = ownerHint.map { " Prefer owner seat `\($0)` unless the user picks another." } ?? ""
        let intro =
            "Help me schedule a cron for team `\(sess)`. Seats: \(seats)." +
            ownerLine +
            " Ask what should run, which seat owns it, and how often." +
            " When ready, emit one line the app can Apply:\n" +
            "CREATE_CRON name=\"…\" owner=w1 cadence=\"every 15m\" task=\"…\""
        appendLocal("Guide: Let's set up a schedule. Tell me what should run, who owns it, and how often.")
        window?.makeFirstResponder(input)
        // Seed headless with the structured brief so Guide asks the right questions
        if AppAIRuntime.isHeadlessReady, !busy {
            busy = true
            sendBtn.isEnabled = false
            AppAIRuntime.chat(userMessage: intro) { [weak self] result in
                guard let self else { return }
                self.busy = false
                self.sendBtn.isEnabled = true
                switch result {
                case .reply(let reply):
                    self.appendLocal("Guide: \(reply)")
                    let fromReply = AppAIMutator.parseChatIntents(reply, defaultSession: session ?? PairState.listPairs().first)
                    if !fromReply.isEmpty {
                        self.offerApply(
                            intents: fromReply,
                            summary: "Guide drafted \(fromReply.count) cron change\(fromReply.count == 1 ? "" : "s") — apply?"
                        )
                    }
                case .disconnected(_, let userFacing):
                    self.appendLocal("Guide: \(userFacing)")
                    self.showDisconnected(userFacing: userFacing, expand: true)
                }
            }
        } else if !AppAIRuntime.isHeadlessReady {
            showDisconnected(
                userFacing: "Guide is offline. Reconnect, then describe the cron (or use Manual form in Cron Manager).",
                expand: true
            )
        }
        Pong.log("Guide beginCronWizard session=\(sess)")
    }

    /// Expand Guide with a mission/ops question and live snapshot context (via AppAIRuntime).
    func beginMissionAsk(_ question: String) {
        attachIfNeeded()
        expanded = true
        layoutInHost()
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            window?.makeFirstResponder(input)
            return
        }
        appendLocal("You: \(q)")
        let sess = PairState.listPairs().first
        let local = AppAIMutator.parseChatIntents(q, defaultSession: sess)
        if !local.isEmpty {
            offerApply(intents: local, summary: "Detected \(local.count) change(s) from your question.")
        }
        guard AppAIRuntime.isHeadlessReady else {
            // Offline: still answer from snapshot rules
            let grounded = GuideCoach.answerMissionQuestion(q)
            appendLocal("Guide: \(grounded)")
            return
        }
        busy = true
        sendBtn.isEnabled = false
        let prompt =
            "MISSION Q&A (use live team state only; name seats and job ages; no fluff).\n" +
            "Question: \(q)\n" +
            "If useful, suggest opening a job id or switching the map team."
        AppAIRuntime.chat(userMessage: prompt) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.sendBtn.isEnabled = true
            switch result {
            case .reply(let reply):
                self.appendLocal("Guide: \(reply)")
            case .disconnected(_, let userFacing):
                let grounded = GuideCoach.answerMissionQuestion(q)
                self.appendLocal("Guide: \(grounded)\n(\(userFacing))")
                self.showDisconnected(userFacing: userFacing, expand: true)
            }
        }
    }

    /// Brief nudge — grows chip next to FAB without full chat.
    func nudge(_ text: String) {
        attachIfNeeded()
        let short = String(text.prefix(80))
        if expanded {
            appendLocal("Guide: \(short)")
            return
        }
        nudgeChip.stringValue = short
        nudgeChip.isHidden = false
        pulseFab(strong: true)
        layoutInHost()
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.08
        anim.duration = 0.35
        anim.autoreverses = true
        anim.repeatCount = 2
        fab.layer?.add(anim, forKey: "nudge")

        nudgeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.nudgeChip.isHidden = true
            self?.pulseFab(strong: false)
            self?.layoutInHost()
        }
        nudgeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5, execute: work)
    }

    /// Proactive coach: short card + action button(s) — not a wall of text.
    func nudgeAction(
        text: String,
        actionTitle: String?,
        action: (() -> Void)?,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        chipText: String? = nil
    ) {
        attachIfNeeded()
        let short = String(text.prefix(120))
        // Collapsed: chip only (no transcript spam)
        if !expanded {
            nudge(chipText ?? short)
        }
        // Expanded transcript: one short line, not a novel
        if expanded {
            appendLocal("Guide: \(short)")
        }
        expanded = true
        layoutInHost()
        if let actionTitle, let action {
            actionHandler = action
            pendingIntents = []
            actionLabel.stringValue = short
            styleActionButton(title: actionTitle)
            actionBar.isHidden = false
            if let secondaryTitle, let secondaryAction {
                secondaryHandler = secondaryAction
                actionBtn2.isHidden = false
                actionBtn2.attributedTitle = NSAttributedString(string: secondaryTitle, attributes: [
                    .foregroundColor: PongTheme.textPrimary,
                    .font: PongTheme.font(11, weight: .semibold),
                ])
            } else {
                secondaryHandler = nil
                actionBtn2.isHidden = true
            }
        } else {
            actionBar.isHidden = true
            actionHandler = nil
            secondaryHandler = nil
            actionBtn2.isHidden = true
        }
        needsLayout = true
        layout()
        pulseFab(strong: true)
    }

    private func offerApply(intents: [AppAIMutator.Intent], summary: String) {
        guard !intents.isEmpty else { return }
        pendingIntents = intents
        actionHandler = nil
        actionLabel.stringValue = summary
        styleActionButton(title: "Apply \(intents.count) change\(intents.count == 1 ? "" : "s")")
        actionBar.isHidden = false
        expanded = true
        layoutInHost()
        needsLayout = true
        layout()
    }

    @objc private func actionPressed() {
        if let handler = actionHandler {
            actionHandler = nil
            secondaryHandler = nil
            actionBar.isHidden = true
            actionBtn2.isHidden = true
            needsLayout = true
            layout()
            handler()
            return
        }
        let intents = pendingIntents
        pendingIntents = []
        actionBar.isHidden = true
        actionBtn2.isHidden = true
        needsLayout = true
        layout()
        guard !intents.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppAIMutator.apply(intents)
            DispatchQueue.main.async {
                if result.failed.isEmpty {
                    self.appendLocal("Guide: Applied — \(result.applied.joined(separator: ", ")).")
                    PanelController.shared.refreshUI()
                } else {
                    self.appendLocal("Guide: Partial fail — " + result.failed.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
                    PanelController.shared.refreshUI()
                }
            }
        }
    }

    @objc private func secondaryActionPressed() {
        let handler = secondaryHandler
        secondaryHandler = nil
        actionBtn2.isHidden = true
        needsLayout = true
        layout()
        handler?()
    }

    // MARK: - Disconnect / reconnect

    private func showDisconnected(userFacing: String, expand: Bool = true) {
        reconnectPhase = .needsReconnect
        reconnectBar.isHidden = false
        reconnectLabel.stringValue = userFacing
        styleReconnectButton(title: "Open sign-in Terminal")
        reconnectBtn.isEnabled = true
        if expand {
            expanded = true
            layoutInHost()
        }
        needsLayout = true
        layout()
        // Orange pulse on FAB when collapsed
        fab.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        pulseFab(strong: true)
        if !expand {
            nudge("Guide offline · reconnect")
        }
    }

    private func hideReconnectBar() {
        reconnectPhase = .hidden
        reconnectBar.isHidden = true
        fab.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.55).cgColor
        needsLayout = true
        layout()
    }

    @objc private func reconnectPressed() {
        switch reconnectPhase {
        case .hidden:
            break
        case .needsReconnect:
            startLoginReconnect()
        case .awaitingSignIn:
            finishLoginReconnect()
        case .connecting:
            break
        }
    }

    private func startLoginReconnect() {
        reconnectPhase = .awaitingSignIn
        reconnectLabel.stringValue = "Sign in / pick model in Terminal.\nSafe to close that window after — or tap I’m signed in (we close it)."
        styleReconnectButton(title: "I’m signed in")
        reconnectBtn.isEnabled = true
        appendLocal("Opening \(AppAISettings.provider?.label ?? "AI") sign-in Terminal…")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppAIRuntime.openLoginTerminal()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func finishLoginReconnect() {
        reconnectPhase = .connecting
        reconnectLabel.stringValue = "Closing Terminal · checking headless…"
        styleReconnectButton(title: "Connecting…")
        reconnectBtn.isEnabled = false
        AppAIRuntime.completeLogin { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                self.hideReconnectBar()
                self.appendLocal("Guide: \(msg)")
                self.nudge("Guide reconnected")
                self.window?.makeFirstResponder(self.input)
            } else {
                self.reconnectPhase = .needsReconnect
                self.reconnectLabel.stringValue = msg + "\nTry again — open sign-in Terminal."
                self.styleReconnectButton(title: "Open sign-in Terminal")
                self.reconnectBtn.isEnabled = true
                self.appendLocal("Guide: \(msg)")
            }
        }
    }

    @objc private func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        // If offline, treat send as a nudge to reconnect rather than silent rules
        if reconnectPhase != .hidden || !AppAIRuntime.isHeadlessReady {
            input.stringValue = ""
            appendLocal("You: \(text)")
            showDisconnected(
                userFacing: "Guide is offline. Open sign-in Terminal, sign in, then tap I’m signed in (safe to close that window after).",
                expand: true
            )
            appendLocal("Guide: Still disconnected — use the orange bar below to reconnect.")
            return
        }
        input.stringValue = ""
        appendLocal("You: \(text)")
        // Local mutator parse — offer Apply without waiting for headless
        let sess = PairState.listPairs().first
        let localIntents = AppAIMutator.parseChatIntents(text, defaultSession: sess)
        if !localIntents.isEmpty {
            offerApply(
                intents: localIntents,
                summary: "Detected \(localIntents.count) architecture change\(localIntents.count == 1 ? "" : "s") from your message."
            )
        }
        busy = true
        sendBtn.isEnabled = false
        AppAIRuntime.chat(userMessage: text) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.sendBtn.isEnabled = true
            switch result {
            case .reply(let reply):
                self.appendLocal("Guide: \(reply)")
                // Also parse Guide reply for apply lines
                let fromReply = AppAIMutator.parseChatIntents(reply, defaultSession: sess)
                if !fromReply.isEmpty, self.pendingIntents.isEmpty {
                    self.offerApply(
                        intents: fromReply,
                        summary: "Guide suggested \(fromReply.count) change\(fromReply.count == 1 ? "" : "s") — apply?"
                    )
                }
            case .disconnected(_, let userFacing):
                self.appendLocal("Guide: \(userFacing)")
                self.showDisconnected(userFacing: userFacing, expand: true)
            }
        }
    }

    private func appendLocal(_ s: String) {
        // Skip near-duplicate consecutive lines (same coach spam)
        let cur = transcript.string
        if cur.hasSuffix(s) || cur.contains("\n\n" + s) {
            let tail = String(cur.suffix(min(cur.count, s.count + 40)))
            if tail.contains(s) { return }
        }
        var next = cur.isEmpty ? s : cur + "\n\n" + s
        if next.count > maxTranscriptChars {
            next = "…\n\n" + String(next.suffix(maxTranscriptChars - 8))
        }
        transcript.string = next
        transcript.scrollToEndOfDocument(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(hostResized),
                name: NSView.frameDidChangeNotification, object: superview
            )
            superview?.postsFrameChangedNotifications = true
        }
    }

    @objc private func hostResized() { layoutInHost() }
}

// Hook for PanelController
extension PanelController {
    /// Host view for floating Guide bubble (3D map page).
    func mapHostView() -> NSView? {
        return _mapHostForBubble()
    }
}

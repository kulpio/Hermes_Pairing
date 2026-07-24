import AppKit

/// Small first-run callouts next to YOU / TASKS / CRON / TRACKING on the 3D map.
enum MapCoachMarks {
    private static var overlay: NSView?
    private static var step = 0

    private static let tips: [(title: String, body: String, anchor: String)] = [
        (
            "YOU",
            "Talk to the boss without hunting Terminals. Pick a team, type, Send.",
            "human"
        ),
        (
            "TASKS",
            "Who is doing what right now — jobs on the road for this team.",
            "tasks"
        ),
        (
            "CRON",
            "Scheduled ticks (optional). Jobs fire to one agent on a timer.",
            "cron"
        ),
        (
            "TRACKING",
            "Live pulse of seats — who is idle, working, or needs you.",
            "track"
        ),
    ]

    static func presentIfNeeded(on host: NSView? = nil) {
        let key = "map_coachmarks_v1_done"
        if (AppAISettings.load()["coachmarks"] as? [String: Any])?[key] as? Bool == true {
            return
        }
        // Also skip during empty preview-only if user never finished onboarding
        guard AppAISettings.onboardingComplete || AppAISettings.providerId != nil else { return }
        present(on: host)
    }

    static func present(on host: NSView? = nil) {
        step = 0
        guard let host = host ?? PanelController.shared.mapHostView() else { return }
        overlay?.removeFromSuperview()

        let o = NSView(frame: host.bounds)
        o.wantsLayer = true
        o.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        o.autoresizingMask = [.width, .height]
        host.addSubview(o, positioned: .above, relativeTo: nil)
        overlay = o
        renderTip(on: o)
        Pong.log("MapCoachMarks present")
    }

    private static func renderTip(on o: NSView) {
        o.subviews.forEach { $0.removeFromSuperview() }
        let tip = tips[min(step, tips.count - 1)]

        // Card near left HUD (bottom-left of map stack)
        let cardW: CGFloat = 260
        let cardH: CGFloat = 132
        let x: CGFloat = 240 // right of left HUD column
        let yBase: CGFloat = {
            switch tip.anchor {
            case "track": return o.bounds.height - 200
            case "human": return o.bounds.height - 340
            case "cron": return o.bounds.height - 480
            default: return o.bounds.height - 600 // tasks
            }
        }()
        let y = max(80, min(o.bounds.height - cardH - 40, yBase))

        let card = NSView(frame: NSRect(x: x, y: y, width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.5).cgColor
        card.layer?.shadowColor = PongSheetChrome.lime.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 12
        o.addSubview(card)

        // Pointer bar toward left HUD
        let pin = NSView(frame: NSRect(x: x - 10, y: y + cardH / 2 - 2, width: 10, height: 4))
        pin.wantsLayer = true
        pin.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        o.addSubview(pin)

        let title = NSTextField(labelWithString: tip.title)
        title.font = PongTheme.font(14, weight: .semibold)
        title.textColor = PongSheetChrome.lime
        title.frame = NSRect(x: 14, y: cardH - 32, width: cardW - 28, height: 20)
        card.addSubview(title)

        let body = NSTextField(wrappingLabelWithString: tip.body)
        body.font = PongTheme.font(12)
        body.textColor = PongTheme.textSecondary
        body.frame = NSRect(x: 14, y: 40, width: cardW - 28, height: 52)
        body.maximumNumberOfLines = 4
        card.addSubview(body)

        let next = NSButton(title: step + 1 >= tips.count ? "Got it" : "Next",
                            target: MapCoachTarget.shared,
                            action: #selector(MapCoachTarget.next))
        next.bezelStyle = .inline
        next.isBordered = false
        next.wantsLayer = true
        next.layer?.cornerRadius = 12
        next.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        next.attributedTitle = NSAttributedString(string: next.title, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.font(12, weight: .semibold),
        ])
        next.frame = NSRect(x: cardW - 96, y: 10, width: 80, height: 28)
        card.addSubview(next)

        let skip = NSButton(title: "Skip", target: MapCoachTarget.shared, action: #selector(MapCoachTarget.skip))
        skip.bezelStyle = .inline
        skip.isBordered = false
        skip.font = PongTheme.font(11)
        skip.contentTintColor = PongTheme.textTertiary
        skip.frame = NSRect(x: 12, y: 12, width: 48, height: 24)
        card.addSubview(skip)
    }

    fileprivate static func goNext() {
        if step + 1 >= tips.count {
            finish()
            return
        }
        step += 1
        if let o = overlay { renderTip(on: o) }
    }

    fileprivate static func finish() {
        overlay?.removeFromSuperview()
        overlay = nil
        AppAISettings.save { root in
            var c = root["coachmarks"] as? [String: Any] ?? [:]
            c["map_coachmarks_v1_done"] = true
            root["coachmarks"] = c
        }
        Pong.log("MapCoachMarks finished")
    }
}

final class MapCoachTarget: NSObject {
    static let shared = MapCoachTarget()
    @objc func next() { MapCoachMarks.goNext() }
    @objc func skip() { MapCoachMarks.finish() }
}

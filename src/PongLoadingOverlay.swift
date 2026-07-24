import AppKit
import QuartzCore

/// Shared loading UX for slow sheet saves (Opts / Policy) and other blocking work.
/// CyberPong logo + two dots that glow intermittently (alternating), not a system spinner.
enum PongLoadingOverlay {
    private static var host: NSView?
    private static var timer: Timer?
    private static var phase = 0
    private static weak var leftDot: NSView?
    private static weak var rightDot: NSView?

    /// Show dim scrim + centered card over `window` (or its contentView).
    static func show(on window: NSWindow?, message: String = "Saving…") {
        hide()
        guard let win = window, let content = win.contentView else { return }

        let scrim = NSView(frame: content.bounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        scrim.autoresizingMask = [.width, .height]
        scrim.identifier = NSUserInterfaceItemIdentifier("pongLoadingOverlay")

        let cardW: CGFloat = 200
        let cardH: CGFloat = 128
        let card = NSView(frame: NSRect(
            x: (content.bounds.width - cardW) / 2,
            y: (content.bounds.height - cardH) / 2,
            width: cardW, height: cardH
        ))
        card.wantsLayer = true
        card.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = PongTheme.line.withAlphaComponent(0.5).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 16
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

        // Logo — prefer accent / wordmark assets already in the app bundle
        let logo = NSImageView(frame: NSRect(x: (cardW - 48) / 2, y: 58, width: 48, height: 48))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.image = loadLogoImage()
        logo.wantsLayer = true
        card.addSubview(logo)

        let label = NSTextField(labelWithString: message)
        label.font = PongTheme.font(12, weight: .medium)
        label.textColor = PongTheme.textSecondary
        label.alignment = .center
        label.frame = NSRect(x: 12, y: 34, width: cardW - 24, height: 18)
        card.addSubview(label)

        // Two intermittent glowing dots
        let d: CGFloat = 10
        let gap: CGFloat = 14
        let rowW = d * 2 + gap
        let rowX = (cardW - rowW) / 2
        let left = makeDot(frame: NSRect(x: rowX, y: 14, width: d, height: d))
        let right = makeDot(frame: NSRect(x: rowX + d + gap, y: 14, width: d, height: d))
        card.addSubview(left)
        card.addSubview(right)
        leftDot = left
        rightDot = right

        scrim.addSubview(card)
        content.addSubview(scrim)
        host = scrim
        phase = 0
        applyDotPhase()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: true) { _ in
            phase = (phase + 1) % 2
            applyDotPhase()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    static func hide() {
        timer?.invalidate()
        timer = nil
        host?.removeFromSuperview()
        host = nil
        leftDot = nil
        rightDot = nil
        phase = 0
    }

    private static func makeDot(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.cornerRadius = frame.width / 2
        v.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        v.layer?.shadowColor = PongSheetChrome.lime.cgColor
        v.layer?.shadowOffset = .zero
        v.layer?.shadowRadius = 6
        v.layer?.shadowOpacity = 0.3
        return v
    }

    private static func applyDotPhase() {
        let bright: Float = 0.95
        let dim: Float = 0.22
        // Alternate: phase 0 → left bright; phase 1 → right bright
        leftDot?.layer?.shadowOpacity = phase == 0 ? bright : dim
        leftDot?.layer?.opacity = phase == 0 ? 1.0 : 0.35
        rightDot?.layer?.shadowOpacity = phase == 1 ? bright : dim
        rightDot?.layer?.opacity = phase == 1 ? 1.0 : 0.35
    }

    private static func loadLogoImage() -> NSImage? {
        let names = [
            "logo-accent-128", "logo-accent", "logo-mono-128",
            "logo-monochrome", "logo", "AppIcon",
            "cyberpong-wordmark-dark",
        ]
        for n in names {
            if let img = NSImage(named: n) { return img }
            // Bundle resource without extension registration
            if let url = Bundle.main.url(forResource: n, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                return img
            }
        }
        // Fallback: monochrome lime circle if assets missing in --dev runs
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus()
        PongSheetChrome.lime.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)).fill()
        img.unlockFocus()
        return img
    }
}

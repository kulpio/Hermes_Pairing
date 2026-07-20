import AppKit

/// Shared defense-schematic chrome for sheets, popups, Mission tiles.
enum PongSheetChrome {
    static var lime: NSColor {
        NSColor(calibratedRed: 0.82, green: 0.95, blue: 0.28, alpha: 1) // blueprint lime
    }
    static var limeSoft: NSColor {
        lime.withAlphaComponent(0.14)
    }
    static var limeDim: NSColor {
        lime.withAlphaComponent(0.45)
    }

    static func styleWindow(_ win: NSWindow, title: String) {
        win.title = title
        win.backgroundColor = PongTheme.bg
        win.appearance = NSAppearance(named: PongTheme.appearance == .dark ? .darkAqua : .aqua)
    }

    static func rootView(width W: CGFloat, height H: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.wantsLayer = true
        v.layer?.backgroundColor = PongTheme.bg.cgColor
        return v
    }

    static func titleLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = PongTheme.font(15, weight: .semibold)
        f.textColor = PongTheme.textPrimary
        f.frame = frame
        return f
    }

    static func sectionLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = PongTheme.labelFont(10)
        f.textColor = limeDim
        f.frame = frame
        return f
    }

    static func bodyLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = PongTheme.font(12)
        f.textColor = PongTheme.textSecondary
        f.frame = frame
        f.maximumNumberOfLines = 8
        return f
    }

    static func hairline(x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        v.wantsLayer = true
        v.layer?.backgroundColor = lime.withAlphaComponent(0.22).cgColor
        return v
    }

    static func plate(frame: NSRect, accent: NSColor = lime) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        v.layer?.cornerRadius = 6
        v.layer?.borderWidth = 1
        v.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        let rail = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: frame.height))
        rail.wantsLayer = true
        rail.layer?.backgroundColor = accent.cgColor
        v.addSubview(rail)
        return v
    }

    static func primaryButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = lime.cgColor
        b.layer?.cornerRadius = 4
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: PongTheme.labelFont(11),
        ])
        b.target = target
        b.action = action
        return b
    }

    static func outlineButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.clear.cgColor
        b.layer?.cornerRadius = 4
        b.layer?.borderWidth = 1
        b.layer?.borderColor = lime.withAlphaComponent(0.4).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.labelFont(11),
        ])
        b.target = target
        b.action = action
        return b
    }
}

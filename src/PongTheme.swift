import AppKit

/// Dark orchestration UI — deep void canvas, violet signal color, elevated glass cards.
/// Inspired by modern agent dashboards (not a clone of any single product).
enum PongTheme {
    // Backgrounds (near-void)
    static let bg = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)          // #0D0D12
    static let bgElevated = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)  // card
    static let bgHover = NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.20, alpha: 1)
    static let bgInput = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
    static let bgFooter = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1)
    static let bgMetric = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.13, alpha: 1)

    // Text
    static let textPrimary = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let textSecondary = NSColor(calibratedWhite: 0.58, alpha: 1)
    static let textTertiary = NSColor(calibratedWhite: 0.40, alpha: 1)

    // Borders
    static let border = NSColor(calibratedWhite: 1, alpha: 0.07)
    static let borderStrong = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let borderAccent = NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.95, alpha: 0.45)

    // Violet signal (orchestration accent)
    static let accent = NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.98, alpha: 1)       // soft purple CTA
    static let accentSoft = NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.98, alpha: 0.18)
    static let accentInk = NSColor(calibratedWhite: 1, alpha: 1)
    static let accentGlow = NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.98, alpha: 0.35)

    // Status
    static let live = NSColor(calibratedRed: 0.30, green: 0.88, blue: 0.55, alpha: 1)
    static let liveSoft = NSColor(calibratedRed: 0.30, green: 0.88, blue: 0.55, alpha: 0.15)
    static let warn = NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.28, alpha: 1)
    static let warnSoft = NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.28, alpha: 0.15)
    static let danger = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.40, alpha: 1)
    static let idle = NSColor(calibratedWhite: 0.42, alpha: 1)
    static let idleSoft = NSColor(calibratedWhite: 0.42, alpha: 0.12)

    static let tabSelected = NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.98, alpha: 0.22)
    static let tabIdle = NSColor.clear

    static let radiusCard: CGFloat = 16
    static let radiusPill: CGFloat = 8
    static let radiusBtn: CGFloat = 10

    static func applyCard(_ v: NSView, elevated: Bool = true, accentBorder: Bool = false) {
        v.wantsLayer = true
        v.layer?.backgroundColor = (elevated ? bgElevated : bgInput).cgColor
        v.layer?.cornerRadius = radiusCard
        v.layer?.borderWidth = 1
        v.layer?.borderColor = (accentBorder ? borderAccent : border).cgColor
    }

    static func applyMetricCard(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.backgroundColor = bgMetric.cgColor
        v.layer?.cornerRadius = 14
        v.layer?.borderWidth = 1
        v.layer?.borderColor = border.cgColor
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func statusKind(_ raw: String) -> (label: String, color: NSColor, soft: NSColor) {
        let t = raw.lowercased()
        if t.contains("busy") || t.contains("running") || t.contains("live") || t.contains("notified") {
            return ("RUNNING", live, liveSoft)
        }
        if t.contains("human") {
            return ("TAKEOVER", warn, warnSoft)
        }
        if t.contains("hide") || t.contains("hidden") {
            return ("HIDDEN", warn, warnSoft)
        }
        if t.contains("fail") || t.contains("error") {
            return ("FAILED", danger, NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.40, alpha: 0.15))
        }
        if t.contains("job") {
            return ("ACTIVE", accent, accentSoft)
        }
        return ("IDLE", idle, idleSoft)
    }
}

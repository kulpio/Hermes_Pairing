import AppKit
import Foundation

/// Hermes_Pairing menu bar — single dock icon; panel is accessory (no second dock icon).
/// Black bolt; when pairs active, top dot Claude orange + bottom dot Hermes blue pulse.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var projectRoot: String = ""
    private var timer: Timer?
    private var glowPhase: CGFloat = 0
    private var boltIdle: NSImage?
    private var boltActiveDim: NSImage?
    private var boltActiveBright: NSImage?
    private var hasActivePair = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolveProjectRoot()
        loadIcons()
        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // ONE dark bolt only — never emoji (that created a second gold icon)
            button.image = boltIdle
            button.image?.isTemplate = true
            button.title = ""
            button.toolTip = "Hermes_Pairing"
            button.appearsDisabled = false
        }
        statusItem.isVisible = true
        rebuildMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.openPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
    }

    private func resolveProjectRoot() {
        if let marker = Bundle.main.resourcePath.map({ $0 + "/project_root" }),
           let root = try? String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty,
           FileManager.default.fileExists(atPath: root) {
            projectRoot = root
            return
        }
        projectRoot = NSString("~/DigitalBrain/Boreal/tools/hermes-claude-app").expandingTildeInPath
    }

    private func loadIcons() {
        let res = Bundle.main.resourcePath ?? ""
        func load(_ name: String, template: Bool, size: CGFloat = 18) -> NSImage? {
            let path = (res as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path),
                  let i = NSImage(contentsOfFile: path) else { return nil }
            let c = i.copy() as! NSImage
            c.size = NSSize(width: size, height: size)
            c.isTemplate = template
            return c
        }
        boltIdle = load("menubar-template.png", template: true)
            ?? load("logo-mono-128.png", template: true)
            ?? load("bolt-black.png", template: true)
        // Active connection: accent logo (Claude orange + Hermes blue dots)
        boltActiveBright = load("bolt-active.png", template: false)
            ?? load("logo-accent-128.png", template: false)
            ?? load("logo-accent.png", template: false)
        boltActiveDim = load("bolt-active-dim.png", template: false)
            ?? boltActiveBright

        if boltIdle == nil,
           let sf = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Hermes_Pairing") {
            sf.isTemplate = true
            boltIdle = sf
        }
    }

    private func pairSessions() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmux")
        p.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init).filter {
            $0 == "hermes-claude" || $0.hasPrefix("hermes-claude-") || $0.hasPrefix("hermes-pair")
        }
    }

    private func tick() {
        let sessions = pairSessions()
        let active = !sessions.isEmpty
        if active != hasActivePair {
            hasActivePair = active
            rebuildMenu()
        }
        guard let button = statusItem?.button else { return }

        if active, let dim = boltActiveDim, let bright = boltActiveBright {
            // Pulse: black bolt stays; dots breathe Hermes blue / Claude orange
            glowPhase += 0.08
            if glowPhase > .pi * 2 { glowPhase -= .pi * 2 }
            let t = (sin(glowPhase) + 1) / 2  // 0...1
            button.image = crossfade(dim, bright, t: t)
            button.image?.isTemplate = false
            button.title = ""
        } else if let idle = boltIdle {
            button.image = idle
            button.image?.isTemplate = true
            button.title = ""
        } else {
            button.title = "HP"
        }
    }

    private func crossfade(_ a: NSImage, _ b: NSImage, t: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            a.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - t)
            b.draw(in: rect, from: .zero, operation: .sourceOver, fraction: t)
            return true
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("Open control panel", #selector(openPanel)))
        menu.addItem(.separator())

        let sessions = pairSessions()
        if sessions.isEmpty {
            let idle = NSMenuItem(title: "No active pairs", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        } else {
            for s in sessions {
                let sub = NSMenu()
                let rejoin = NSMenuItem(title: "Bring to front", action: #selector(rejoinNamed(_:)), keyEquivalent: "")
                rejoin.target = self
                rejoin.representedObject = s
                sub.addItem(rejoin)
                let kill = NSMenuItem(title: "Kill pair", action: #selector(killNamed(_:)), keyEquivalent: "")
                kill.target = self
                kill.representedObject = s
                sub.addItem(kill)
                let row = NSMenuItem(title: "● \(s)", action: nil, keyEquivalent: "")
                row.submenu = sub
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("New pair", #selector(newPair)))
        menu.addItem(item("Refresh", #selector(refreshMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hermes_Pairing", #selector(quit)))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func refreshMenu() { rebuildMenu() }

    @objc func openPanel() {
        let panelPaths = [
            Bundle.main.bundlePath + "/Contents/Resources/Panel.app",
            "/Applications/Hermes_Pairing.app/Contents/Resources/Panel.app",
        ]
        if let panel = panelPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            // Activate existing panel window if running; else open
            NSWorkspace.shared.open(URL(fileURLWithPath: panel))
            return
        }
        // fallback
        let script = "\(projectRoot)/src/hermes_pairing.py"
        let py = "\(projectRoot)/venv/bin/python"
        guard FileManager.default.fileExists(atPath: script) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: py) ? py : "/usr/bin/python3")
        task.arguments = [script, "--window-only"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    @objc func newPair() {
        let sessions = pairSessions()
        var name = "hermes-claude"
        if sessions.contains(name) {
            var n = 1
            repeat {
                name = "hermes-pair-\(n)"
                n += 1
            } while sessions.contains(name) && n < 50
        }
        runShell("""
        tmux new-session -d -s \(name) -n Hermes
        tmux new-window -t \(name):1 -n Claude
        tmux send-keys -t \(name):1 'cd ~ && claude' Enter
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t \(name)"'
        """)
        notify("New pair", name)
        rebuildMenu()
    }

    @objc func rejoinNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runShell("""
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t \(name)"'
        """)
    }

    @objc func killNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runShell("tmux kill-session -t \(name) 2>/dev/null || true")
        notify("Killed", name)
        rebuildMenu()
    }

    @objc func quit() {
        // Kill panel helper too (no second dock icon after quit)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "hermes_pairing.py"]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }

    private func runShell(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func notify(_ title: String, _ msg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(title)\""]
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

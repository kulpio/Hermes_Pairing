import AppKit
import Foundation

/// Hermes Pong — menu bar + pairs. Control UI lives in nested Panel.app.

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
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = boltIdle
            button.image?.isTemplate = true
            button.title = ""
            button.toolTip = "Hermes Pong"
            button.appearsDisabled = false
        }
        statusItem.isVisible = true
        rebuildMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.openPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Hermes Pong")
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About Hermes Pong", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())

        let open = NSMenuItem(title: "Open Control Panel", action: #selector(openPanel), keyEquivalent: "o")
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Hermes Pong", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)

        NSApp.mainMenu = mainMenu
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Hermes Pong"
        alert.informativeText = "Pair Hermes + Claude Code in Terminal.\nkulpio/Hermes_Pairing"
        alert.runModal()
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
        boltActiveBright = load("bolt-active.png", template: false)
            ?? load("logo-accent-128.png", template: false)
            ?? load("logo-accent.png", template: false)
        boltActiveDim = load("bolt-active-dim.png", template: false) ?? boltActiveBright

        if boltIdle == nil,
           let sf = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Hermes Pong") {
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
            glowPhase += 0.08
            if glowPhase > .pi * 2 { glowPhase -= .pi * 2 }
            let t = (sin(glowPhase) + 1) / 2
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
        menu.addItem(item("Quit Hermes Pong", #selector(quitAll)))
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
            "/Applications/HermesPong.app/Contents/Resources/Panel.app",
            "/Applications/Hermes_Pairing.app/Contents/Resources/Panel.app",
        ]
        if let panel = panelPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: panel))
            return
        }
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
        rebuildMenu()
    }

    @objc func quitAll() {
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

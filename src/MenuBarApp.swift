import AppKit
import Foundation

/// Hermes Pong — menu bar + control panel, all native Swift (no Python at runtime).

// MARK: - Shared helpers (shell, AppleScript, state files, logging)

enum Pong {
    static var stateDir: String { NSHomeDirectory() + "/.hermes-pong" }
    static var logPath: String { NSHomeDirectory() + "/Library/Logs/HermesPong.log" }
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/bin"

    static func log(_ msg: String) {
        let line = msg.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Run a shell line with brew/user paths prepended (tmux lives there).
    @discardableResult
    static func sh(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Multi-line AppleScript via temp file (reliable, mirrors the old panel).
    @discardableResult
    static func osascript(_ script: String) -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hp-\(ProcessInfo.processInfo.globallyUniqueString).applescript")
        do { try script.write(to: tmp, atomically: true, encoding: .utf8) } catch { return "" }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [tmp.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loadJSON(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    static func writeJSON(_ path: String, _ dict: [String: Any]) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Pair state (contracts identical to the Python panel)

enum PairState {
    static var pairsPath: String { Pong.stateDir + "/pairs.json" }
    static var activePath: String { Pong.stateDir + "/active-pair.json" }
    static var settingsPath: String { Pong.stateDir + "/settings.json" }

    static func isPairName(_ s: String) -> Bool {
        if s.hasSuffix("-h") || s.hasSuffix("-c") { return false }
        return s == "hermes-claude" || s.hasPrefix("hermes-claude-") || s.hasPrefix("hermes-pair")
    }

    static func loadPairsDb() -> [String: Any] { Pong.loadJSON(pairsPath) }

    /// Live tmux pair sessions ∪ saved pairs.json entries (window-mode links).
    static func listPairs() -> [String] {
        let out = Pong.sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        var names = Set(out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isPairName($0) })
        for key in loadPairsDb().keys where isPairName(key) { names.insert(key) }
        return names.sorted()
    }

    static func nextPairName() -> String {
        let existing = Set(listPairs())
        if !existing.contains("hermes-claude") { return "hermes-claude" }
        for n in 1...50 where !existing.contains("hermes-pair-\(n)") { return "hermes-pair-\(n)" }
        return "hermes-pair-\(Int(Date().timeIntervalSince1970) % 10000)"
    }

    /// Default per-pair access constraints (bans + freeform note).
    /// Checked boxes mean "ban this". Injected into Claude via claude-delegate.
    static func defaultPermissions() -> [String: Any] {
        [
            "ban_mcp": false,
            "ban_root": false,
            "ban_network": false,
            "ban_system_paths": false,
            "repo_only": false,
            "custom_prompt": "",
        ]
    }

    static func permissions(for session: String) -> [String: Any] {
        let prev = (loadPairsDb()[session] as? [String: Any])?["permissions"] as? [String: Any] ?? [:]
        var merged = defaultPermissions()
        for (k, v) in prev { merged[k] = v }
        return merged
    }

    /// Persist active pair + per-session map. Merges with the existing entry so
    /// views / permissions are not wiped. v1.3: autonomy is always "full" — the
    /// verdict loop runs until accept or escalate; there are no ask-modes anymore.
    static func savePairState(_ session: String,
                              hermesWindowId: String? = nil,
                              claudeWindowId: String? = nil,
                              claudeMode: String? = nil,
                              permissions: [String: Any]? = nil) {
        var db = loadPairsDb()
        let prev = db[session] as? [String: Any] ?? [:]
        var entry: [String: Any] = [
            "hermes_window_id": hermesWindowId ?? prev["hermes_window_id"] ?? NSNull(),
            "claude_window_id": claudeWindowId ?? prev["claude_window_id"] ?? NSNull(),
            "claude_mode": claudeMode ?? prev["claude_mode"] ?? "tmux",
            "autonomy_level": "full",
            "updated": Date().timeIntervalSince1970,
        ]
        for k in ["view_hermes", "view_claude"] {
            if let v = prev[k] { entry[k] = v }
        }
        if let permissions {
            entry["permissions"] = permissions
        } else if let p = prev["permissions"] {
            entry["permissions"] = p
        } else {
            entry["permissions"] = defaultPermissions()
        }
        db[session] = entry
        Pong.writeJSON(pairsPath, db)

        var active = entry
        active["session"] = session
        Pong.writeJSON(activePath, active)

        let reply = Pong.stateDir + "/last-claude.txt"
        if !FileManager.default.fileExists(atPath: reply) {
            try? "(no Claude reply yet — run claude-delegate.py after Claude finishes a task)\n"
                .write(toFile: reply, atomically: true, encoding: .utf8)
        }
        Pong.log("saved pair state \(session) \(entry)")
    }

}

// MARK: - Pairing operations (Terminal + tmux, ports of the Python panel)

enum Pairing {
    /// [(window_id, title)] for all Terminal windows.
    static func listTerminalWindows() -> [(id: String, title: String)] {
        let out = Pong.osascript("""
        tell application "Terminal"
          set acc to ""
          repeat with w in windows
            try
              set wid to id of w as string
              set nm to name of w
              set acc to acc & wid & "|||" & nm & linefeed
            end try
          end repeat
          return acc
        end tell
        """)
        var rows: [(String, String)] = []
        for line in out.split(separator: "\n") {
            guard let sep = line.range(of: "|||") else { continue }
            let wid = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
            var title = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard Int(wid) != nil else { continue }
            if title.count > 42 { title = String(title.prefix(39)) + "…" }
            rows.append((wid, title))
        }
        return rows
    }

    static func frontTerminalId() -> String? {
        let r = Pong.osascript("""
        tell application "Terminal"
          try
            if (count of windows) is 0 then return "NONE"
            return id of front window as string
          on error
            return "NONE"
          end try
        end tell
        """)
        return Int(r) != nil ? r : nil
    }

    /// Run a command inside the *selected tab* of an existing window (never a new tab).
    static func runInTerminalWindow(_ windowId: String, _ command: String) {
        let cmd = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let out = Pong.osascript("""
        tell application "Terminal"
          try
            set w to window id \(windowId)
            set index of w to 1
            set selected of w to true
            do script "\(cmd)" in selected tab of w
            activate
            return "OK"
          on error errMsg
            return "ERR:" & errMsg
          end try
        end tell
        """)
        Pong.log("run_in_terminal_window id=\(windowId) → \(out)")
    }

    /// One clean blink of the paired windows (raise, hide once, show once).
    static func flashPairWindows(_ hermesId: String?, _ claudeId: String?) {
        var ids: [String] = []
        for wid in [claudeId, hermesId] {
            if let w = wid, Int(w) != nil, !ids.contains(w) { ids.append(w) }
        }
        guard !ids.isEmpty else { return }
        var lines = ["tell application \"Terminal\"", "  try"]
        for (i, wid) in ids.enumerated() { lines.append("    set w\(i) to window id \(wid)") }
        for i in ids.indices { lines.append("    set index of w\(i) to 1") }
        lines.append("    activate")
        for i in ids.indices { lines.append("    set visible of w\(i) to false") }
        lines.append("    delay 0.10")
        for i in ids.indices { lines.append("    set visible of w\(i) to true") }
        for i in ids.indices { lines.append("    set index of w\(i) to 1") }
        lines += ["  end try", "end tell"]
        Pong.osascript(lines.joined(separator: "\n"))
    }

    static func bringToFront(_ name: String) {
        var entry = PairState.loadPairsDb()[name] as? [String: Any] ?? [:]
        if entry.isEmpty {
            let cur = Pong.loadJSON(PairState.activePath)
            if cur["session"] as? String == name { entry = cur }
        }
        let hid = entry["hermes_window_id"].flatMap { "\($0)" }
        let cid = entry["claude_window_id"].flatMap { "\($0)" }
        if (hid.map { Int($0) != nil } ?? false) || (cid.map { Int($0) != nil } ?? false) {
            flashPairWindows(hid, cid)
        } else {
            Pong.sh("tmux switch-client -t \(name):0 2>/dev/null || true")
            Pong.osascript("tell application \"Terminal\" to activate")
        }
    }

    /// True if the Terminal tab already runs a Hermes/Claude TUI (not a bare shell).
    static func looksLikeTui(_ windowId: String) -> Bool {
        for (wid, title) in listTerminalWindows() where wid == windowId {
            let t = title.lowercased()
            return ["claude", "✳", "fable", "hermes", "⚕", "grok"].contains { t.contains($0) }
        }
        return false
    }

    /// New pair: base session (Hermes :0, Claude :1) + grouped view sessions so
    /// each Terminal keeps its own current window.
    static func startFresh() -> String {
        let name = PairState.nextPairName()
        let viewH = "\(name)-h", viewC = "\(name)-c"
        for s in [name, viewH, viewC] {
            Pong.sh("tmux has-session -t \(s) 2>/dev/null && tmux kill-session -t \(s) || true")
        }
        Pong.sh("tmux new-session -d -s \(name) -n Hermes")
        Pong.sh("tmux new-window -t \(name) -n Claude")
        Pong.sh("tmux send-keys -t \(name):0 -l 'printf \"\\n  HERMES · \(name):0\\n\\n\"; hermes'")
        usleep(50_000)
        Pong.sh("tmux send-keys -t \(name):0 Enter")
        Pong.sh("tmux send-keys -t \(name):1 -l 'claude'")
        usleep(50_000)
        Pong.sh("tmux send-keys -t \(name):1 Enter")
        Pong.sh("tmux new-session -d -s \(viewH) -t \(name)")
        Pong.sh("tmux select-window -t \(viewH):0")
        Pong.sh("tmux new-session -d -s \(viewC) -t \(name)")
        Pong.sh("tmux select-window -t \(viewC):1")

        let out = Pong.osascript("""
        tell application "Terminal"
          activate
          do script "tmux attach-session -t \(viewH)"
          delay 0.45
          set idH to id of front window
          do script "tmux attach-session -t \(viewC)"
          delay 0.45
          set idC to id of front window
          return (idH as string) & "," & (idC as string)
        end tell
        """)
        var hid: String?, cid: String?
        if let comma = out.firstIndex(of: ",") {
            hid = String(out[..<comma]).trimmingCharacters(in: .whitespaces)
            cid = String(out[out.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }

        PairState.savePairState(name, hermesWindowId: hid, claudeWindowId: cid, claudeMode: "tmux")
        var active = Pong.loadJSON(PairState.activePath)
        active["session"] = name
        active["view_hermes"] = viewH
        active["view_claude"] = viewC
        active["hermes_window_id"] = hid ?? NSNull() as Any
        active["claude_window_id"] = cid ?? NSNull() as Any
        active["claude_mode"] = "tmux"
        active["updated"] = Date().timeIntervalSince1970
        Pong.writeJSON(PairState.activePath, active)
        var db = PairState.loadPairsDb()
        var entry = db[name] as? [String: Any] ?? [:]
        entry["view_hermes"] = viewH
        entry["view_claude"] = viewC
        entry["updated"] = Date().timeIntervalSince1970
        db[name] = entry
        Pong.writeJSON(PairState.pairsPath, db)

        if let h = hid { flashPairWindows(h, cid) }
        Pong.log("start_fresh \(name) views=\(viewH)/\(viewC) hermes=\(hid ?? "-") claude=\(cid ?? "-")")
        return name
    }

    /// Link existing windows. Never dumps shell/tmux into live TUIs.
    static func wirePair(_ name: String, _ w1: String, _ w2: String) {
        Pong.sh("tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -n Hermes")
        let wins = Pong.sh("tmux list-windows -t \(name) -F '#{window_index}'")
        if !wins.split(separator: "\n").map(String.init).contains("1") {
            Pong.sh("tmux new-window -t \(name) -n Claude")
        }
        let hermesTui = looksLikeTui(w1)
        let claudeTui = looksLikeTui(w2)

        if !hermesTui {
            runInTerminalWindow(w1, "printf '\\n  HERMES · \(name):0\\n\\n'; tmux attach-session -t \(name):0")
            usleep(300_000)
        } else {
            Pong.log("Hermes window \(w1) is live TUI — register only")
        }

        if claudeTui {
            PairState.savePairState(name, hermesWindowId: w1, claudeWindowId: w2, claudeMode: "window")
            startWindowRelay()
            Pong.log("wired \(name) mode=window hermes=\(w1) claude=\(w2) (+relay)")
            return
        }

        runInTerminalWindow(w2, "printf '\\n  CLAUDE · \(name):1\\n\\n'; tmux attach-session -t \(name):1")
        usleep(400_000)
        let pane = Pong.sh("tmux capture-pane -p -t \(name):1 -S -40 2>/dev/null || true").lowercased()
        let already = ["claude code", "trust this folder", "bypass permissions", "fable", "✳"]
            .contains { pane.contains($0) }
        if !already {
            Pong.sh("tmux send-keys -t \(name):1 -l 'claude'")
            usleep(50_000)
            Pong.sh("tmux send-keys -t \(name):1 Enter")
        }
        PairState.savePairState(name, hermesWindowId: w1, claudeWindowId: w2, claudeMode: "tmux")
        Pong.log("wired \(name) mode=tmux hermes=\(w1) claude=\(w2)")
    }

    static func killPair(_ name: String) {
        for s in [name, "\(name)-h", "\(name)-c"] {
            Pong.sh("tmux kill-session -t \(s) 2>/dev/null || true")
        }
        var db = PairState.loadPairsDb()
        if db[name] != nil {
            db.removeValue(forKey: name)
            Pong.writeJSON(PairState.pairsPath, db)
        }
        let active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == name {
            Pong.writeJSON(PairState.activePath,
                           ["session": NSNull(), "updated": Date().timeIntervalSince1970])
            stopWindowRelay()
        }
        let anyWindow = PairState.loadPairsDb().values
            .compactMap { $0 as? [String: Any] }
            .contains { $0["claude_mode"] as? String == "window" }
        if !anyWindow { stopWindowRelay() }
        Pong.log("killed \(name) (+ views)")
    }

    /// Background relay: tmux :1 → live Claude window (window-mode links).
    static func startWindowRelay() {
        stopWindowRelay()
        var script = NSHomeDirectory() + "/bin/claude-window-relay.py"
        if !FileManager.default.fileExists(atPath: script),
           let bundled = Bundle.main.resourcePath.map({ $0 + "/claude-window-relay.py" }),
           FileManager.default.fileExists(atPath: bundled) {
            script = bundled
        }
        guard FileManager.default.fileExists(atPath: script) else {
            Pong.log("relay script missing")
            return
        }
        let pid = Pong.sh("nohup python3 '\(script)' >/dev/null 2>&1 & echo $!")
        if Int(pid) != nil {
            try? pid.write(toFile: Pong.stateDir + "/relay.pid", atomically: true, encoding: .utf8)
            Pong.log("window relay started pid=\(pid)")
        }
    }

    static func stopWindowRelay() {
        let pidPath = Pong.stateDir + "/relay.pid"
        if let s = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid_t(pid), SIGTERM)
            Pong.log("relay stopped pid=\(pid)")
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var glowPhase: CGFloat = 0
    private var boltIdle: NSImage?
    private var boltActiveDim: NSImage?
    private var boltActiveBright: NSImage?
    private var hasActivePair = false
    private var onboardingWindow: NSWindow?
    private var cachedSessions: [String] = []
    private var lastSessionPoll = Date.distantPast

    private var onboardedFlagPath: String { NSHomeDirectory() + "/.hermes-pong/onboarded" }
    private var isOnboarded: Bool { FileManager.default.fileExists(atPath: onboardedFlagPath) }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            guard let self else { return }
            if self.isOnboarded {
                self.openPanel()
            } else {
                self.showOnboarding()
            }
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
        alert.informativeText = "Pair Hermes + Claude Code in Terminal.\nkulpio/Hermes-Pong"
        alert.runModal()
    }

    // MARK: - First-run onboarding

    @objc func showOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        func label(_ text: String, bold: Bool = false, size: CGFloat = 13, muted: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            if muted { l.textColor = .secondaryLabelColor }
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return l
        }
        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            return b
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("Two one-time macOS permissions", bold: true, size: 15))
        stack.addArrangedSubview(label(
            "Hermes Pong bridges two Terminal windows. macOS asks once for each permission below — that's it.",
            muted: true))

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("Automation", bold: true))
        stack.addArrangedSubview(label(
            "Hermes Pong sends tasks into your Terminal windows. macOS prompts the first time a task is sent — if you decline, re-enable it in Settings.",
            muted: true))
        stack.addArrangedSubview(button("Open Automation Settings…", #selector(openAutomationSettings)))

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("Accessibility", bold: true))
        stack.addArrangedSubview(label(
            "Needed so paste + Enter lands reliably in the Claude Code window.",
            muted: true))
        stack.addArrangedSubview(button("Open Accessibility Settings…", #selector(openAccessibilitySettings)))

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label(
            "Everything — pairs, tasks, and the verdict ledger — stays on this Mac. Nothing is sent anywhere.",
            muted: true))

        let done = button("Done", #selector(finishOnboarding))
        done.keyEquivalent = "\r"
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(done)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Hermes Pong"
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 470),
        ])
        window.setContentSize(stack.fittingSize)
        window.center()

        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func finishOnboarding() {
        let dir = NSHomeDirectory() + "/.hermes-pong"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: onboardedFlagPath, contents: Data())
        onboardingWindow?.close()
        onboardingWindow = nil
        openPanel()
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

    // MARK: - Verdict ledger (read-only monitoring surface)

    private struct LedgerSummary {
        let rounds: Int
        let acceptPct: Int
        let rejectStreak: Int
        let lastLine: String
    }

    private var ledgerDirPath: String { NSHomeDirectory() + "/.hermes-pong/ledger" }

    private func ledgerSummary() -> LedgerSummary? {
        let path = ledgerDirPath + "/verdicts.jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var verdicts: [(verdict: String, task: String, round: Int)] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let d = obj as? [String: Any],
                  let v = d["verdict"] as? String else { continue }
            verdicts.append((v, d["task_id"] as? String ?? "?", d["round"] as? Int ?? 0))
        }
        guard !verdicts.isEmpty else { return nil }
        let accepts = verdicts.filter { $0.verdict == "accept" }.count
        var streak = 0
        for v in verdicts.reversed() {
            if v.verdict == "reject" { streak += 1 } else { break }
        }
        let last = verdicts[verdicts.count - 1]
        return LedgerSummary(
            rounds: verdicts.count,
            acceptPct: Int((Double(accepts) / Double(verdicts.count) * 100).rounded()),
            rejectStreak: streak,
            lastLine: "\(last.verdict) (\(last.task) r\(last.round))"
        )
    }

    @objc func openLedgerFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: ledgerDirPath))
    }

    /// Pair names for the menu + glow. Polled at most every 2s — tmux is
    /// resolved via PATH (Homebrew locations), not a hardcoded /usr/bin path.
    private func pairSessions() -> [String] {
        if Date().timeIntervalSince(lastSessionPoll) > 2.0 {
            cachedSessions = PairState.listPairs()
            lastSessionPoll = Date()
        }
        return cachedSessions
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
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    // Called each time the status menu opens — keeps pair + ledger rows fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
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

        if let sum = ledgerSummary() {
            menu.addItem(.separator())
            let head = NSMenuItem(title: "Verdict ledger", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            let warn = sum.rejectStreak >= 2 ? "⚠︎ " : ""
            let stats = NSMenuItem(
                title: "\(warn)\(sum.rounds) rounds · accept \(sum.acceptPct)% · reject streak \(sum.rejectStreak)",
                action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
            let last = NSMenuItem(title: "Last: \(sum.lastLine)", action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
            menu.addItem(item("Open ledger folder", #selector(openLedgerFolder)))
        }

        menu.addItem(.separator())
        menu.addItem(item("New pair", #selector(newPair)))
        menu.addItem(item("Refresh", #selector(refreshMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hermes Pong", #selector(quitAll)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func refreshMenu() {
        lastSessionPoll = .distantPast
        rebuildMenu()
    }

    @objc func openPanel() {
        PanelController.shared.show()
    }

    @objc func newPair() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Pairing.startFresh()
            DispatchQueue.main.async { [weak self] in
                self?.lastSessionPoll = .distantPast
                self?.rebuildMenu()
                PanelController.shared.refreshUI()
            }
        }
    }

    @objc func rejoinNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(name) }
    }

    @objc func killNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Pairing.killPair(name)
        lastSessionPoll = .distantPast
        rebuildMenu()
        PanelController.shared.refreshUI()
    }

    @objc func quitAll() {
        // Clean up any panel process left over from pre-1.3 installs.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "hermes_pairing.py"]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }
}

// MARK: - Control panel window (Swift port of hermes_pairing.py)

final class PanelController: NSObject {
    static let shared = PanelController()

    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private var listContainer: NSView!
    private let guide = LinkGuideController()

    private let W: CGFloat = 460, H: CGFloat = 720, PAD: CGFloat = 28

    func show() {
        if window == nil { buildWindow() }
        refreshUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: UI helpers (mirror the old panel's lbl/btn)

    static func label(_ text: String, frame: NSRect, bold: Bool = false,
                      size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        if secondary { f.textColor = .secondaryLabelColor }
        f.frame = frame
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 4
        return f
    }

    private func button(_ title: String, _ sel: Selector, _ frame: NSRect,
                        id: String? = nil) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .rounded
        b.target = self
        b.action = sel
        if let id { b.identifier = NSUserInterfaceItemIdentifier(id) }
        return b
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Hermes Pong"
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let res = Bundle.main.resourcePath ?? ""

        // Logo tile (top left)
        let logoCandidates = ["AppIcon-1024.png", "logo.png", "logo-accent.png", "logo-monochrome.png"]
            .map { res + "/" + $0 }
        if let logoPath = logoCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
           let img = NSImage(contentsOfFile: logoPath) {
            let size: CGFloat = 44
            let container = NSView(frame: NSRect(x: PAD - 2, y: H - PAD - size + 2, width: size + 4, height: size + 4))
            container.wantsLayer = true
            container.layer?.cornerRadius = 12
            container.layer?.masksToBounds = true
            container.layer?.backgroundColor =
                NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1.0).cgColor
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor =
                NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.3, alpha: 0.9).cgColor
            let iv = NSImageView(frame: NSRect(x: 2, y: 2, width: size, height: size))
            iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 10
            iv.layer?.masksToBounds = true
            container.addSubview(iv)
            content.addSubview(container)
        }

        var y = H - PAD
        y -= 34
        content.addSubview(Self.label("Hermes Pong",
            frame: NSRect(x: (W - 180) / 2, y: y, width: 180, height: 34), bold: true, size: 26))
        y -= 24
        let subW = min(W - 2 * PAD, 340)
        let sub = Self.label("Hermes Pong — two terminals, one bridge.",
            frame: NSRect(x: (W - subW) / 2, y: y, width: subW, height: 20), size: 13, secondary: true)
        sub.alignment = .center
        content.addSubview(sub)

        y -= 30
        statusLabel = Self.label("○ Idle",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 20), size: 13, secondary: true)
        content.addSubview(statusLabel)

        y -= 120
        if let img = NSImage(contentsOfFile: res + "/pair-illustration.png") {
            let iv = NSImageView(frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 110))
            iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            content.addSubview(iv)
        }

        y -= 36
        content.addSubview(Self.label("SETUP",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 16), size: 11, secondary: true))
        y -= 44
        content.addSubview(button("New pair", #selector(newPairPressed(_:)),
            NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 38)))
        y -= 36
        content.addSubview(Self.label("Opens 2 Terminals: one Hermes, one Claude (fresh Claude).",
            frame: NSRect(x: PAD + 2, y: y, width: W - 2 * PAD - 4, height: 32), size: 12, secondary: true))
        y -= 48
        content.addSubview(button("Link existing terminals", #selector(linkPressed(_:)),
            NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 38)))
        y -= 48
        content.addSubview(Self.label(
            "Pick your open Hermes + Claude windows. Keeps Claude model, resume, and chat. Nothing injected into Claude.",
            frame: NSRect(x: PAD + 2, y: y, width: W - 2 * PAD - 4, height: 44), size: 12, secondary: true))

        y -= 40
        content.addSubview(Self.label("ACTIVE PAIRS",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 16), size: 11, secondary: true))
        y -= 16
        content.addSubview(Self.label("Hermes verifies every CLAIM and loops until accept or escalate.",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 13), size: 9, secondary: true))
        y -= 14
        content.addSubview(Self.label("Perms = per-pair access bans + note, injected on every handoff.",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 13), size: 9, secondary: true))

        y -= 228
        listContainer = NSView(frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 190))
        content.addSubview(listContainer)

        let half = (W - 2 * PAD - 12) / 2
        content.addSubview(button("Refresh", #selector(refreshPressed(_:)),
            NSRect(x: PAD, y: 24, width: half, height: 36)))
        content.addSubview(button("Close Panel", #selector(closePressed(_:)),
            NSRect(x: PAD + half + 12, y: 24, width: half, height: 36)))

        win.contentView = content
        window = win
    }

    func refreshUI() {
        let pairs = PairState.listPairs()
        statusLabel?.stringValue = pairs.isEmpty
            ? "○ Idle  ·  no pair running"
            : "● \(pairs.count) active  ·  \(pairs.joined(separator: ", "))"
        rebuildList(pairs)
    }

    private func rebuildList(_ pairs: [String]) {
        guard let listContainer else { return }
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        if pairs.isEmpty {
            listContainer.addSubview(Self.label("No pairs yet — use New pair.",
                frame: NSRect(x: 0, y: 150, width: W - 2 * PAD, height: 20), size: 12, secondary: true))
            return
        }
        var y: CGFloat = 150
        for name in pairs {
            let row = NSView(frame: NSRect(x: 0, y: y - 8, width: W - 2 * PAD, height: 44))
            row.addSubview(Self.label("●  \(name)",
                frame: NSRect(x: 0, y: 12, width: 150, height: 20), bold: true, size: 13))
            row.addSubview(button("Front", #selector(frontPressed(_:)),
                NSRect(x: 155, y: 6, width: 55, height: 28), id: name))
            row.addSubview(button("Kill", #selector(killPressed(_:)),
                NSRect(x: 214, y: 6, width: 55, height: 28), id: name))
            // Per-pair access bans + freeform note (sheet). Label shows count if any ban on.
            let perms = PairState.permissions(for: name)
            let onCount = ["ban_mcp", "ban_root", "ban_network", "ban_system_paths", "repo_only"]
                .filter { (perms[$0] as? Bool) == true }.count
            let noteOn = !((perms["custom_prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let permsTitle = (onCount > 0 || noteOn) ? "Perms·\(onCount + (noteOn ? 1 : 0))" : "Perms"
            row.addSubview(button(permsTitle, #selector(permsPressed(_:)),
                NSRect(x: 273, y: 6, width: 90, height: 28), id: name))
            listContainer.addSubview(row)
            y -= 48
        }
    }

    // MARK: Actions

    @objc private func newPairPressed(_ sender: NSButton) {
        DispatchQueue.global(qos: .userInitiated).async {
            let name = Pairing.startFresh()
            usleep(200_000)
            DispatchQueue.main.async {
                self.refreshUI()
                Self.showPairPersistTip(name)
            }
        }
    }

    @objc private func linkPressed(_ sender: NSButton) {
        Pong.log("link → guide")
        guide.startLink(parent: self)
    }

    @objc private func frontPressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(name) }
    }

    @objc private func killPressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        Pairing.killPair(name)
        refreshUI()
    }

    @objc private func permsPressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        PermissionsSheetController.shared.show(for: name) { [weak self] in
            self?.refreshUI()
        }
    }

    @objc private func refreshPressed(_ sender: NSButton) { refreshUI() }

    @objc private func closePressed(_ sender: NSButton) {
        guide.closeGuide()
        window?.close()
    }

    /// After connect: pair survives app quit until Kill. One-time reminder.
    static func showPairPersistTip(_ name: String) {
        let flag = Pong.stateDir + "/dont-remind-pair-persist"
        guard !FileManager.default.fileExists(atPath: flag) else { return }
        let label = name.isEmpty ? "this pair" : name
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pair stays connected"
        alert.informativeText =
            "“\(label)” stays linked until you hit Kill — even if you quit Hermes Pong.\n\n" +
            "Link existing = keeps your Claude model, resume, and chat.\n" +
            "New pair = two fresh Terminals (Claude starts clean).\n\n" +
            "When Hermes delegates, the task pastes into your Claude Code window."
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Don't remind me")
        if alert.runModal() == .alertSecondButtonReturn {
            try? "1\n".write(toFile: flag, atomically: true, encoding: .utf8)
            Pong.log("dont-remind-pair-persist set")
        }
    }
}

// MARK: - Per-pair access permissions sheet

/// Modal sheet: tick ban boxes + freeform prompt. Stored on the pair in pairs.json
/// and mirrored into active-pair.json so claude-delegate can inject constraints.
final class PermissionsSheetController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = PermissionsSheetController()

    private var window: NSWindow?
    private var pairName = ""
    private var onSaved: (() -> Void)?
    private var boxes: [String: NSButton] = [:]
    private var noteView: NSTextView!

    private let keys: [(String, String)] = [
        ("ban_mcp", "Ban MCP tools / external tool servers"),
        ("ban_root", "Ban root / outside-project writes"),
        ("repo_only", "Repo-only (stay inside the project tree)"),
        ("ban_network", "Ban network installs / outbound fetches"),
        ("ban_system_paths", "Ban system paths (~/.ssh, /etc, keychains)"),
    ]

    func show(for name: String, onSaved: @escaping () -> Void) {
        self.pairName = name
        self.onSaved = onSaved
        if window == nil { buildWindow() }
        loadIntoUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func buildWindow() {
        let W: CGFloat = 440, H: CGFloat = 460
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Pair permissions"
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
        win.delegate = self
        win.level = .floating

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let PAD: CGFloat = 22
        var y = H - PAD - 8

        let title = NSTextField(labelWithString: "Access for this pair")
        title.font = .boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: PAD, y: y - 20, width: W - 2 * PAD, height: 22)
        content.addSubview(title)
        y -= 28

        let sub = NSTextField(wrappingLabelWithString:
            "Checked boxes ban that access for Claude on every handoff. Optional note explains or tightens further.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: PAD, y: y - 40, width: W - 2 * PAD, height: 40)
        content.addSubview(sub)
        y -= 52

        boxes.removeAll()
        for (key, label) in keys {
            let b = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            b.frame = NSRect(x: PAD, y: y - 24, width: W - 2 * PAD, height: 24)
            b.font = .systemFont(ofSize: 13)
            content.addSubview(b)
            boxes[key] = b
            y -= 28
        }

        y -= 8
        let noteLbl = NSTextField(labelWithString: "Extra note (injected into Claude)")
        noteLbl.font = .systemFont(ofSize: 11)
        noteLbl.textColor = .secondaryLabelColor
        noteLbl.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(noteLbl)
        y -= 22

        let scrollH: CGFloat = 110
        let scroll = NSScrollView(frame: NSRect(x: PAD, y: y - scrollH, width: W - 2 * PAD, height: scrollH))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scrollH))
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.isEditable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.string = ""
        tv.delegate = self
        scroll.documentView = tv
        content.addSubview(scroll)
        noteView = tv
        y -= scrollH + 18

        let save = NSButton(frame: NSRect(x: W - PAD - 100, y: 18, width: 100, height: 32))
        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(savePressed)
        content.addSubview(save)

        let cancel = NSButton(frame: NSRect(x: W - PAD - 210, y: 18, width: 100, height: 32))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)

        let clear = NSButton(frame: NSRect(x: PAD, y: 18, width: 90, height: 32))
        clear.title = "Clear all"
        clear.bezelStyle = .rounded
        clear.target = self
        clear.action = #selector(clearPressed)
        content.addSubview(clear)

        win.contentView = content
        window = win
    }

    private func loadIntoUI() {
        window?.title = "Permissions · \(pairName)"
        let perms = PairState.permissions(for: pairName)
        for (key, box) in boxes {
            box.state = ((perms[key] as? Bool) == true) ? .on : .off
        }
        noteView?.string = (perms["custom_prompt"] as? String) ?? ""
    }

    @objc private func clearPressed() {
        for box in boxes.values { box.state = .off }
        noteView?.string = ""
    }

    @objc private func cancelPressed() {
        window?.orderOut(nil)
    }

    @objc private func savePressed() {
        var perms = PairState.defaultPermissions()
        for (key, box) in boxes {
            perms[key] = (box.state == .on)
        }
        perms["custom_prompt"] = noteView?.string ?? ""
        let prev = PairState.loadPairsDb()[pairName] as? [String: Any] ?? [:]
        PairState.savePairState(
            pairName,
            hermesWindowId: prev["hermes_window_id"] as? String,
            claudeWindowId: prev["claude_window_id"] as? String,
            claudeMode: prev["claude_mode"] as? String,
            permissions: perms
        )
        Pong.log("permissions \(pairName) -> \(perms)")
        window?.orderOut(nil)
        onSaved?()
    }

    func windowWillClose(_ notification: Notification) {
        // no-op; isReleasedWhenClosed = false
    }
}

// MARK: - Link guide (click-to-select two Terminal windows)

final class LinkGuideController: NSObject {
    private enum Phase { case hermes, claude, wiring, done, idle }

    private var window: NSWindow?
    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var hermesMark: NSTextField!
    private var claudeMark: NSTextField!
    private var hintLabel: NSTextField!
    private var timer: Timer?
    private var monitor: Any?
    private var phase: Phase = .idle
    private var hermesId: String?
    private var claudeId: String?
    private var pairName = ""
    private weak var parent: PanelController?
    private var baselineId: String?
    private var lastFront: String?
    private var started = Date()

    private let GW: CGFloat = 400, GH: CGFloat = 280

    func startLink(parent: PanelController) {
        self.parent = parent
        phase = .hermes
        hermesId = nil
        claudeId = nil
        pairName = PairState.nextPairName()
        started = Date()
        baselineId = Pairing.frontTerminalId()
        lastFront = baselineId
        Pong.log("startLink click-select pair=\(pairName) baseline=\(baselineId ?? "-")")
        ensureWindow()
        render()
        window?.center()
        window?.orderFrontRegardless()
        installClickMonitor()
        armTimer()
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: GW, height: GH),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Hermes Pong — Link"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: GW, height: GH))
        stepLabel = PanelController.label("Step 1 of 2",
            frame: NSRect(x: 16, y: GH - 36, width: GW - 32, height: 18), size: 11, secondary: true)
        titleLabel = PanelController.label("Click the HERMES Terminal window",
            frame: NSRect(x: 16, y: GH - 68, width: GW - 32, height: 28), bold: true, size: 15)
        hermesMark = PanelController.label("○  Hermes  —  not selected",
            frame: NSRect(x: 16, y: GH - 120, width: GW - 32, height: 22), size: 13)
        claudeMark = PanelController.label("○  Claude  —  not selected",
            frame: NSRect(x: 16, y: GH - 150, width: GW - 32, height: 22), size: 13)
        hintLabel = PanelController.label(
            "Click the Terminal window itself.\nNothing is drawn on it — the mark only appears here.",
            frame: NSRect(x: 16, y: 56, width: GW - 32, height: 50), size: 12, secondary: true)
        let cancel = NSButton(frame: NSRect(x: GW - 100, y: 14, width: 84, height: 32))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelPressed(_:))
        for v in [stepLabel!, titleLabel!, hermesMark!, claudeMark!, hintLabel!] {
            content.addSubview(v)
        }
        content.addSubview(cancel)
        win.contentView = content
        window = win
    }

    private func titleFor(_ wid: String?) -> String {
        guard let wid else { return "" }
        for (i, t) in Pairing.listTerminalWindows() where i == wid {
            return String(t.prefix(48))
        }
        return "window \(wid)"
    }

    private func render() {
        switch phase {
        case .hermes:
            stepLabel.stringValue = "Step 1 of 2"
            titleLabel.stringValue = "Click the HERMES Terminal window"
            hintLabel.stringValue = "Click the Terminal that runs Hermes.\nSelection mark only shows in this popup."
        case .claude:
            stepLabel.stringValue = "Step 2 of 2"
            titleLabel.stringValue = "Click the CLAUDE Terminal window"
            hintLabel.stringValue = "Click a different Terminal for Claude.\nNo scripts will be typed into Claude chat."
        case .wiring:
            stepLabel.stringValue = "Linking…"
            titleLabel.stringValue = "Pairing without touching Claude chat"
            hintLabel.stringValue = "Registering windows. Hermes and Claude keep their own UIs."
        case .done:
            stepLabel.stringValue = "Done"
            titleLabel.stringValue = "Linked"
            hintLabel.stringValue = "Work stays in each window. Bridge paste+Enter only."
        case .idle:
            break
        }
        hermesMark.stringValue = hermesId != nil
            ? "✓  Hermes  —  \(titleFor(hermesId))" : "○  Hermes  —  not selected"
        claudeMark.stringValue = claudeId != nil
            ? "✓  Claude  —  \(titleFor(claudeId))" : "○  Claude  —  not selected"
    }

    private func installClickMonitor() {
        removeClickMonitor()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.trySelectFront(force: true)
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func armTimer() {
        timer?.invalidate()
        // Poll front window too — works even without Accessibility for the monitor.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard phase == .hermes || phase == .claude else { return }
        if Date().timeIntervalSince(started) > 60 {
            phase = .idle
            titleLabel.stringValue = "Timed out"
            hintLabel.stringValue = "Try Link again and click a Terminal window."
            stopTimer()
            removeClickMonitor()
            return
        }
        if Date().timeIntervalSince(started) < 0.5 { return }
        trySelectFront(force: false)
    }

    private func trySelectFront(force: Bool) {
        guard phase == .hermes || phase == .claude else { return }
        guard let wid = Pairing.frontTerminalId() else { return }
        if !force && wid == lastFront { return }
        if phase == .hermes {
            if wid == baselineId && !force {
                lastFront = wid
                return
            }
            accept(wid)
        } else {
            if wid == hermesId {
                hintLabel.stringValue = "That’s Hermes. Click the other Terminal for Claude."
                lastFront = wid
                return
            }
            if force || wid != lastFront { accept(wid) }
        }
        lastFront = wid
    }

    private func accept(_ wid: String) {
        if phase == .hermes {
            hermesId = wid
            phase = .claude
            started = Date()
            baselineId = wid
            lastFront = wid
            Pong.log("selected HERMES id=\(wid)")
            render()
        } else if phase == .claude {
            guard wid != hermesId else { return }
            claudeId = wid
            phase = .wiring
            Pong.log("selected CLAUDE id=\(wid)")
            render()
            stopTimer()
            removeClickMonitor()
            let (hid, cid, name) = (hermesId!, claudeId!, pairName)
            DispatchQueue.global(qos: .userInitiated).async {
                Pairing.wirePair(name, hid, cid)
                DispatchQueue.main.async { self.finishOk(name) }
            }
        }
    }

    private func finishOk(_ name: String) {
        phase = .done
        render()
        titleLabel.stringValue = "Linked · \(name)"
        parent?.refreshUI()
        PanelController.showPairPersistTip(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.closeGuide() }
    }

    @objc private func cancelPressed(_ sender: NSButton) { closeGuide() }

    func closeGuide() {
        phase = .idle
        stopTimer()
        removeClickMonitor()
        window?.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

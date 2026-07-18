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
        // View sessions are not pairs (Hermes view, legacy Claude view, worker views).
        if s.hasSuffix("-h") || s.hasSuffix("-c") { return false }
        // hermes-pair-w0 / hermes-pair-1-w2 — Phase 2 worker view sessions
        if s.range(of: #"-w\d+$"#, options: .regularExpression) != nil { return false }
        return s == "hermes-claude" || s.hasPrefix("hermes-claude-")
            || s == "hermes-pair" || s.hasPrefix("hermes-pair-")
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
        if !existing.contains("hermes-pair") { return "hermes-pair" }
        for n in 1...50 where !existing.contains("hermes-pair-\(n)") { return "hermes-pair-\(n)" }
        // legacy names still listed; don't reuse hermes-claude as default
        return "hermes-pair-\(Int(Date().timeIntervalSince1970) % 10000)"
    }

    /// Default per-pair access constraints (bans + freeform note).
    /// Checked boxes mean "ban this". Injected into the worker via the bridge (claude-delegate).
    static func defaultPermissions() -> [String: Any] {
        [
            "ban_mcp": false,
            "ban_root": false,
            "ban_network": false,
            "ban_system_paths": false,
            "repo_only": false,
            "ask_each": false,
            "custom_prompt": "",
        ]
    }

    /// Full access preset: no bans, no ask gate.
    static func fullAccessPermissions() -> [String: Any] {
        defaultPermissions()
    }

    /// Ask-each-time preset: Claude must request elevated access in chat first.
    static func askEachPermissions() -> [String: Any] {
        var p = defaultPermissions()
        p["ask_each"] = true
        p["custom_prompt"] =
            "Before any elevated action, ask me in this chat and wait for a clear yes. " +
            "Elevated = MCP tools, network/installs, files outside the project, system paths " +
            "(~/.ssh, /etc, keychains), sudo/root, or destructive shell. One yes does not unlock the rest."
        return p
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
                              permissions: [String: Any]? = nil,
                              workerType: String? = nil,
                              workerLabel: String? = nil,
                              workerCmd: String? = nil,
                              workers: [[String: Any]]? = nil) {
        var db = loadPairsDb()
        let prev = db[session] as? [String: Any] ?? [:]
        var ws = workers ?? (prev["workers"] as? [[String: Any]])
        if ws == nil || ws?.isEmpty == true {
            ws = Workers.list(from: prev)
        }
        // Primary window for bridge compat
        let primaryWid: Any = {
            if let workers, let first = workers.first?["window_id"] { return first }
            if let claudeWindowId { return claudeWindowId }
            if let p = prev["claude_window_id"] { return p }
            return NSNull()
        }()
        let primaryType = (ws?.first?["type"] as? String)
            ?? workerType ?? (prev["worker_type"] as? String) ?? "claude"
        let primaryLabel = (ws?.first?["label"] as? String)
            ?? workerLabel ?? (prev["worker_label"] as? String) ?? "Worker"
        let primaryCmd = (ws?.first?["cmd"] as? String)
            ?? workerCmd ?? (prev["worker_cmd"] as? String) ?? "claude"
        let mode = claudeMode
            ?? (ws?.first?["mode"] as? String)
            ?? (prev["claude_mode"] as? String) ?? "tmux"
        var entry: [String: Any] = [
            "hermes_window_id": hermesWindowId ?? prev["hermes_window_id"] ?? NSNull(),
            "claude_window_id": primaryWid,
            "worker_window_id": primaryWid,
            "claude_mode": mode,
            "worker_type": primaryType,
            "worker_label": primaryLabel,
            "worker_cmd": primaryCmd,
            "autonomy_level": "full",
            "updated": Date().timeIntervalSince1970,
        ]
        if let ws, !ws.isEmpty {
            entry["workers"] = ws
        }
        for k in ["view_hermes", "view_claude", "view_worker"] {
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

// MARK: - Worker types (Phase 1: one worker per Hermes; army comes later)

/// Built-in worker seeds. User signs into each CLI themselves; we only launch the cmd.
struct WorkerType: Equatable {
    let id: String
    let label: String
    let cmd: String
    let tmuxWindowName: String

    static let all: [WorkerType] = [
        WorkerType(id: "claude", label: "Claude Code", cmd: "claude", tmuxWindowName: "Worker"),
        WorkerType(id: "kimi", label: "Kimi", cmd: "kimi", tmuxWindowName: "Worker"),
        WorkerType(id: "grok", label: "Grok", cmd: "grok", tmuxWindowName: "Worker"),
        WorkerType(id: "codex", label: "Codex", cmd: "codex", tmuxWindowName: "Worker"),
        WorkerType(id: "opencode", label: "OpenCode", cmd: "opencode", tmuxWindowName: "Worker"),
        WorkerType(id: "custom", label: "Custom command…", cmd: "", tmuxWindowName: "Worker"),
    ]

    static func named(_ id: String) -> WorkerType {
        all.first(where: { $0.id == id }) ?? all[0]
    }

    /// Load optional overrides from ~/.hermes-pong/workers.json → { "kimi": { "cmd": "…" } }
    static func resolved(_ id: String) -> WorkerType {
        var base = named(id)
        let path = Pong.stateDir + "/workers.json"
        let db = Pong.loadJSON(path)
        if let row = db[id] as? [String: Any], let cmd = row["cmd"] as? String, !cmd.isEmpty {
            base = WorkerType(id: base.id, label: (row["label"] as? String) ?? base.label,
                              cmd: cmd, tmuxWindowName: base.tmuxWindowName)
        }
        return base
    }
}

// MARK: - Workers array helpers (Phase 2 army)

enum Workers {
    /// Normalize pair entry → workers array. Migrates legacy single-worker fields.
    static func list(from entry: [String: Any]) -> [[String: Any]] {
        if let arr = entry["workers"] as? [[String: Any]], !arr.isEmpty {
            return arr
        }
        // Legacy: single claude_window_id / worker_*
        let wid = entry["claude_window_id"] ?? entry["worker_window_id"]
        if wid == nil || wid is NSNull { return [] }
        return [[
            "id": "w1",
            "type": entry["worker_type"] ?? "claude",
            "label": entry["worker_label"] ?? "Worker",
            "window_id": wid as Any,
            "mode": entry["claude_mode"] ?? "tmux",
            "cmd": entry["worker_cmd"] ?? "claude",
            "tmux_index": 1,
        ]]
    }

    static func primaryWindowId(from entry: [String: Any]) -> String? {
        let ws = list(from: entry)
        if let w = ws.first, let id = w["window_id"] {
            let s = "\(id)"
            if s != "<null>", !s.isEmpty { return s }
        }
        return nil
    }

    static func makeWorker(id: String, type: String, label: String, windowId: String,
                           mode: String, cmd: String, tmuxIndex: Int) -> [String: Any] {
        [
            "id": id,
            "type": type,
            "label": label,
            "window_id": windowId,
            "mode": mode,
            "cmd": cmd,
            "tmux_index": tmuxIndex,
            "done_marker": type == "claude" ? "##CLAUDE_DONE##" : "##WORKER_DONE##",
            "permissions": PairState.defaultPermissions(),
        ]
    }

    static func permissions(pair: String, workerId: String) -> [String: Any] {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let ws = list(from: entry)
        if let w = ws.first(where: { ($0["id"] as? String) == workerId }),
           let p = w["permissions"] as? [String: Any] {
            var merged = PairState.defaultPermissions()
            for (k, v) in p { merged[k] = v }
            return merged
        }
        // fall back to pair-level permissions
        return PairState.permissions(for: pair)
    }

    static func setPermissions(pair: String, workerId: String, permissions: [String: Any]) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return }
        ws[idx]["permissions"] = permissions
        entry["workers"] = ws
        // if only one worker / primary, keep pair-level in sync for bridge default
        if idx == 0 { entry["permissions"] = permissions }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair {
            active["workers"] = ws
            if idx == 0 { active["permissions"] = permissions }
            active["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(PairState.activePath, active)
        }
        Pong.log("worker perms \(pair)/\(workerId)")
    }

    /// Remove one worker from the team; kill its view session. Pair stays if workers remain.
    @discardableResult
    static func removeWorker(pair: String, workerId: String) -> Bool {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return false }
        let removed = ws.remove(at: idx)
        // kill view session name-w(index) if known
        if let ti = removed["tmux_index"] as? Int {
            let view = "\(pair)-w\(ti - 1)"
            Pong.sh("tmux kill-session -t \(view) 2>/dev/null || true")
            // kill pane/window in base if possible
            Pong.sh("tmux kill-window -t \(pair):\(ti) 2>/dev/null || true")
        }
        if ws.isEmpty {
            // last worker gone → kill whole pair
            Pairing.killPair(pair)
            return true
        }
        // reindex ids optional — keep stable w1/w2 ids
        entry["workers"] = ws
        if let first = ws.first {
            entry["claude_window_id"] = first["window_id"] ?? NSNull()
            entry["worker_window_id"] = first["window_id"] ?? NSNull()
            entry["worker_type"] = first["type"] ?? "linked"
            entry["worker_label"] = first["label"] ?? "Worker"
            entry["worker_cmd"] = first["cmd"] ?? ""
            entry["claude_mode"] = first["mode"] ?? "tmux"
        }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair {
            active["workers"] = ws
            active["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(PairState.activePath, active)
        }
        Pong.log("removed worker \(pair)/\(workerId) remaining=\(ws.count)")
        return true
    }

    static func setWorkerLabel(pair: String, workerId: String, label: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ws[idx]["label"] = trimmed
        entry["workers"] = ws
        if idx == 0 { entry["worker_label"] = trimmed }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        TerminalTheme.applyPair(pair)
        Pong.log("rename worker \(pair)/\(workerId) → \(trimmed)")
    }

    static func setWorkerColors(pair: String, workerId: String, colors: TerminalTheme.Colors) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return }
        ws[idx]["colors"] = colors.asDict()
        entry["workers"] = ws
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        TerminalTheme.applyPair(pair)
        Pong.log("colors worker \(pair)/\(workerId)")
    }

    static func setPairDisplayName(_ pair: String, _ name: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["display_name"] = trimmed
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        TerminalTheme.applyPair(pair)
        Pong.log("rename pair \(pair) → \(trimmed)")
    }

    static func setPairColors(_ pair: String, colors: TerminalTheme.Colors) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["colors"] = colors.asDict()
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        TerminalTheme.applyPair(pair)
        Pong.log("colors pair \(pair)")
    }

    private static func syncActive(_ pair: String, entry: [String: Any]) {
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair {
            for (k, v) in entry { active[k] = v }
            active["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(PairState.activePath, active)
        }
    }

    static func frontWorker(pair: String, workerId: String) {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let ws = list(from: entry)
        guard let w = ws.first(where: { ($0["id"] as? String) == workerId }) else { return }
        let wid = "\(w["window_id"] ?? "")"
        if Int(wid) != nil {
            TerminalTheme.applyPair(pair)
            Pairing.flashPairWindows(wid, nil)
            return
        }
        // fallback: attach view
        if let ti = w["tmux_index"] as? Int {
            let view = "\(pair)-w\(ti - 1)"
            Pong.sh("tmux has-session -t \(view) 2>/dev/null && open -a Terminal && tmux attach -t \(view) || true")
            Pong.osascript("""
            tell application "Terminal"
              activate
              try
                do script "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; tmux attach-session -t \(view)"
              end try
            end tell
            """)
        }
    }
}


// MARK: - Terminal titles + colors

/// Per-window look for Hermes / each worker. Stored on pair or workers[].colors.
enum TerminalTheme {
    /// RGB 0…1
    struct Colors {
        var bg: (CGFloat, CGFloat, CGFloat)
        var text: (CGFloat, CGFloat, CGFloat)
        var highlight: (CGFloat, CGFloat, CGFloat)

        static let hermesDefault = Colors(
            bg: (0.06, 0.07, 0.12),
            text: (0.90, 0.92, 0.98),
            highlight: (0.15, 0.01, 0.95)
        )
        static let workerDefault = Colors(
            bg: (0.10, 0.08, 0.06),
            text: (0.95, 0.93, 0.88),
            highlight: (0.85, 0.45, 0.30)
        )

        static func from(_ any: Any?) -> Colors? {
            guard let d = any as? [String: Any] else { return nil }
            func trip(_ key: String, _ fb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
                if let a = d[key] as? [Any], a.count >= 3 {
                    let r = CGFloat((a[0] as? Double) ?? Double("\(a[0])") ?? Double(fb.0))
                    let g = CGFloat((a[1] as? Double) ?? Double("\(a[1])") ?? Double(fb.1))
                    let b = CGFloat((a[2] as? Double) ?? Double("\(a[2])") ?? Double(fb.2))
                    return (r, g, b)
                }
                return fb
            }
            let fb = hermesDefault
            return Colors(bg: trip("bg", fb.bg), text: trip("text", fb.text), highlight: trip("highlight", fb.highlight))
        }

        func asDict() -> [String: Any] {
            [
                "bg": [bg.0, bg.1, bg.2],
                "text": [text.0, text.1, text.2],
                "highlight": [highlight.0, highlight.1, highlight.2],
            ]
        }

        /// Terminal AppleScript uses 16-bit RGB 0…65535
        func t16(_ c: (CGFloat, CGFloat, CGFloat)) -> String {
            let r = Int(max(0, min(1, c.0)) * 65535)
            let g = Int(max(0, min(1, c.1)) * 65535)
            let b = Int(max(0, min(1, c.2)) * 65535)
            return "{\(r), \(g), \(b)}"
        }

        var asNSColors: (bg: NSColor, text: NSColor, hi: NSColor) {
            (
                NSColor(calibratedRed: bg.0, green: bg.1, blue: bg.2, alpha: 1),
                NSColor(calibratedRed: text.0, green: text.1, blue: text.2, alpha: 1),
                NSColor(calibratedRed: highlight.0, green: highlight.1, blue: highlight.2, alpha: 1)
            )
        }
    }

    static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Dedicated profile name — never mutate Basic/Pro (that recolors unrelated Terminals).
    static func profileName(pair: String, role: String) -> String {
        let raw = "HP-\(pair)-\(role)"
            .replacingOccurrences(of: " ", with: "-")
        return raw.count <= 40 ? raw : String(raw.prefix(40))
    }

    static func listWindows() -> [(id: String, title: String)] {
        let out = Pong.osascript("""
        tell application "Terminal"
          set acc to ""
          repeat with w in windows
            try
              set acc to acc & (id of w as string) & "|||" & (name of w) & linefeed
            end try
          end repeat
          return acc
        end tell
        """)
        var rows: [(String, String)] = []
        for line in out.split(separator: "\n") {
            guard let sep = line.range(of: "|||") else { continue }
            let wid = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            if Int(wid) != nil { rows.append((wid, title)) }
        }
        return rows
    }

    static func resolveWindowId(stored: String?, hints: [String], avoid: Set<String> = []) -> String? {
        let wins = listWindows().filter { !avoid.contains($0.id) }
        let ids = Set(wins.map(\.id))
        if let s = stored, Int(s) != nil, ids.contains(s), !avoid.contains(s) { return s }
        let lowerHints = hints.map { $0.lowercased() }.filter { !$0.isEmpty }
        for (id, title) in wins {
            let t = title.lowercased()
            for h in lowerHints where t.contains(h) { return id }
        }
        return nil
    }

    /// Paint ONE window via a private settings set (do not touch shared Basic/Pro).
    static func apply(windowId: String?, title: String?, colors: Colors?, profile: String) {
        guard let wid = windowId, Int(wid) != nil else {
            Pong.log("theme apply skip — no window id profile=\(profile)")
            return
        }
        let prof = escapeAS(profile)
        var script = """
        tell application "Terminal"
          try
            set W to window id \(wid)
            set T to selected tab of W
        """
        if let title, !title.isEmpty {
            let t = escapeAS(title)
            script += """

            try
              set custom title of W to "\(t)"
            end try
            try
              set custom title of T to "\(t)"
            end try
            """
        }
        if let c = colors {
            let bg = c.t16(c.bg)
            let tx = c.t16(c.text)
            let hi = c.t16(c.highlight)
            script += """

            set setName to "\(prof)"
            try
              set theme to settings set setName
            on error
              set theme to make new settings set with properties {name:setName}
            end try
            set background color of theme to \(bg)
            set normal text color of theme to \(tx)
            set bold text color of theme to \(hi)
            set cursor color of theme to \(hi)
            try
              set selected text color of theme to \(hi)
            end try
            set current settings of T to theme
            """
        }
        script += """

            return "OK"
          on error errMsg
            return "ERR:" & errMsg
          end try
        end tell
        """
        let out = Pong.osascript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        Pong.log("theme apply window=\(wid) profile=\(profile) → \(out.isEmpty ? "(empty)" : out)")
    }

    static func applyPair(_ pair: String) {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hermesTitle = (display?.isEmpty == false) ? "● \(display!) · Hermes" : "● Hermes · \(pair)"
        let hColors = Colors.from(entry["colors"]) ?? .hermesDefault
        let storedH = entry["hermes_window_id"].flatMap { v -> String? in
            let s = "\(v)"; return (s == "<null>" || s.isEmpty) ? nil : s
        }
        let viewH = (entry["view_hermes"] as? String) ?? "\(pair)-h"
        var claimed = Set<String>()
        let hid = resolveWindowId(stored: storedH, hints: [viewH, "\(pair)-h", "HERMES ·", hermesTitle])
        if let hid { claimed.insert(hid) }
        apply(windowId: hid, title: hermesTitle, colors: hColors, profile: profileName(pair: pair, role: "hermes"))

        var ws = Workers.list(from: entry)
        var changed = false
        let views = (entry["view_workers"] as? [String]) ?? []
        for i in 0..<ws.count {
            let id = (ws[i]["id"] as? String) ?? "w\(i + 1)"
            let lab = (ws[i]["label"] as? String) ?? "Worker"
            let storedW = "\(ws[i]["window_id"] ?? "")"
            let storedOpt = Int(storedW) != nil ? storedW : nil
            var hints = [lab, id, "→ \(lab)", "WORKER · \(lab)"]
            if i < views.count { hints.insert(views[i], at: 0) }
            hints.append("\(pair)-w\(i)")
            let wid = resolveWindowId(stored: storedOpt, hints: hints, avoid: claimed)
            if let wid { claimed.insert(wid) }
            let title = "→ \(lab) · \(id)"
            let cols = Colors.from(ws[i]["colors"]) ?? .workerDefault
            apply(windowId: wid, title: title, colors: cols, profile: profileName(pair: pair, role: id))
            if let wid, storedW != wid {
                ws[i]["window_id"] = wid
                changed = true
            }
        }
        if changed || (hid != nil && hid != storedH) {
            var db = PairState.loadPairsDb()
            var e = db[pair] as? [String: Any] ?? entry
            if let hid { e["hermes_window_id"] = hid }
            e["workers"] = ws
            if let first = ws.first { e["claude_window_id"] = first["window_id"] ?? NSNull() }
            db[pair] = e
            Pong.writeJSON(PairState.pairsPath, db)
            var active = Pong.loadJSON(PairState.activePath)
            if active["session"] as? String == pair {
                for (k, v) in e { active[k] = v }
                Pong.writeJSON(PairState.activePath, active)
            }
        }
    }
}


// MARK: - Saved teams (~/.hermes-pong/teams.json)

/// Snapshot of Hermes display name/colors + worker types/labels/cmds/perms/colors.
/// Spawnable from New pair → Saved team…
enum SavedTeams {
    static var path: String { Pong.stateDir + "/teams.json" }

    struct Team {
        let id: String
        let name: String
        let displayName: String
        let hermesColors: [String: Any]?
        let workers: [[String: Any]]
    }

    static func loadAll() -> [Team] {
        let raw = Pong.loadJSON(path)
        let arr = (raw["teams"] as? [[String: Any]]) ?? []
        var out: [Team] = []
        for row in arr {
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String,
                  let workers = row["workers"] as? [[String: Any]], !workers.isEmpty else { continue }
            out.append(Team(
                id: id,
                name: name,
                displayName: (row["display_name"] as? String) ?? name,
                hermesColors: row["colors"] as? [String: Any],
                workers: workers
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func saveFromLivePair(_ pair: String, teamName: String) -> Team? {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        if ws.isEmpty { return nil }
        // Strip live window ids / modes — spawn will create fresh
        var cleanWorkers: [[String: Any]] = []
        for (i, w) in ws.enumerated() {
            var c: [String: Any] = [
                "id": (w["id"] as? String) ?? "w\(i + 1)",
                "type": (w["type"] as? String) ?? "claude",
                "label": (w["label"] as? String) ?? "Worker",
                "cmd": (w["cmd"] as? String) ?? "claude",
            ]
            if let perms = w["permissions"] as? [String: Any] { c["permissions"] = perms }
            if let colors = w["colors"] as? [String: Any] { c["colors"] = colors }
            cleanWorkers.append(c)
        }
        var trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "My team" }
        var list = loadAll()
        let id: String
        if let existing = list.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            id = existing.id
            list.removeAll { $0.id == id }
        } else {
            id = "team-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        }
        let display = (entry["display_name"] as? String) ?? trimmed
        let team = Team(
            id: id,
            name: trimmed,
            displayName: display.isEmpty ? trimmed : display,
            hermesColors: entry["colors"] as? [String: Any],
            workers: cleanWorkers
        )
        list.append(team)
        writeAll(list)
        Pong.log("saved team id=\(id) name=\(trimmed) workers=\(cleanWorkers.count)")
        return team
    }

    static func delete(id: String) {
        writeAll(loadAll().filter { $0.id != id })
        Pong.log("deleted team \(id)")
    }

    private static func writeAll(_ list: [Team]) {
        let rows: [[String: Any]] = list.map { t in
            var row: [String: Any] = [
                "id": t.id,
                "name": t.name,
                "display_name": t.displayName,
                "workers": t.workers,
            ]
            if let c = t.hermesColors { row["colors"] = c }
            return row
        }
        Pong.writeJSON(path, ["teams": rows, "updated": Date().timeIntervalSince1970])
    }

    /// Spawn a saved team as a new live pair (fresh Terminals).
    @discardableResult
    static func spawn(_ team: Team) -> String {
        var types: [WorkerType] = []
        for w in team.workers {
            let typeId = (w["type"] as? String) ?? "claude"
            let cmd = (w["cmd"] as? String) ?? WorkerType.resolved(typeId).cmd
            let label = (w["label"] as? String) ?? WorkerType.resolved(typeId).label
            if typeId == "custom" || !WorkerType.all.contains(where: { $0.id == typeId }) {
                types.append(WorkerType(id: "custom", label: label, cmd: cmd, tmuxWindowName: "Worker"))
            } else {
                var base = WorkerType.resolved(typeId)
                // keep custom label from saved team
                base = WorkerType(id: base.id, label: label, cmd: cmd.isEmpty ? base.cmd : cmd, tmuxWindowName: base.tmuxWindowName)
                types.append(base)
            }
        }
        if types.isEmpty { types = [WorkerType.resolved("claude")] }
        let pair = Pairing.startFresh(workers: types)
        // Apply saved names/colors/perms onto live pair
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["display_name"] = team.displayName
        if let hc = team.hermesColors { entry["colors"] = hc }
        var live = Workers.list(from: entry)
        for i in 0..<min(live.count, team.workers.count) {
            let saved = team.workers[i]
            if let lab = saved["label"] as? String { live[i]["label"] = lab }
            if let perms = saved["permissions"] as? [String: Any] { live[i]["permissions"] = perms }
            if let colors = saved["colors"] as? [String: Any] { live[i]["colors"] = colors }
            if let cmd = saved["cmd"] as? String { live[i]["cmd"] = cmd }
            if let typ = saved["type"] as? String { live[i]["type"] = typ }
        }
        entry["workers"] = live
        if let first = live.first {
            entry["worker_label"] = first["label"] ?? "Worker"
            entry["worker_type"] = first["type"] ?? "claude"
            entry["worker_cmd"] = first["cmd"] ?? "claude"
        }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair {
            for (k, v) in entry { active[k] = v }
            Pong.writeJSON(PairState.activePath, active)
        }
        // Small delay so Terminal windows exist, then paint
        usleep(400_000)
        TerminalTheme.applyPair(pair)
        Pong.log("spawned team \(team.name) → \(pair)")
        return pair
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

    /// Cascade team Terminals top→bottom so they read like the tree, not a horizontal row.
    static func tileWindowsVertically(hermesId: String?, workerIds: [String]) {
        var ids: [String] = []
        if let h = hermesId, Int(h) != nil { ids.append(h) }
        ids.append(contentsOf: workerIds.filter { Int($0) != nil })
        guard !ids.isEmpty else { return }
        // Screen visible frame
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 40, y: 40, width: 1200, height: 800)
        let gap: CGFloat = 8
        let n = CGFloat(ids.count)
        let h = max(180, (screen.height - gap * (n + 1)) / n)
        let w = min(screen.width * 0.55, 900)
        let x = screen.minX + 24
        // Top of screen first (Hermes)
        for (i, wid) in ids.enumerated() {
            // AppleScript set bounds: {left, top, right, bottom} in screen coords (top-left origin)
            // Terminal uses top-left for bounds in some versions; use position + size via AS
            let left = Int(x)
            // Prefer: set bounds of window id to {x, y, x+w, y+h} with y from bottom in Cocoa...
            // Terminal AppleScript bounds are {left, top, right, bottom} with top measured from top of screen.
            let topEdge = Int(gap + CGFloat(i) * (h + gap) + 28)  // menu bar clearance
            let bottomEdge = topEdge + Int(h)
            let right = left + Int(w)
            let script = """
            tell application "Terminal"
              try
                set bounds of window id \(wid) to {\(left), \(topEdge), \(right), \(bottomEdge)}
              end try
            end tell
            """
            _ = Pong.osascript(script)
        }
        Pong.log("tileWindowsVertically n=\(ids.count)")
    }

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
            return ["claude", "✳", "fable", "hermes", "⚕", "grok", "kimi", "codex", "opencode", "deepseek"].contains { t.contains($0) }
        }
        return false
    }

    /// New pair: Hermes + one or more workers (Phase 2).
    static func startFresh(worker: WorkerType = WorkerType.named("claude")) -> String {
        startFresh(workers: [worker])
    }

    static func startFresh(workers: [WorkerType]) -> String {
        var list = workers
        if list.isEmpty { list = [WorkerType.named("claude")] }
        let name = PairState.nextPairName()
        let pathExport = "export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$PATH"
        let viewH = "\(name)-h"

        var toKill = [name, viewH, "\(name)-c"]
        for i in 0..<max(list.count, 8) { toKill.append("\(name)-w\(i)") }
        for s in toKill {
            Pong.sh("tmux has-session -t \(s) 2>/dev/null && tmux kill-session -t \(s) || true")
        }

        Pong.sh("tmux new-session -d -s \(name) -n Hermes")
        Pong.sh("tmux send-keys -t \(name):0 -l '\(pathExport); printf \"\\n  HERMES · \(name):0\\n\\n\"; hermes'")
        usleep(80_000)
        Pong.sh("tmux send-keys -t \(name):0 Enter")

        var workerRecords: [[String: Any]] = []
        for (idx, worker) in list.enumerated() {
            let wCmd = worker.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            let launchCmd = wCmd.isEmpty ? "claude" : wCmd
            let winName = list.count == 1 ? "Worker" : "W\(idx + 1)"
            Pong.sh("tmux new-window -t \(name) -n \(winName)")
            let safeCmd = launchCmd.replacingOccurrences(of: "'", with: "'\\''")
            let banner = "WORKER · \(worker.label) · \(name):\(idx + 1)"
            Pong.sh("tmux send-keys -t \(name):\(idx + 1) -l '\(pathExport); printf \"\\n  \(banner)\\n\\n\"; \(safeCmd)'")
            usleep(80_000)
            Pong.sh("tmux send-keys -t \(name):\(idx + 1) Enter")
            workerRecords.append([
                "id": "w\(idx + 1)",
                "type": worker.id,
                "label": worker.label,
                "cmd": launchCmd,
                "mode": "tmux",
                "tmux_index": idx + 1,
                "done_marker": worker.id == "claude" ? "##CLAUDE_DONE##" : "##WORKER_DONE##",
            ])
        }

        Pong.sh("tmux new-session -d -s \(viewH) -t \(name)")
        Pong.sh("tmux select-window -t \(viewH):0")
        var viewNames: [String] = []
        for idx in 0..<list.count {
            let vn = "\(name)-w\(idx)"
            viewNames.append(vn)
            Pong.sh("tmux new-session -d -s \(vn) -t \(name)")
            Pong.sh("tmux select-window -t \(vn):\(idx + 1)")
        }
        if !viewNames.isEmpty {
            Pong.sh("tmux has-session -t \(name)-c 2>/dev/null || tmux new-session -d -s \(name)-c -t \(name)")
            Pong.sh("tmux select-window -t \(name)-c:1")
        }

        // Open Terminals one-by-one.
        // Never bare `activate` first — that spawns a blank extra window.
        // Capture ids via before/after diff so workers never share one window id.
        func openAttach(_ session: String, used: inout Set<String>) -> String? {
            let before = Set(TerminalTheme.listWindows().map(\.id))
            let script = """
            tell application "Terminal"
              do script "\(pathExport); exec tmux attach-session -t \(session)"
              delay 0.75
            end tell
            """
            _ = Pong.osascript(script)
            usleep(250_000)
            let after = TerminalTheme.listWindows()
            let fresh = after.filter { !before.contains($0.id) && !used.contains($0.id) }
            if let best = fresh.last {
                used.insert(best.id)
                Pong.log("openAttach \(session) → \(best.id) (new) \(best.title)")
                return best.id
            }
            if let hit = after.first(where: { !used.contains($0.id) && $0.title.contains(session) }) {
                used.insert(hit.id)
                Pong.log("openAttach \(session) → \(hit.id) (title)")
                return hit.id
            }
            Pong.log("openAttach \(session) → FAILED")
            return nil
        }

        let baselineWindows = Set(TerminalTheme.listWindows().map(\.id))
        var usedWindowIds = Set<String>()
        let hid = openAttach(viewH, used: &usedWindowIds)
        var windowIds: [String] = []
        for vn in viewNames {
            windowIds.append(openAttach(vn, used: &usedWindowIds) ?? "")
        }
        // Close accidental blank windows created during launch
        let afterAll = TerminalTheme.listWindows()
        for w in afterAll where !baselineWindows.contains(w.id) && !usedWindowIds.contains(w.id) {
            let t = w.title.lowercased()
            if t.contains("tmux") || t.contains("hermes") || t.contains("worker")
                || t.contains("claude") || t.contains("grok") || t.contains("kimi") {
                continue
            }
            _ = Pong.osascript("""
            tell application "Terminal"
              try
                close window id \(w.id)
              end try
            end tell
            """)
            Pong.log("closed stray Terminal window \(w.id) title=\(w.title)")
        }
        while windowIds.count < workerRecords.count { windowIds.append("") }
        // Stack Terminal windows vertically (Hermes on top, workers below)
        tileWindowsVertically(hermesId: hid, workerIds: windowIds.filter { !$0.isEmpty })
        for i in 0..<workerRecords.count {
            if i < windowIds.count, Int(windowIds[i]) != nil {
                workerRecords[i]["window_id"] = windowIds[i]
            } else {
                workerRecords[i]["window_id"] = NSNull()
            }
        }
        let primaryWid = windowIds.first(where: { Int($0) != nil })
        let teamLabel = list.count == 1 ? list[0].label : "\(list.count) workers"

        PairState.savePairState(
            name,
            hermesWindowId: hid,
            claudeWindowId: primaryWid,
            claudeMode: "tmux",
            workerType: list[0].id,
            workerLabel: teamLabel,
            workerCmd: list[0].cmd.isEmpty ? "claude" : list[0].cmd,
            workers: workerRecords
        )
        var active = Pong.loadJSON(PairState.activePath)
        active["session"] = name
        active["view_hermes"] = viewH
        active["view_claude"] = viewNames.first ?? "\(name)-c"
        active["view_workers"] = viewNames
        active["workers"] = workerRecords
        active["hermes_window_id"] = hid ?? NSNull() as Any
        active["claude_window_id"] = primaryWid ?? NSNull() as Any
        active["claude_mode"] = "tmux"
        active["worker_type"] = list[0].id
        active["worker_label"] = teamLabel
        active["updated"] = Date().timeIntervalSince1970
        Pong.writeJSON(PairState.activePath, active)
        var db = PairState.loadPairsDb()
        var entry = db[name] as? [String: Any] ?? [:]
        entry["view_hermes"] = viewH
        entry["view_claude"] = viewNames.first ?? "\(name)-c"
        entry["view_workers"] = viewNames
        entry["workers"] = workerRecords
        entry["hermes_window_id"] = hid ?? NSNull() as Any
        entry["claude_window_id"] = primaryWid ?? NSNull() as Any
        entry["updated"] = Date().timeIntervalSince1970
        db[name] = entry
        Pong.writeJSON(PairState.pairsPath, db)

        if let h = hid {
            flashPairWindows(h, primaryWid)
        } else {
            Pong.osascript("tell application \"Terminal\" to activate")
            Pong.log("start_fresh WARNING: no hermes window id — check Automation permission for Terminal")
        }
        let labels = list.map { $0.label }.joined(separator: ", ")
        Pong.log("start_fresh \(name) workers=[\(labels)] hermes=\(hid ?? "-") primaryWorker=\(primaryWid ?? "-")")
        TerminalTheme.applyPair(name)
        Tips.afterSuccessfulPair()
        return name
    }

    /// Link existing windows (single worker). Never dumps into live TUIs.
    static func wirePair(_ name: String, _ w1: String, _ w2: String) {
        wireArmy(name, hermesId: w1, workerWindowIds: [w2])
    }

    /// Link Hermes + N worker Terminal windows (Phase 2 army).
    static func wireArmy(_ name: String, hermesId: String, workerWindowIds: [String]) {
        var ids = workerWindowIds.filter { !$0.isEmpty && $0 != hermesId }
        // de-dupe preserve order
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else {
            Pong.log("wireArmy: no workers")
            return
        }
        Pong.sh("tmux has-session -t \(name) 2>/dev/null || tmux new-session -d -s \(name) -n Hermes")

        let hermesTui = looksLikeTui(hermesId)
        if !hermesTui {
            runInTerminalWindow(hermesId, "printf '\\n  HERMES · \(name):0\\n\\n'; tmux attach-session -t \(name):0")
            usleep(250_000)
        } else {
            Pong.log("Hermes window \(hermesId) live TUI — register only")
        }

        var workers: [[String: Any]] = []
        var anyWindowMode = false
        for (idx, wid) in ids.enumerated() {
            let tui = looksLikeTui(wid)
            let mode = tui ? "window" : "tmux"
            if tui { anyWindowMode = true }
            let label: String = {
                for (i, title) in listTerminalWindows() where i == wid {
                    let t = title
                    if t.count > 36 { return String(t.prefix(33)) + "…" }
                    return t.isEmpty ? "Worker \(idx + 1)" : t
                }
                return "Worker \(idx + 1)"
            }()
            // Infer type from title
            let low = label.lowercased()
            let type: String
            if low.contains("claude") || low.contains("✳") || low.contains("fable") { type = "claude" }
            else if low.contains("kimi") { type = "kimi" }
            else if low.contains("grok") { type = "grok" }
            else if low.contains("codex") { type = "codex" }
            else if low.contains("opencode") { type = "opencode" }
            else { type = "linked" }
            workers.append(Workers.makeWorker(
                id: "w\(idx + 1)",
                type: type,
                label: label,
                windowId: wid,
                mode: mode,
                cmd: type == "linked" ? "" : (WorkerType.named(type).cmd),
                tmuxIndex: idx + 1
            ))
            if !tui {
                // soft attach only if bare shell
                runInTerminalWindow(wid, "printf '\\n  WORKER · \(name) w\(idx + 1)\\n\\n'; true")
            }
        }

        let primary = ids[0]
        let primaryMode = (workers.first?["mode"] as? String) ?? "window"
        PairState.savePairState(
            name,
            hermesWindowId: hermesId,
            claudeWindowId: primary,
            claudeMode: primaryMode,
            workerType: (workers.first?["type"] as? String) ?? "linked",
            workerLabel: workers.count == 1
                ? ((workers.first?["label"] as? String) ?? "Worker")
                : "\(workers.count) workers",
            workerCmd: (workers.first?["cmd"] as? String) ?? "",
            workers: workers
        )
        if anyWindowMode { startWindowRelay() }
        Pong.log("wireArmy \(name) hermes=\(hermesId) workers=\(ids.count) \(ids)")
        Tips.afterSuccessfulPair()
    }

    static func killPair(_ name: String) {
        var sessions = [name, "\(name)-h", "\(name)-c"]
        for i in 0..<12 { sessions.append("\(name)-w\(i)") }
        for s in sessions {
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

// MARK: - Usage + tip milestones (~/.hermes-pong/usage.json)

enum Tips {
    static let tip20URL = "https://donate.stripe.com/fZufZhbl58V2cQX9xZ1B60a"
    static let milestones = [3, 10, 30]
    static var usagePath: String { Pong.stateDir + "/usage.json" }

    static func loadUsage() -> [String: Any] {
        var u = Pong.loadJSON(usagePath)
        if u["pair_count"] == nil { u["pair_count"] = 0 }
        if u["tip_never_ask"] == nil { u["tip_never_ask"] = false }
        if u["supporter"] == nil { u["supporter"] = false }
        if u["paid_cents"] == nil { u["paid_cents"] = 0 }
        if u["tip_milestones_shown"] == nil { u["tip_milestones_shown"] = [Int]() }
        return u
    }

    static func saveUsage(_ u: [String: Any]) {
        Pong.writeJSON(usagePath, u)
    }

    static func openTip20() {
        if let url = URL(string: tip20URL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Bump pair_count after a successful New pair / Link. Returns new count.
    @discardableResult
    static func recordSuccessfulPair() -> Int {
        var u = loadUsage()
        let n = (u["pair_count"] as? Int) ?? Int("\(u["pair_count"] ?? 0)") ?? 0
        let next = n + 1
        u["pair_count"] = next
        u["last_pair_at"] = Date().timeIntervalSince1970
        saveUsage(u)
        Pong.log("pair_count=\(next)")
        return next
    }

    static func isSupporter(_ u: [String: Any]) -> Bool {
        if (u["supporter"] as? Bool) == true { return true }
        let paid = (u["paid_cents"] as? Int) ?? Int("\(u["paid_cents"] ?? 0)") ?? 0
        return paid >= 50
    }

    static func shownMilestones(_ u: [String: Any]) -> Set<Int> {
        if let arr = u["tip_milestones_shown"] as? [Int] { return Set(arr) }
        if let arr = u["tip_milestones_shown"] as? [NSNumber] {
            return Set(arr.map { $0.intValue })
        }
        return []
    }

    /// Call on main thread after a successful pair.
    static func maybeShowTipMilestone(pairCount: Int? = nil) {
        var u = loadUsage()
        if (u["tip_never_ask"] as? Bool) == true { return }
        if isSupporter(u) { return }
        let count = pairCount ?? ((u["pair_count"] as? Int) ?? 0)
        guard milestones.contains(count) else { return }
        var shown = shownMilestones(u)
        if shown.contains(count) { return }

        shown.insert(count)
        u["tip_milestones_shown"] = Array(shown).sorted()
        saveUsage(u)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enjoying Hermes Pong?"
        alert.informativeText =
            "You've linked \(count) pairs — nice.\n\n" +
            "The app is free forever. If it's useful, a small tip helps keep shipping.\n\n" +
            "Already tipped? Choose “I already tipped.”"
        alert.addButton(withTitle: "Tip $20")
        alert.addButton(withTitle: "I already tipped")
        alert.addButton(withTitle: "Maybe later")
        alert.addButton(withTitle: "Don't ask again")
        let resp = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        switch resp {
        case first:
            openTip20()
            Pong.log("tip milestone \(count) → stripe $20")
        case NSApplication.ModalResponse(rawValue: first.rawValue + 1):
            u = loadUsage()
            u["supporter"] = true
            u["paid_cents"] = max((u["paid_cents"] as? Int) ?? 0, 200)
            u["tip_never_ask"] = true
            saveUsage(u)
            Pong.log("tip milestone \(count) → already tipped")
        case NSApplication.ModalResponse(rawValue: first.rawValue + 3):
            u = loadUsage()
            u["tip_never_ask"] = true
            saveUsage(u)
            Pong.log("tip milestone \(count) → never ask")
        default:
            Pong.log("tip milestone \(count) → later")
        }
    }

    /// Record pair + schedule milestone prompt on main.
    static func afterSuccessfulPair() {
        let n = recordSuccessfulPair()
        DispatchQueue.main.async {
            maybeShowTipMilestone(pairCount: n)
        }
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
        open.keyEquivalentModifierMask = [.command]
        open.target = self
        appMenu.addItem(open)

        let tip = NSMenuItem(title: "Tip developer…", action: #selector(tipDeveloper), keyEquivalent: "")
        tip.target = self
        appMenu.addItem(tip)
        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Hermes Pong", action: #selector(quitAll), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        appMenu.addItem(quit)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        timer = nil
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app: closing the panel must not quit.
        return false
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Hermes Pong"
        alert.informativeText = "Hermes orchestrates any AI terminal workers.\nClaude default · multi-model ready.\nkulpio/Hermes-Pong"
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
            "Needed so paste + Enter lands reliably in the worker terminal window.",
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
            let db = PairState.loadPairsDb()
            for s in sessions {
                let entry = db[s] as? [String: Any] ?? [:]
                let ws = Workers.list(from: entry)
                let title: String = {
                    if ws.isEmpty { return "● \(s)" }
                    if ws.count == 1 {
                        let lab = (ws[0]["label"] as? String) ?? "worker"
                        return "● \(s)  →  \(lab)"
                    }
                    let labs = ws.map { ($0["id"] as? String) ?? "?" }.joined(separator: "+")
                    return "● \(s)  →  team [\(labs)]"
                }()
                let sub = NSMenu()
                let rejoin = NSMenuItem(title: "Bring to front", action: #selector(rejoinNamed(_:)), keyEquivalent: "")
                rejoin.target = self
                rejoin.representedObject = s
                sub.addItem(rejoin)
                if !ws.isEmpty {
                    sub.addItem(NSMenuItem.separator())
                    let head = NSMenuItem(title: "Workers (same Hermes)", action: nil, keyEquivalent: "")
                    head.isEnabled = false
                    sub.addItem(head)
                    for w in ws {
                        let id = (w["id"] as? String) ?? "?"
                        let lab = (w["label"] as? String) ?? "?"
                        let line = NSMenuItem(title: "  \(id)  \(lab)", action: nil, keyEquivalent: "")
                        line.isEnabled = false
                        sub.addItem(line)
                    }
                    sub.addItem(NSMenuItem.separator())
                }
                let kill = NSMenuItem(title: "Kill pair", action: #selector(killNamed(_:)), keyEquivalent: "")
                kill.target = self
                kill.representedObject = s
                sub.addItem(kill)
                let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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
        menu.addItem(item("Tip developer…", #selector(tipDeveloper)))
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
        guard let workers = Self.pickWorkerTypes() else { return }
        if workers.isEmpty {
            // Saved team already spawned inside picker
            lastSessionPoll = .distantPast
            rebuildMenu()
            PanelController.shared.refreshUI()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Pairing.startFresh(workers: workers)
            DispatchQueue.main.async { [weak self] in
                self?.lastSessionPoll = .distantPast
                self?.rebuildMenu()
                PanelController.shared.refreshUI()
            }
        }
    }

    /// New pair worker selection.
    /// Always one Hermes session. Single worker or army under that Hermes — never separate pair rows.
        /// Returns workers to launch, OR nil if cancelled.
    /// New pair: Claude · Other Model · Team · Cancel
    static func pickWorkerTypes() -> [WorkerType]? {
        NSApp.activate(ignoringOtherApps: true)
        let gate = NSAlert()
        gate.messageText = "New pair"
        gate.informativeText = "Always one Hermes. Pick how to staff it."
        gate.addButton(withTitle: "Claude")
        gate.addButton(withTitle: "Other Model")
        gate.addButton(withTitle: "Team")
        gate.addButton(withTitle: "Cancel")
        let g = gate.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        if g == first {
            return [WorkerType.resolved("claude")]
        }
        if g == NSApplication.ModalResponse(rawValue: first.rawValue + 1) {
            return TeamBuilderPanel.run(mode: .oneModel)
        }
        if g == NSApplication.ModalResponse(rawValue: first.rawValue + 2) {
            return TeamBuilderPanel.run(mode: .team)
        }
        return nil
    }

    static func pickWorkerType() -> WorkerType? {
        pickWorkerTypes()?.first
    }

    static func pickCustomWorker() -> WorkerType? {
        let a2 = NSAlert()
        a2.messageText = "Custom worker command"
        a2.informativeText = "Shell command (e.g. kimi, grok, opencode)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "kimi"
        a2.accessoryView = field
        a2.addButton(withTitle: "Use")
        a2.addButton(withTitle: "Cancel")
        a2.window.initialFirstResponder = field
        guard a2.runModal() == .alertFirstButtonReturn else { return nil }
        let cmd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty { return nil }
        return WorkerType(id: "custom", label: cmd, cmd: cmd, tmuxWindowName: "Worker")
    }

    @discardableResult
    static func pickAndSpawnSavedTeam() -> Bool {
        let teams = SavedTeams.loadAll()
        if teams.isEmpty {
            let a = NSAlert()
            a.messageText = "No saved teams"
            a.informativeText = "Open an Active pair → Save Team on the Hermes row."
            a.addButton(withTitle: "OK")
            a.runModal()
            return false
        }
        // Vertical list via TeamBuilder-style alert isn't needed — use NSAlert with one button per line (vertical stack on macOS)
        let alert = NSAlert()
        alert.messageText = "Saved teams"
        alert.informativeText = "Each launches Hermes + workers (names, colors, perms)."
        for t in teams {
            alert.addButton(withTitle: "\(t.name)  ·  \(t.workers.count) workers")
        }
        alert.addButton(withTitle: "Cancel")
        let resp = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = resp.rawValue - first
        guard idx >= 0 && idx < teams.count else { return false }
        _ = SavedTeams.spawn(teams[idx])
        return true
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

    @objc func tipDeveloper() {
        Tips.openTip20()
        Pong.log("tip developer menu → stripe $20")
    }

    @objc func quitAll() {
        timer?.invalidate()
        timer = nil
        // Clean up any panel process left over from pre-1.3 installs (non-blocking).
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "hermes_pairing.py"]
            try? p.run()
        }
        // Ensure terminate actually ends the process (Cmd+Q + menu Quit).
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exit(0)
        }
    }
}

// MARK: - Control panel window (Swift port of hermes_pairing.py)

final class PanelController: NSObject {
    static let shared = PanelController()

    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private var listContainer: NSView!
    private let guide = LinkGuideController()

    private let W: CGFloat = 460, H: CGFloat = 780, PAD: CGFloat = 28

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
        content.addSubview(Self.label("Claude · Other Model · Team (vertical). Saved teams live under Team.",
            frame: NSRect(x: PAD + 2, y: y, width: W - 2 * PAD - 4, height: 32), size: 12, secondary: true))
        y -= 48
        content.addSubview(button("Link existing terminals", #selector(linkPressed(_:)),
            NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 38)))
        y -= 48
        content.addSubview(Self.label(
            "Pick Hermes, then one or more worker terminals. Add workers, then Done. Nothing injected into worker TUIs.",
            frame: NSRect(x: PAD + 2, y: y, width: W - 2 * PAD - 4, height: 44), size: 12, secondary: true))

        y -= 40
        content.addSubview(Self.label("ACTIVE PAIRS",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 16), size: 11, secondary: true))
        y -= 16
        content.addSubview(Self.label("Hermes verifies every CLAIM and loops until accept or escalate.",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 13), size: 9, secondary: true))
        y -= 14
        content.addSubview(Self.label("Hub = Hermes (Save Team). Workers = Front / Kill / Perms + colors.",
            frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 13), size: 9, secondary: true))

        y -= 280
        listContainer = NSView(frame: NSRect(x: PAD, y: y, width: W - 2 * PAD, height: 260))
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
        let boxW = listContainer.bounds.width > 0 ? listContainer.bounds.width : (W - 2 * PAD)
        if pairs.isEmpty {
            listContainer.addSubview(Self.label("No pairs yet — use New pair.",
                frame: NSRect(x: 0, y: 150, width: boxW, height: 20), size: 12, secondary: true))
            return
        }

        let top: CGFloat = listContainer.bounds.height > 0 ? listContainer.bounds.height - 4 : 200
        var y = top
        let db = PairState.loadPairsDb()

        for name in pairs {
            let entry = db[name] as? [String: Any] ?? [:]
            var ws = Workers.list(from: entry)
            if ws.isEmpty {
                ws = [[
                    "id": "w1",
                    "label": (entry["worker_label"] as? String) ?? "Worker",
                    "type": (entry["worker_type"] as? String) ?? "linked",
                ]]
            }
            let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hermesTitle = display.isEmpty ? name : display
            let hCols = TerminalTheme.Colors.from(entry["colors"]) ?? .hermesDefault
            let hNS = hCols.asNSColors

            // —— Hermes hub ——
            let hermesH: CGFloat = 36
            y -= hermesH
            let hermesRow = NSView(frame: NSRect(x: 0, y: y, width: boxW, height: hermesH))
            hermesRow.wantsLayer = true
            hermesRow.layer?.backgroundColor =
                NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor
            hermesRow.layer?.cornerRadius = 8

            // Color swatch (click → colors)
            hermesRow.addSubview(swatchButton(
                color: hNS.hi,
                frame: NSRect(x: 8, y: 10, width: 14, height: 14),
                id: name,
                action: #selector(hermesColorPressed(_:))
            ))

            // Name (click → rename)
            hermesRow.addSubview(nameButton(
                "Hermes · \(hermesTitle)",
                frame: NSRect(x: 28, y: 6, width: 140, height: 24),
                id: name,
                action: #selector(hermesNamePressed(_:))
            ))
            hermesRow.addSubview(button("Front", #selector(frontPressed(_:)),
                NSRect(x: 172, y: 5, width: 46, height: 26), id: name))
            hermesRow.addSubview(button("Kill", #selector(killPressed(_:)),
                NSRect(x: 220, y: 5, width: 42, height: 26), id: name))
            // No Hermes Perms — only workers have access bans. Save Team instead.
            hermesRow.addSubview(button("Save Team", #selector(saveTeamPressed(_:)),
                NSRect(x: 264, y: 5, width: 90, height: 26), id: name))
            // Apply titles/colors when list refreshes (cheap)
            TerminalTheme.applyPair(name)
            listContainer.addSubview(hermesRow)

            for (i, w) in ws.enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let lab = (w["label"] as? String) ?? "worker"
                let isLast = i == ws.count - 1
                let branch = isLast ? "`->" : "|->"
                let rowH: CGFloat = 34
                y -= rowH
                let row = NSView(frame: NSRect(x: 0, y: y, width: boxW, height: rowH))
                let rail = NSView(frame: NSRect(x: 13, y: isLast ? rowH / 2 : 0, width: 2, height: isLast ? rowH / 2 : rowH))
                rail.wantsLayer = true
                rail.layer?.backgroundColor =
                    NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.42, alpha: 1).cgColor
                row.addSubview(rail)
                let stub = NSView(frame: NSRect(x: 13, y: rowH / 2 - 1, width: 12, height: 2))
                stub.wantsLayer = true
                stub.layer?.backgroundColor =
                    NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.42, alpha: 1).cgColor
                row.addSubview(stub)

                let wCols = TerminalTheme.Colors.from(w["colors"]) ?? .workerDefault
                let wNS = wCols.asNSColors
                let tag = "\(name)|\(wid)"
                row.addSubview(swatchButton(
                    color: wNS.hi,
                    frame: NSRect(x: 28, y: 10, width: 12, height: 12),
                    id: tag,
                    action: #selector(workerColorPressed(_:))
                ))
                row.addSubview(nameButton(
                    "\(branch) \(lab)",
                    frame: NSRect(x: 44, y: 5, width: 124, height: 24),
                    id: tag,
                    action: #selector(workerNamePressed(_:))
                ))
                row.addSubview(button("Front", #selector(frontWorkerPressed(_:)),
                    NSRect(x: 172, y: 5, width: 46, height: 24), id: tag))
                row.addSubview(button("Kill", #selector(killWorkerPressed(_:)),
                    NSRect(x: 220, y: 5, width: 42, height: 24), id: tag))
                let wperms = Workers.permissions(pair: name, workerId: wid)
                let won = ["ban_mcp", "ban_root", "ban_network", "ban_system_paths", "repo_only"]
                    .filter { (wperms[$0] as? Bool) == true }.count
                let wnote = !((wperms["custom_prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let wtitle = (won > 0 || wnote) ? "Perms·\(won + (wnote ? 1 : 0))" : "Perms"
                row.addSubview(button(wtitle, #selector(permsWorkerPressed(_:)),
                    NSRect(x: 264, y: 5, width: 72, height: 24), id: tag))
                listContainer.addSubview(row)
            }
            y -= 10
        }
    }

    private func nameButton(_ title: String, frame: NSRect, id: String, action: Selector) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .inline
        b.isBordered = false
        b.alignment = .left
        b.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        b.contentTintColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        b.target = self
        b.action = action
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.toolTip = "Click to rename"
        return b
    }

    private func swatchButton(color: NSColor, frame: NSRect, id: String, action: Selector) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = ""
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = frame.height / 2
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
        b.target = self
        b.action = action
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.toolTip = "Colors: background, text, highlight"
        return b
    }

    // MARK: Actions

    @objc private func newPairPressed(_ sender: NSButton) {
        guard let workers = AppDelegate.pickWorkerTypes() else { return }
        if workers.isEmpty {
            // Saved team already spawned
            refreshUI()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let name = Pairing.startFresh(workers: workers)
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
        // pair-level (Hermes row)
        PermissionsSheetController.shared.show(for: name, workerId: nil) { [weak self] in
            self?.refreshUI()
        }
    }

    @objc private func frontWorkerPressed(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Workers.frontWorker(pair: parts[0], workerId: parts[1])
    }

    @objc private func killWorkerPressed(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(parts[1]) from team?"
        alert.informativeText = "Kills that worker terminal/view. Hermes stays if other workers remain."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = Workers.removeWorker(pair: parts[0], workerId: parts[1])
        refreshUI()
    }

    @objc private func permsWorkerPressed(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        PermissionsSheetController.shared.show(for: parts[0], workerId: parts[1]) { [weak self] in
            self?.refreshUI()
        }
    }

    @objc private func saveTeamPressed(_ sender: NSButton) {
        guard let pair = sender.identifier?.rawValue else { return }
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let suggestion = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = (suggestion?.isEmpty == false) ? suggestion! : pair
        promptName(title: "Save team as…", value: seed) { name in
            if SavedTeams.saveFromLivePair(pair, teamName: name) != nil {
                let a = NSAlert()
                a.messageText = "Team saved"
                a.informativeText =
                    "“\(name)” is under New pair → Saved team…\n" +
                    "Includes workers, names, colors, and per-worker perms."
                a.addButton(withTitle: "OK")
                a.runModal()
            } else {
                let a = NSAlert()
                a.messageText = "Nothing to save"
                a.informativeText = "This pair has no workers yet."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
            self.refreshUI()
        }
    }

    @objc private func hermesNamePressed(_ sender: NSButton) {
        guard let pair = sender.identifier?.rawValue else { return }
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let current = (entry["display_name"] as? String) ?? pair
        promptName(title: "Name this pair", value: current) { name in
            Workers.setPairDisplayName(pair, name)
            self.refreshUI()
        }
    }

    @objc private func workerNamePressed(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let entry = PairState.loadPairsDb()[parts[0]] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        let cur = (ws.first(where: { ($0["id"] as? String) == parts[1] })?["label"] as? String) ?? parts[1]
        promptName(title: "Name worker \(parts[1])", value: cur) { name in
            Workers.setWorkerLabel(pair: parts[0], workerId: parts[1], label: name)
            self.refreshUI()
        }
    }

    @objc private func hermesColorPressed(_ sender: NSButton) {
        guard let pair = sender.identifier?.rawValue else { return }
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let cols = TerminalTheme.Colors.from(entry["colors"]) ?? .hermesDefault
        ColorThemeSheet.shared.show(title: "Hermes colors · \(pair)", colors: cols) { [weak self] c in
            Workers.setPairColors(pair, colors: c)
            self?.refreshUI()
        }
    }

    @objc private func workerColorPressed(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let entry = PairState.loadPairsDb()[parts[0]] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        let w = ws.first(where: { ($0["id"] as? String) == parts[1] }) ?? [:]
        let cols = TerminalTheme.Colors.from(w["colors"]) ?? .workerDefault
        ColorThemeSheet.shared.show(title: "Colors · \(parts[1])", colors: cols) { [weak self] c in
            Workers.setWorkerColors(pair: parts[0], workerId: parts[1], colors: c)
            self?.refreshUI()
        }
    }

    private func promptName(title: String, value: String, onOK: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Shows in the panel and at the top of that Terminal window."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onOK(name) }
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
            "Link existing = keeps your worker’s model, resume, and chat.\n" +
            "New pair = Hermes + a worker CLI you choose (starts clean).\n\n" +
            "When Hermes delegates, the task pastes into the worker window."
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Don't remind me")
        if alert.runModal() == .alertSecondButtonReturn {
            try? "1\n".write(toFile: flag, atomically: true, encoding: .utf8)
            Pong.log("dont-remind-pair-persist set")
        }
    }
}

// MARK: - Saved permission presets (~/.hermes-pong/permission-presets.json)

/// Built-in + user-saved permission packs. Builtins are always available; user
/// packs are named snapshots of the checkbox/note set.
enum PermissionPresets {
    static var path: String { Pong.stateDir + "/permission-presets.json" }

    struct Item {
        let id: String
        let name: String
        let builtin: Bool
        let permissions: [String: Any]
    }

    static func builtins() -> [Item] {
        [
            Item(id: "full", name: "Full access", builtin: true,
                 permissions: PairState.fullAccessPermissions()),
            Item(id: "ask_each", name: "Ask each time", builtin: true,
                 permissions: PairState.askEachPermissions()),
        ]
    }

    static func loadUser() -> [Item] {
        let raw = Pong.loadJSON(path)
        let arr = (raw["presets"] as? [[String: Any]]) ?? []
        var out: [Item] = []
        for row in arr {
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String,
                  let perms = row["permissions"] as? [String: Any] else { continue }
            // Never shadow builtins
            if id == "full" || id == "ask_each" { continue }
            out.append(Item(id: id, name: name, builtin: false, permissions: perms))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func all() -> [Item] { builtins() + loadUser() }

    static func saveUser(name: String, permissions: [String: Any]) -> Item {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "My preset" }
        var list = loadUser()
        let id: String
        if let existing = list.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            id = existing.id
            list.removeAll { $0.id == id }
        } else {
            id = "user-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        }
        let item = Item(id: id, name: trimmed, builtin: false, permissions: permissions)
        list.append(item)
        writeUser(list)
        Pong.log("permission preset saved id=\(id) name=\(trimmed)")
        return item
    }

    static func deleteUser(id: String) {
        if id == "full" || id == "ask_each" { return }
        let list = loadUser().filter { $0.id != id }
        writeUser(list)
        Pong.log("permission preset deleted id=\(id)")
    }

    private static func writeUser(_ list: [Item]) {
        let arr: [[String: Any]] = list.map {
            ["id": $0.id, "name": $0.name, "permissions": $0.permissions]
        }
        Pong.writeJSON(path, ["presets": arr, "updated": Date().timeIntervalSince1970])
    }
}

// MARK: - Per-pair access permissions sheet



// MARK: - Team / model picker (vertical panel)

/// Vertical list UI for Other Model + Team (not horizontal NSAlert button rows).
final class TeamBuilderPanel: NSObject {
    enum Mode { case oneModel, team }

    private var window: NSWindow?
    private var selected: [WorkerType] = []
    private var rosterLabel: NSTextField!
    private var mode: Mode = .team
    private var result: [WorkerType]?
    private var finished = false

    /// Modal: returns workers, empty array if saved team spawned, nil if cancelled.
    static func run(mode: Mode) -> [WorkerType]? {
        let p = TeamBuilderPanel()
        return p.runModal(mode: mode)
    }

    private func runModal(mode: Mode) -> [WorkerType]? {
        self.mode = mode
        self.selected = []
        self.result = nil
        self.finished = false
        build()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Run a nested loop until Done/Cancel
        let session = NSApp.beginModalSession(for: window!)
        while !finished {
            if NSApp.runModalSession(session) != .continue {
                break
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        NSApp.endModalSession(session)
        window?.orderOut(nil)
        return result
    }

    private func build() {
        let W: CGFloat = 360
        let H: CGFloat = mode == .oneModel ? 420 : 520
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = mode == .oneModel ? "Other Model" : "Team"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        var y = H - 28

        let title = NSTextField(labelWithString: mode == .oneModel
            ? "Pick one worker under Hermes"
            : "Build a team (vertical list)")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 20, y: y - 20, width: W - 40, height: 22)
        content.addSubview(title)
        y -= 36

        let sub = NSTextField(wrappingLabelWithString: mode == .oneModel
            ? "One model + Hermes. Same Active pair row."
            : "Add models top → bottom. One Hermes orchestrates all.")
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        sub.frame = NSRect(x: 20, y: y - 32, width: W - 40, height: 34)
        content.addSubview(sub)
        y -= 44

        // —— Models (vertical) ——
        let models = WorkerType.all.filter { $0.id != "custom" }
        for w in models {
            y -= 36
            let btn = NSButton(frame: NSRect(x: 20, y: y, width: W - 40, height: 32))
            btn.title = mode == .oneModel ? w.label : "+  \(w.label)"
            btn.bezelStyle = .rounded
            btn.setButtonType(.momentaryPushIn)
            btn.target = self
            btn.action = #selector(addModel(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(w.id)
            content.addSubview(btn)
        }
        y -= 36
        let custom = NSButton(frame: NSRect(x: 20, y: y, width: W - 40, height: 32))
        custom.title = mode == .oneModel ? "Custom…" : "+  Custom…"
        custom.bezelStyle = .rounded
        custom.target = self
        custom.action = #selector(addCustom)
        content.addSubview(custom)

        if mode == .team {
            y -= 16
            // Saved teams section
            let saved = SavedTeams.loadAll()
            if !saved.isEmpty {
                y -= 20
                let sh = NSTextField(labelWithString: "SAVED TEAMS")
                sh.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                sh.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
                sh.frame = NSRect(x: 20, y: y, width: W - 40, height: 14)
                content.addSubview(sh)
                for t in saved.prefix(6) {
                    y -= 34
                    let b = NSButton(frame: NSRect(x: 20, y: y, width: W - 40, height: 30))
                    b.title = "Spawn  \(t.name)  (\(t.workers.count))"
                    b.bezelStyle = .rounded
                    b.target = self
                    b.action = #selector(spawnSaved(_:))
                    b.identifier = NSUserInterfaceItemIdentifier(t.id)
                    content.addSubview(b)
                }
            }

            y -= 16
            rosterLabel = NSTextField(wrappingLabelWithString: "Team: (empty)")
            rosterLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            rosterLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            rosterLabel.frame = NSRect(x: 20, y: max(y - 70, 56), width: W - 40, height: 70)
            content.addSubview(rosterLabel)
            refreshRoster()

            let launch = NSButton(frame: NSRect(x: 20, y: 16, width: (W - 48) / 2, height: 34))
            launch.title = "Launch team"
            launch.bezelStyle = .rounded
            launch.target = self
            launch.action = #selector(launchTeam)
            content.addSubview(launch)
            let cancel = NSButton(frame: NSRect(x: 28 + (W - 48) / 2, y: 16, width: (W - 48) / 2, height: 34))
            cancel.title = "Cancel"
            cancel.bezelStyle = .rounded
            cancel.target = self
            cancel.action = #selector(cancelPressed)
            content.addSubview(cancel)
        } else {
            let cancel = NSButton(frame: NSRect(x: 20, y: 16, width: W - 40, height: 34))
            cancel.title = "Cancel"
            cancel.bezelStyle = .rounded
            cancel.target = self
            cancel.action = #selector(cancelPressed)
            content.addSubview(cancel)
        }

        win.contentView = content
        win.delegate = self
        window = win
    }

    private func refreshRoster() {
        guard mode == .team else { return }
        if selected.isEmpty {
            rosterLabel?.stringValue = "Team: (empty)\nAdd models above — order is top → bottom."
            return
        }
        let lines = selected.enumerated().map { i, w in
            "  w\(i + 1)  \(w.label)"
        }
        rosterLabel?.stringValue = "Team (\(selected.count)):\n" + lines.joined(separator: "\n")
    }

    @objc private func addModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let w = WorkerType.resolved(id)
        if mode == .oneModel {
            result = [w]
            finished = true
            NSApp.stopModal()
            return
        }
        selected.append(w)
        refreshRoster()
    }

    @objc private func addCustom() {
        guard let w = AppDelegate.pickCustomWorker() else { return }
        if mode == .oneModel {
            result = [w]
            finished = true
            NSApp.stopModal()
            return
        }
        selected.append(w)
        refreshRoster()
    }

    @objc private func spawnSaved(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let team = SavedTeams.loadAll().first(where: { $0.id == id }) else { return }
        _ = SavedTeams.spawn(team)
        result = []  // signal: already spawned
        finished = true
        NSApp.stopModal()
    }

    @objc private func launchTeam() {
        guard !selected.isEmpty else {
            let a = NSAlert()
            a.messageText = "Add at least one model"
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        result = selected
        finished = true
        NSApp.stopModal()
    }

    @objc private func cancelPressed() {
        result = nil
        finished = true
        NSApp.stopModal()
    }
}

extension TeamBuilderPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if !finished {
            result = nil
            finished = true
            NSApp.stopModal()
        }
    }
}


// MARK: - Color theme sheet (bg / text / highlight)

final class ColorThemeSheet: NSObject {
    static let shared = ColorThemeSheet()
    private var window: NSWindow?
    private var bgWell: NSColorWell!
    private var textWell: NSColorWell!
    private var hiWell: NSColorWell!
    private var onSave: ((TerminalTheme.Colors) -> Void)?

    func show(title: String, colors: TerminalTheme.Colors, onSave: @escaping (TerminalTheme.Colors) -> Void) {
        self.onSave = onSave
        if window == nil { build() }
        window?.title = title
        let ns = colors.asNSColors
        bgWell.color = ns.bg
        textWell.color = ns.text
        hiWell.color = ns.hi
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let W: CGFloat = 360, H: CGFloat = 240
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        func row(_ label: String, y: CGFloat) -> NSColorWell {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 24, y: y, width: 120, height: 20)
            l.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            l.font = NSFont.systemFont(ofSize: 13)
            content.addSubview(l)
            let well = NSColorWell(frame: NSRect(x: 160, y: y - 4, width: 160, height: 28))
            well.isBordered = true
            content.addSubview(well)
            return well
        }
        var y: CGFloat = H - 48
        let hint = NSTextField(labelWithString: "Applied to that Terminal window.")
        hint.frame = NSRect(x: 24, y: y, width: W - 48, height: 18)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        hint.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(hint)
        y -= 40
        bgWell = row("Background", y: y)
        y -= 40
        textWell = row("Text", y: y)
        y -= 40
        hiWell = row("Highlight", y: y)

        let apply = NSButton(frame: NSRect(x: W - 24 - 100, y: 16, width: 100, height: 32))
        apply.title = "Apply"
        apply.bezelStyle = .rounded
        apply.target = self
        apply.action = #selector(applyPressed)
        content.addSubview(apply)
        let cancel = NSButton(frame: NSRect(x: W - 24 - 100 - 90, y: 16, width: 80, height: 32))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)

        win.contentView = content
        window = win
    }

    @objc private func cancelPressed() { window?.orderOut(nil) }

    @objc private func applyPressed() {
        func trip(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let x = c.usingColorSpace(.deviceRGB) ?? c
            return (x.redComponent, x.greenComponent, x.blueComponent)
        }
        let cols = TerminalTheme.Colors(
            bg: trip(bgWell.color),
            text: trip(textWell.color),
            highlight: trip(hiWell.color)
        )
        window?.orderOut(nil)
        onSave?(cols)
    }
}


/// Modal sheet: tick ban boxes + freeform prompt. Stored on the pair in pairs.json
/// and mirrored into active-pair.json so claude-delegate can inject constraints.
final class PermissionsSheetController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = PermissionsSheetController()

    private var window: NSWindow?
    private var pairName = ""
    private var workerId: String? = nil  // nil = pair-level; w1/w2 = per-worker
    private var onSaved: (() -> Void)?
    private var boxes: [String: NSButton] = [:]
    private var noteView: NSTextView!
    private var presetStatus: NSTextField!
    private var contentRoot: NSView!

    private let keys: [(String, String)] = [
        ("ban_mcp", "Ban MCP tools / external tool servers"),
        ("ban_root", "Ban root / outside-project writes"),
        ("repo_only", "Repo-only (stay inside the project tree)"),
        ("ban_network", "Ban network installs / outbound fetches"),
        ("ban_system_paths", "Ban system paths (~/.ssh, /etc, keychains)"),
        ("ask_each", "Ask in chat before each elevated permission"),
    ]

    func show(for name: String, workerId: String? = nil, onSaved: @escaping () -> Void) {
        self.pairName = name
        self.workerId = workerId
        self.onSaved = onSaved
        if window == nil { buildWindow() }
        loadIntoUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func buildWindow() {
        let W: CGFloat = 460, H: CGFloat = 560
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
        contentRoot = content
        let PAD: CGFloat = 22
        var y = H - PAD - 8

        let title = NSTextField(labelWithString: "Access for this pair")
        title.font = .boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: PAD, y: y - 20, width: W - 2 * PAD, height: 22)
        content.addSubview(title)
        y -= 28

        let sub = NSTextField(wrappingLabelWithString:
            "Checked boxes ban that access on every handoff. “Ask each time” makes Claude request elevated access in chat first. Save a preset once, reuse it on any pair.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: PAD, y: y - 48, width: W - 2 * PAD, height: 48)
        content.addSubview(sub)
        y -= 56

        // Preset bar
        let presetLbl = NSTextField(labelWithString: "PRESETS")
        presetLbl.font = .systemFont(ofSize: 10)
        presetLbl.textColor = .secondaryLabelColor
        presetLbl.frame = NSRect(x: PAD, y: y - 14, width: 80, height: 14)
        content.addSubview(presetLbl)
        y -= 20

        let btnH: CGFloat = 28
        let gap: CGFloat = 8
        let fullW: CGFloat = 108
        let askW: CGFloat = 118
        let loadW: CGFloat = 100
        let saveAsW: CGFloat = 88
        var x = PAD
        content.addSubview(makeButton("Full access", #selector(applyFullPreset),
            NSRect(x: x, y: y - btnH, width: fullW, height: btnH)))
        x += fullW + gap
        content.addSubview(makeButton("Ask each time", #selector(applyAskPreset),
            NSRect(x: x, y: y - btnH, width: askW, height: btnH)))
        x += askW + gap
        content.addSubview(makeButton("Load saved…", #selector(loadSavedPreset),
            NSRect(x: x, y: y - btnH, width: loadW, height: btnH)))
        x += loadW + gap
        content.addSubview(makeButton("Save as…", #selector(saveAsPreset),
            NSRect(x: x, y: y - btnH, width: saveAsW, height: btnH)))
        y -= btnH + 6

        presetStatus = NSTextField(labelWithString: "")
        presetStatus.font = .systemFont(ofSize: 11)
        presetStatus.textColor = .secondaryLabelColor
        presetStatus.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(presetStatus)
        y -= 24

        boxes.removeAll()
        for (key, label) in keys {
            let b = NSButton(checkboxWithTitle: label, target: self, action: #selector(boxChanged(_:)))
            b.frame = NSRect(x: PAD, y: y - 24, width: W - 2 * PAD, height: 24)
            b.font = .systemFont(ofSize: 13)
            b.identifier = NSUserInterfaceItemIdentifier(key)
            content.addSubview(b)
            boxes[key] = b
            y -= 28
        }

        y -= 6
        let noteLbl = NSTextField(labelWithString: "Extra note (injected into worker)")
        noteLbl.font = .systemFont(ofSize: 11)
        noteLbl.textColor = .secondaryLabelColor
        noteLbl.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(noteLbl)
        y -= 22

        let scrollH: CGFloat = 96
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

        let save = makeButton("Save to pair", #selector(savePressed),
            NSRect(x: W - PAD - 120, y: 18, width: 120, height: 32))
        save.keyEquivalent = "\r"
        content.addSubview(save)

        let cancel = makeButton("Cancel", #selector(cancelPressed),
            NSRect(x: W - PAD - 230, y: 18, width: 100, height: 32))
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        content.addSubview(makeButton("Clear all", #selector(clearPressed),
            NSRect(x: PAD, y: 18, width: 90, height: 32)))

        win.contentView = content
        window = win
    }

    private func makeButton(_ title: String, _ sel: Selector, _ frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .rounded
        b.target = self
        b.action = sel
        return b
    }

    private func currentPermissionsFromUI() -> [String: Any] {
        var perms = PairState.defaultPermissions()
        for (key, box) in boxes {
            perms[key] = (box.state == .on)
        }
        perms["custom_prompt"] = noteView?.string ?? ""
        return perms
    }

    private func applyPermissionsToUI(_ perms: [String: Any], status: String) {
        var merged = PairState.defaultPermissions()
        for (k, v) in perms { merged[k] = v }
        for (key, box) in boxes {
            box.state = ((merged[key] as? Bool) == true) ? .on : .off
        }
        noteView?.string = (merged["custom_prompt"] as? String) ?? ""
        presetStatus?.stringValue = status
    }

    private func loadIntoUI() {
        if let workerId {
            window?.title = "Permissions · \(pairName) / \(workerId)"
            let perms = Workers.permissions(pair: pairName, workerId: workerId)
            applyPermissionsToUI(perms, status: matchStatus(for: perms))
        } else {
            window?.title = "Permissions · \(pairName) (Hermes / all)"
            let perms = PairState.permissions(for: pairName)
            applyPermissionsToUI(perms, status: matchStatus(for: perms))
        }
    }

    private func matchStatus(for perms: [String: Any]) -> String {
        for item in PermissionPresets.all() {
            if permissionsEqual(item.permissions, perms) {
                return item.builtin ? "Preset: \(item.name)" : "Saved: \(item.name)"
            }
        }
        return "Custom for this pair"
    }

    private func permissionsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let keys = ["ban_mcp", "ban_root", "ban_network", "ban_system_paths", "repo_only", "ask_each"]
        for k in keys {
            let av = (a[k] as? Bool) ?? false
            let bv = (b[k] as? Bool) ?? false
            if av != bv { return false }
        }
        let an = ((a["custom_prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bn = ((b["custom_prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return an == bn
    }

    @objc private func boxChanged(_ sender: NSButton) {
        presetStatus?.stringValue = "Custom for this pair"
    }

    func textDidChange(_ notification: Notification) {
        presetStatus?.stringValue = "Custom for this pair"
    }

    @objc private func applyFullPreset() {
        applyPermissionsToUI(PairState.fullAccessPermissions(), status: "Preset: Full access")
    }

    @objc private func applyAskPreset() {
        applyPermissionsToUI(PairState.askEachPermissions(), status: "Preset: Ask each time")
    }

    @objc private func loadSavedPreset() {
        let users = PermissionPresets.loadUser()
        if users.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No saved presets yet"
            alert.informativeText = "Tune the checkboxes/note, then hit Save as… to keep a named pack."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Load saved preset"
        alert.informativeText = "Applies into this sheet. Hit Save to pair to stick it on \(pairName)."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for item in users {
            popup.addItem(withTitle: item.name)
            popup.lastItem?.representedObject = item.id
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Load")
        alert.addButton(withTitle: "Delete selected")
        alert.addButton(withTitle: "Cancel")
        let resp = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        guard let id = popup.selectedItem?.representedObject as? String,
              let item = users.first(where: { $0.id == id }) else { return }
        if resp == first {
            applyPermissionsToUI(item.permissions, status: "Saved: \(item.name)")
        } else if resp == NSApplication.ModalResponse(rawValue: first.rawValue + 1) {
            let confirm = NSAlert()
            confirm.messageText = "Delete “\(item.name)”?"
            confirm.informativeText = "This only removes the saved pack. Pair settings stay until you change them."
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() == .alertFirstButtonReturn {
                PermissionPresets.deleteUser(id: id)
                presetStatus?.stringValue = "Deleted saved preset “\(item.name)”"
            }
        }
    }

    @objc private func saveAsPreset() {
        let alert = NSAlert()
        alert.messageText = "Save permission preset"
        alert.informativeText = "Name this pack. Same name overwrites an existing saved preset."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = suggestedPresetName()
        field.placeholderString = "e.g. Strict lab, Client work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save preset")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let item = PermissionPresets.saveUser(name: field.stringValue, permissions: currentPermissionsFromUI())
        presetStatus?.stringValue = "Saved: \(item.name)"
    }

    private func suggestedPresetName() -> String {
        let p = currentPermissionsFromUI()
        if permissionsEqual(p, PairState.fullAccessPermissions()) { return "Full access copy" }
        if permissionsEqual(p, PairState.askEachPermissions()) { return "Ask each time copy" }
        if (p["ask_each"] as? Bool) == true { return "Ask-first custom" }
        let bans = ["ban_mcp", "ban_root", "ban_network", "ban_system_paths", "repo_only"]
            .filter { (p[$0] as? Bool) == true }
        if bans.isEmpty { return "My preset" }
        return "Strict (\(bans.count) bans)"
    }

    @objc private func clearPressed() {
        applyPermissionsToUI(PairState.defaultPermissions(), status: "Custom for this pair")
    }

    @objc private func cancelPressed() {
        window?.orderOut(nil)
    }

    @objc private func savePressed() {
        let perms = currentPermissionsFromUI()
        if let workerId {
            Workers.setPermissions(pair: pairName, workerId: workerId, permissions: perms)
            Pong.log("permissions \(pairName)/\(workerId) -> \(perms)")
        } else {
            let prev = PairState.loadPairsDb()[pairName] as? [String: Any] ?? [:]
            PairState.savePairState(
                pairName,
                hermesWindowId: prev["hermes_window_id"] as? String,
                claudeWindowId: prev["claude_window_id"] as? String,
                claudeMode: prev["claude_mode"] as? String,
                permissions: perms
            )
            Pong.log("permissions \(pairName) -> \(perms)")
        }
        window?.orderOut(nil)
        onSaved?()
    }

    func windowWillClose(_ notification: Notification) {
        // isReleasedWhenClosed = false
    }
}

// MARK: - Link guide (click-to-select two Terminal windows)

final class LinkGuideController: NSObject {
    private enum Phase { case hermes, workers, wiring, done, idle }

    private var window: NSWindow?
    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var hermesMark: NSTextField!
    private var workersMark: NSTextField!
    private var hintLabel: NSTextField!
    private var doneBtn: NSButton!
    private var timer: Timer?
    private var monitor: Any?
    private var phase: Phase = .idle
    private var hermesId: String?
    private var workerIds: [String] = []
    private var pairName = ""
    private weak var parent: PanelController?
    private var baselineId: String?
    private var lastFront: String?
    private var started = Date()

    private let GW: CGFloat = 420, GH: CGFloat = 320

    func startLink(parent: PanelController) {
        self.parent = parent
        phase = .hermes
        hermesId = nil
        workerIds = []
        pairName = PairState.nextPairName()
        started = Date()
        baselineId = Pairing.frontTerminalId()
        lastFront = baselineId
        Pong.log("startLink multi pair=\(pairName) baseline=\(baselineId ?? "-")")
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
        win.title = "Hermes Pong — Link team"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: GW, height: GH))
        stepLabel = PanelController.label("Step 1",
            frame: NSRect(x: 16, y: GH - 36, width: GW - 32, height: 18), size: 11, secondary: true)
        titleLabel = PanelController.label("Click the HERMES Terminal",
            frame: NSRect(x: 16, y: GH - 68, width: GW - 32, height: 28), bold: true, size: 15)
        hermesMark = PanelController.label("○  Hermes  —  not selected",
            frame: NSRect(x: 16, y: GH - 110, width: GW - 32, height: 22), size: 13)
        workersMark = PanelController.label("○  Workers  —  none yet",
            frame: NSRect(x: 16, y: GH - 168, width: GW - 32, height: 48), size: 12)
        workersMark.maximumNumberOfLines = 4
        hintLabel = PanelController.label(
            "Click Terminal windows. Marks only appear here.",
            frame: NSRect(x: 16, y: 56, width: GW - 32, height: 50), size: 12, secondary: true)

        doneBtn = NSButton(frame: NSRect(x: GW - 200, y: 14, width: 100, height: 32))
        doneBtn.title = "Done"
        doneBtn.bezelStyle = .rounded
        doneBtn.target = self
        doneBtn.action = #selector(donePressed(_:))
        doneBtn.isEnabled = false
        doneBtn.isHidden = true

        let cancel = NSButton(frame: NSRect(x: GW - 90, y: 14, width: 74, height: 32))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelPressed(_:))

        for v in [stepLabel!, titleLabel!, hermesMark!, workersMark!, hintLabel!] {
            content.addSubview(v)
        }
        content.addSubview(doneBtn)
        content.addSubview(cancel)
        win.contentView = content
        window = win
    }

    private func titleFor(_ wid: String?) -> String {
        guard let wid else { return "" }
        for (i, t) in Pairing.listTerminalWindows() where i == wid {
            return String(t.prefix(40))
        }
        return "window \(wid)"
    }

    private func render() {
        switch phase {
        case .hermes:
            stepLabel.stringValue = "Step 1 — Hermes"
            titleLabel.stringValue = "Click the HERMES Terminal window"
            hintLabel.stringValue = "Then add one or more worker Terminals."
            doneBtn.isHidden = true
        case .workers:
            stepLabel.stringValue = "Step 2 — Workers (\(workerIds.count))"
            titleLabel.stringValue = workerIds.isEmpty
                ? "Click a WORKER Terminal"
                : "Add another worker, or Done"
            hintLabel.stringValue = "Click other Terminals (Claude, Kimi, …).\\nPress Done when the army is complete."
            doneBtn.isHidden = workerIds.isEmpty
            doneBtn.isEnabled = !workerIds.isEmpty
            doneBtn.title = "Done (\(workerIds.count))"
        case .wiring:
            stepLabel.stringValue = "Linking…"
            titleLabel.stringValue = "Registering windows"
            hintLabel.stringValue = "No scripts injected into worker TUIs."
            doneBtn.isHidden = true
        case .done:
            stepLabel.stringValue = "Done"
            titleLabel.stringValue = "Linked"
            hintLabel.stringValue = "Route with pong-delegate --worker w1|w2|…"
            doneBtn.isHidden = true
        case .idle:
            break
        }
        hermesMark.stringValue = hermesId != nil
            ? "✓  Hermes  —  \(titleFor(hermesId))" : "○  Hermes  —  not selected"
        if workerIds.isEmpty {
            workersMark.stringValue = "○  Workers  —  none yet"
        } else {
            let lines = workerIds.enumerated().map { i, id in
                "✓  w\(i + 1)  —  \(titleFor(id))"
            }
            workersMark.stringValue = lines.joined(separator: "\\n")
        }
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard phase == .hermes || phase == .workers else { return }
        if Date().timeIntervalSince(started) > 90 {
            phase = .idle
            titleLabel.stringValue = "Timed out"
            hintLabel.stringValue = "Try Link again."
            stopTimer()
            removeClickMonitor()
            return
        }
        if Date().timeIntervalSince(started) < 0.5 { return }
        trySelectFront(force: false)
    }

    private func trySelectFront(force: Bool) {
        guard phase == .hermes || phase == .workers else { return }
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
                hintLabel.stringValue = "That’s Hermes. Click a worker Terminal."
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
            phase = .workers
            started = Date()
            baselineId = wid
            lastFront = wid
            Pong.log("selected HERMES id=\(wid)")
            render()
            return
        }
        if phase == .workers {
            guard wid != hermesId else { return }
            if workerIds.contains(wid) {
                hintLabel.stringValue = "Already added. Click another, or Done."
                return
            }
            workerIds.append(wid)
            started = Date()
            lastFront = wid
            Pong.log("selected WORKER id=\(wid) count=\(workerIds.count)")
            render()
        }
    }

    @objc private func donePressed(_ sender: NSButton) {
        guard phase == .workers, let hid = hermesId, !workerIds.isEmpty else { return }
        phase = .wiring
        render()
        stopTimer()
        removeClickMonitor()
        let (name, workers) = (pairName, workerIds)
        DispatchQueue.global(qos: .userInitiated).async {
            Pairing.wireArmy(name, hermesId: hid, workerWindowIds: workers)
            DispatchQueue.main.async { self.finishOk(name) }
        }
    }

    private func finishOk(_ name: String) {
        phase = .done
        render()
        titleLabel.stringValue = "Linked · \(name) · \(workerIds.count) worker(s)"
        parent?.refreshUI()
        PanelController.showPairPersistTip(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.closeGuide() }
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

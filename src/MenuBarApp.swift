import AppKit
import Foundation

/// Pong (Agent-Pong) — menu bar + control panel.
/// Conductor-agnostic mission control (Grok recommended; Hermes/Claude/custom supported).

// MARK: - Shared helpers (shell, AppleScript, state files, logging)

enum Pong {
    /// Prefer ~/.pong; fall back to legacy ~/.hermes-pong when that tree has data.
    static var stateDir: String {
        let primary = NSHomeDirectory() + "/.pong"
        let legacy = NSHomeDirectory() + "/.hermes-pong"
        let fm = FileManager.default
        if fm.fileExists(atPath: primary) { return primary }
        if let items = try? fm.contentsOfDirectory(atPath: legacy), !items.isEmpty {
            return legacy
        }
        try? fm.createDirectory(atPath: primary, withIntermediateDirectories: true)
        return primary
    }
    static var logPath: String { NSHomeDirectory() + "/Library/Logs/Pong.log" }
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
        do { try script.write(to: tmp, atomically: true, encoding: .utf8) } catch {
            log("osascript write fail: \(error)")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [tmp.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            log("osascript run fail: \(error)")
            return ""
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 || !err.isEmpty {
            log("osascript exit=\(p.terminationStatus) err=\(err) out=\(out)")
        }
        return out
    }

    /// Prefer for Terminal UI changes (titles/colors). Uses app Automation TCC properly.
    @discardableResult
    static func appleScript(_ source: String) -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            log("appleScript: could not create script")
            return ""
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String
                ?? error[NSAppleScript.errorNumber] as? String
                ?? "\(error)"
            log("appleScript ERR: \(msg)")
            return "ERR:\(msg)"
        }
        return (result.stringValue ?? "OK").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // View sessions are not pairs (conductor view, legacy Claude view, worker views).
        if s.hasSuffix("-h") || s.hasSuffix("-c") { return false }
        // *-w0 / *-w2 — worker view sessions
        if s.range(of: #"-w\d+$"#, options: .regularExpression) != nil { return false }
        return s == "pong-team" || s.hasPrefix("pong-team-")
            || s == "hermes-claude" || s.hasPrefix("hermes-claude-")
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
        if !existing.contains("pong-team") { return "pong-team" }
        for n in 1...50 where !existing.contains("pong-team-\(n)") { return "pong-team-\(n)" }
        // legacy hermes-pair* still load; new teams use pong-team*
        return "pong-team-\(Int(Date().timeIntervalSince1970) % 10000)"
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
                              workers: [[String: Any]]? = nil,
                              conductor: [String: Any]? = nil,
                              transportDefault: String? = nil) {
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
        // Conductor (v2): default Grok Build when creating fresh pairs
        var cond: [String: Any] = {
            if let conductor { return conductor }
            if let prevC = prev["conductor"] as? [String: Any] { return prevC }
            var d = ConductorType.resolved("grok").asDict()
            d["window_id"] = hermesWindowId ?? prev["hermes_window_id"] ?? NSNull()
            d["tmux_index"] = 0
            d["mode"] = "tmux"
            return d
        }()
        if let hermesWindowId {
            cond["window_id"] = hermesWindowId
        } else if cond["window_id"] == nil, let prevH = prev["hermes_window_id"] {
            cond["window_id"] = prevH
        }
        var entry: [String: Any] = [
            "schema_version": 2,
            "conductor": cond,
            "hermes_window_id": cond["window_id"] ?? hermesWindowId ?? prev["hermes_window_id"] ?? NSNull(),
            "conductor_window_id": cond["window_id"] ?? NSNull(),
            "claude_window_id": primaryWid,
            "worker_window_id": primaryWid,
            "claude_mode": mode,
            "worker_type": primaryType,
            "worker_label": primaryLabel,
            "worker_cmd": primaryCmd,
            "transport_default": transportDefault
                ?? (prev["transport_default"] as? String)
                ?? "job+paste",
            "autonomy_level": "full",
            "updated": Date().timeIntervalSince1970,
        ]
        if let ws, !ws.isEmpty {
            entry["workers"] = ws
        }
        for k in ["view_hermes", "view_claude", "view_worker", "view_conductor",
                  "display_name", "colors", "project_root", "team_brief", "stowed"] {
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

        let reply = Pong.stateDir + "/last-reply.txt"
        if !FileManager.default.fileExists(atPath: reply) {
            try? "(no worker reply yet — pong job create / pong delegate)\n"
                .write(toFile: reply, atomically: true, encoding: .utf8)
        }
        let legacyReply = Pong.stateDir + "/last-claude.txt"
        if !FileManager.default.fileExists(atPath: legacyReply) {
            try? "(no worker reply yet)\n".write(toFile: legacyReply, atomically: true, encoding: .utf8)
        }
        Pong.log("saved pair state \(session) conductor=\(cond["type"] ?? "?") \(entry)")
        // Refresh bind card for conductor skills
        Pong.sh("python3 \"$HOME/bin/hermes_pong.py\" write-bind --session \(session) >/dev/null 2>&1 || "
            + "python3 \"$HOME/src/Agent-Pong/scripts/hermes_pong.py\" write-bind --session \(session) >/dev/null 2>&1 || true")
    }

}

// MARK: - Conductor types (who receives mission prompts)

struct ConductorType: Equatable {
    let id: String
    let label: String
    let cmd: String
    /// Shown in New Team picker; Grok is recommended default.
    let recommended: Bool

    static let all: [ConductorType] = [
        ConductorType(id: "grok", label: "Grok Build (recommended)", cmd: "grok", recommended: true),
        ConductorType(id: "hermes", label: "Hermes Agent", cmd: "hermes chat", recommended: false),
        ConductorType(id: "claude", label: "Claude Code", cmd: "claude", recommended: false),
        ConductorType(id: "custom", label: "Custom command…", cmd: "", recommended: false),
    ]

    static func named(_ id: String) -> ConductorType {
        all.first(where: { $0.id == id }) ?? all[0]
    }

    static func resolved(_ id: String) -> ConductorType {
        var base = named(id)
        let path = Pong.stateDir + "/conductors.json"
        let db = Pong.loadJSON(path)
        if let row = db[id] as? [String: Any], let cmd = row["cmd"] as? String, !cmd.isEmpty {
            base = ConductorType(
                id: base.id,
                label: (row["label"] as? String) ?? base.label,
                cmd: cmd,
                recommended: base.recommended
            )
        }
        return base
    }

    func asDict() -> [String: Any] {
        [
            "id": "c1",
            "type": id,
            "label": label.replacingOccurrences(of: " (recommended)", with: ""),
            "cmd": cmd,
            "mode": "tmux",
            "tmux_index": 0,
        ]
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
        // "Grok Build" = SuperGrok / Premium+ coding CLI on the user's own
        // Grok login and weekly pool. Same id/cmd for bridge + state compat.
        WorkerType(id: "grok", label: "Grok Build", cmd: "grok", tmuxWindowName: "Worker"),
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

    /// Launch a new worker CLI into an existing team (new tmux window + Terminal).
    @discardableResult
    static func addWorker(pair: String, type: WorkerType) -> String? {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        let nextIdx = ws.count + 1
        let wid = "w\(nextIdx)"
        // avoid id collision
        var id = wid
        var n = nextIdx
        while ws.contains(where: { ($0["id"] as? String) == id }) {
            n += 1
            id = "w\(n)"
        }
        let tmuxIndex = (ws.compactMap { $0["tmux_index"] as? Int }.max() ?? 0) + 1
        let cmd = type.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let launch = cmd.isEmpty ? "claude" : cmd
        let pathExport = "export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$PATH"
        let safeCmd = launch.replacingOccurrences(of: "'", with: "'\\''")

        // Ensure base tmux session exists
        Pong.sh("tmux has-session -t \(pair) 2>/dev/null || tmux new-session -d -s \(pair) -n Conductor")
        let winName = "W\(n)"
        Pong.sh("tmux new-window -t \(pair) -n \(winName)")
        // attach window index: use last window
        let idxOut = Pong.sh("tmux display-message -p -t \(pair) '#{window_index}' 2>/dev/null || echo \(tmuxIndex)")
        let actualIdx = Int(idxOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? tmuxIndex
        Pong.sh("tmux send-keys -t \(pair):\(actualIdx) -l '\(pathExport); export PONG_SESSION=\(pair) HERMES_PONG_SESSION=\(pair); printf \"\\n  WORKER · \(type.label) · \(pair):\(actualIdx)\\n\\n\"; \(safeCmd)'")
        usleep(80_000)
        Pong.sh("tmux send-keys -t \(pair):\(actualIdx) Enter")

        // Open Terminal attached to this window view
        let view = "\(pair)-w\(actualIdx - 1)"
        Pong.sh("tmux has-session -t \(view) 2>/dev/null || tmux new-session -d -s \(view) -t \(pair)")
        Pong.sh("tmux select-window -t \(view):\(actualIdx) 2>/dev/null || tmux select-window -t \(pair):\(actualIdx)")
        let before = Set(TerminalTheme.listWindows().map(\.id))
        _ = Pong.osascript("""
        tell application "Terminal"
          do script "\(pathExport); exec tmux attach-session -t \(view)"
          delay 0.6
        end tell
        """)
        usleep(300_000)
        let after = TerminalTheme.listWindows()
        let newId = after.first(where: { !before.contains($0.id) })?.id
            ?? after.last(where: { $0.title.contains(view) || $0.title.contains(pair) })?.id

        let rec = makeWorker(
            id: id,
            type: type.id,
            label: type.label,
            windowId: newId ?? "",
            mode: "tmux",
            cmd: launch,
            tmuxIndex: actualIdx
        )
        var recMut = rec
        if newId == nil { recMut["window_id"] = NSNull() }
        else { recMut["window_id"] = newId! }
        ws.append(recMut)
        entry["workers"] = ws
        entry["updated"] = Date().timeIntervalSince1970
        if let first = ws.first {
            entry["claude_window_id"] = first["window_id"] ?? NSNull()
            entry["worker_window_id"] = first["window_id"] ?? NSNull()
        }
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair || active["session"] == nil {
            active = entry
            active["session"] = pair
            Pong.writeJSON(PairState.activePath, active)
        }
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")
        Pong.log("addWorker \(pair)/\(id) type=\(type.id) window=\(newId ?? "-")")
        TerminalTheme.applyPair(pair)
        return id
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

    /// Team options (display name, project root, team brief) on the live pair.
    /// Empty strings mean unset but are still written, so a stale value can't
    /// survive via the active-pair.json merge. The brief is mirrored to
    /// ~/.hermes-pong/briefs/<session>.md for the bridge/skills; pairs.json
    /// stays the source of truth for the app.
    static func setTeamOptions(_ pair: String, displayName: String, projectRoot: String, teamBrief: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["display_name"] = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["project_root"] = root
        let brief = teamBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["team_brief"] = brief
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        writeBriefFile(session: pair, brief: brief)
        // Keep the orchestra bind card in step with the fields just saved.
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")
        TerminalTheme.applyPair(pair)
        Pong.log("team options \(pair) root=\(root.isEmpty ? "(unset)" : root) brief_chars=\(brief.count)")
    }

    /// Human/agent-readable mirror of team_brief. Removed when the brief is empty.
    static func writeBriefFile(session: String, brief: String) {
        let dir = Pong.stateDir + "/briefs"
        let path = dir + "/\(session).md"
        if brief.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (brief + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Stow flag: Terminal windows hidden, pair + tmux still alive. Set by
    /// Pairing.stow/unstow; cleared by Front. savePairState preserves it.
    static func setStowed(_ pair: String, _ stowed: Bool) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["stowed"] = stowed
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
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

    /// View-session token always present in Terminal title: "tmux attach-session -t hermes-pair-w0"
    static func viewToken(pair: String, role: String) -> String {
        if role == "hermes" { return "\(pair)-h" }
        if role.hasPrefix("w"), let n = Int(role.dropFirst()), n >= 1 {
            return "\(pair)-w\(n - 1)"
        }
        return "\(pair)-\(role)"
    }

    static func profileName(pair: String, role: String) -> String {
        let raw = "HP-\(pair)-\(role)".replacingOccurrences(of: " ", with: "-")
        return raw.count <= 40 ? raw : String(raw.prefix(40))
    }

    static func listWindows() -> [(id: String, title: String)] {
        let out = Pong.appleScript("""
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

    /// Strict: only windows whose title contains "attach-session -t <token>".
    /// Never match agent chat (hermes ▸) or bare "hermes".
    static func resolvePairWindow(stored: String?, viewToken: String) -> String? {
        let wins = listWindows()
        let needle = "attach-session -t \(viewToken)".lowercased()
        func isPairPane(_ title: String) -> Bool {
            let t = title.lowercased()
            if t.contains("hermes ▸") { return false }
            if t.contains("osascript") { return false }
            return t.contains(needle)
        }
        if let s = stored, Int(s) != nil {
            if let title = wins.first(where: { $0.id == s })?.title, isPairPane(title) {
                return s
            }
        }
        for (id, title) in wins where isPairPane(title) {
            return id
        }
        Pong.log("theme resolve miss token=\(viewToken) windows=\(wins.map { $0.title }.joined(separator: " || "))")
        return nil
    }

    /// Title + colors on ONE pair pane. Uses NSAppleScript + tab properties.
    /// colors.highlight = Marker accent (bold + cursor). Terminal has no title-bar color API.
    static func apply(windowId: String?, displayTitle: String, viewToken: String, colors: Colors?, profile: String) {
        guard let wid = windowId, Int(wid) != nil else {
            Pong.log("theme apply skip — no window for \(viewToken)")
            return
        }
        if let title = listWindows().first(where: { $0.id == wid })?.title {
            let t = title.lowercased()
            let needle = "attach-session -t \(viewToken)".lowercased()
            if t.contains("hermes ▸") || !t.contains(needle) {
                Pong.log("theme APPLY BLOCKED window=\(wid) token=\(viewToken) title=\(title)")
                return
            }
        }

        let safeTitle = escapeAS(String(displayTitle.prefix(48))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: ""))
        let prof = escapeAS(profile)

        var colorLines = ""
        if let c = colors {
            let bg = c.t16(c.bg)
            let tx = c.t16(c.text)
            let win = c.t16(c.highlight)
            colorLines = """

            set setName to "\(prof)"
            try
              set theme to settings set setName
            on error
              set theme to make new settings set with properties {name:setName}
            end try
            set background color of theme to \(bg)
            set normal text color of theme to \(tx)
            set bold text color of theme to \(win)
            set cursor color of theme to \(win)
            set current settings of T to theme
            set background color of T to \(bg)
            set normal text color of T to \(tx)
            set bold text color of T to \(win)
            set cursor color of T to \(win)
            """
        }

        let source = """
        tell application "Terminal"
          try
            set W to window id \(wid)
            set T to selected tab of W
            set title displays custom title of T to true
            set title displays device name of T to false
            set title displays shell path of T to false
            set title displays window size of T to false
            try
              set title displays file name of T to false
            end try
            try
              set title displays settings name of T to false
            end try
            set custom title of T to "\(safeTitle)"
            \(colorLines)
            return "OK"
          on error errMsg
            return "ERR:" & errMsg
          end try
        end tell
        """
        let out = Pong.appleScript(source)
        Pong.log("theme apply window=\(wid) token=\(viewToken) title=\(displayTitle) → \(out.isEmpty ? "(empty)" : out)")
    }

    static func tmuxTitle(baseSession: String, tmuxIndex: Int, displayTitle: String) {
        let safe = displayTitle
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        _ = Pong.sh("tmux set-option -t \(baseSession):\(tmuxIndex) automatic-rename off 2>/dev/null || true")
        _ = Pong.sh("tmux rename-window -t \(baseSession):\(tmuxIndex) '\(safe)' 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -t \(baseSession) set-titles on 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -t \(baseSession) set-titles-string '#W' 2>/dev/null || true")
    }

    static func applyPair(_ pair: String) {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hermesLabel = (display?.isEmpty == false) ? display! : pair
        let hColors = Colors.from(entry["colors"]) ?? .hermesDefault
        let storedH = entry["hermes_window_id"].flatMap { v -> String? in
            let s = "\(v)"; return (s == "<null>" || s.isEmpty) ? nil : s
        }
        let hToken = viewToken(pair: pair, role: "hermes")
        let hid = resolvePairWindow(stored: storedH, viewToken: hToken)
        let condType = (entry["conductor"] as? [String: Any])?["type"] as? String
        let condLabel = (entry["conductor"] as? [String: Any])?["label"] as? String
        let hubTitle = "\(condLabel ?? "Conductor") · \(hermesLabel)"
        apply(windowId: hid, displayTitle: hubTitle, viewToken: hToken,
              colors: hColors, profile: profileName(pair: pair, role: "hermes"))
        tmuxTitle(baseSession: pair, tmuxIndex: 0, displayTitle: hubTitle)
        _ = condType // reserved for future per-conductor chrome

        var ws = Workers.list(from: entry)
        var changed = false
        for i in 0..<ws.count {
            let id = (ws[i]["id"] as? String) ?? "w\(i + 1)"
            let lab = (ws[i]["label"] as? String) ?? "Worker"
            let storedW = "\(ws[i]["window_id"] ?? "")"
            let storedOpt = Int(storedW) != nil ? storedW : nil
            let token = viewToken(pair: pair, role: id)
            let wid = resolvePairWindow(stored: storedOpt, viewToken: token)
            let cols = Colors.from(ws[i]["colors"]) ?? .workerDefault
            apply(windowId: wid, displayTitle: lab, viewToken: token,
                  colors: cols, profile: profileName(pair: pair, role: id))
            let tmuxIdx = (ws[i]["tmux_index"] as? Int) ?? (i + 1)
            tmuxTitle(baseSession: pair, tmuxIndex: tmuxIdx, displayTitle: lab)
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
/// Spawnable from Show Teams…
enum SavedTeams {
    static var path: String { Pong.stateDir + "/teams.json" }

    struct Team {
        let id: String
        let name: String
        let displayName: String
        let hermesColors: [String: Any]?
        let workers: [[String: Any]]
        let projectRoot: String
        let teamBrief: String
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
                workers: workers,
                projectRoot: (row["project_root"] as? String) ?? "",
                teamBrief: (row["team_brief"] as? String) ?? ""
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
            workers: cleanWorkers,
            projectRoot: (entry["project_root"] as? String) ?? "",
            teamBrief: (entry["team_brief"] as? String) ?? ""
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


    @discardableResult
    static func duplicate(id: String) -> Team? {
        guard let src = loadAll().first(where: { $0.id == id }) else { return nil }
        var list = loadAll()
        var base = src.name + " copy"
        var n = 2
        while list.contains(where: { $0.name.caseInsensitiveCompare(base) == .orderedSame }) {
            base = "\(src.name) copy \(n)"
            n += 1
        }
        let newId = "team-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        let team = Team(
            id: newId,
            name: base,
            displayName: src.displayName,
            hermesColors: src.hermesColors,
            workers: src.workers,
            projectRoot: src.projectRoot,
            teamBrief: src.teamBrief
        )
        list.append(team)
        writeAll(list)
        Pong.log("duplicated team \(id) → \(newId) name=\(base)")
        return team
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
            if !t.projectRoot.isEmpty { row["project_root"] = t.projectRoot }
            if !t.teamBrief.isEmpty { row["team_brief"] = t.teamBrief }
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
        entry["project_root"] = team.projectRoot
        entry["team_brief"] = team.teamBrief
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
        Workers.writeBriefFile(session: pair, brief: team.teamBrief)
        // Re-write the bind card now that project_root/team_brief are on the
        // live entry — the first card (written at pair start) predates them.
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")
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
        flashWindows(ids)
    }

    /// Raise + flash any set of Terminal windows in ONE AppleScript (a single
    /// activate, one blink). The LAST id ends frontmost — pass Hermes last.
    static func flashWindows(_ ids: [String]) {
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
        // Front on a stowed pair: show its windows and clear the flag first,
        // then the normal raise/flash below.
        if (entry["stowed"] as? Bool) == true { unstow(name) }
        // Raise the WHOLE team (every saved worker window + Hermes), not just
        // Hermes + primary worker. pairWindowIds orders Hermes last = on top.
        let ids = pairWindowIds(name)
        if !ids.isEmpty {
            flashWindows(ids)
        } else {
            Pong.sh("tmux switch-client -t \(name):0 2>/dev/null || true")
            Pong.osascript("tell application \"Terminal\" to activate")
        }
    }

    // MARK: Stow (hide a team's Terminal windows; pair + tmux keep running)

    /// All saved Terminal window ids for a pair (every worker + Hermes) — the
    /// same stored ids Front uses. Never a front-window guess. Workers first,
    /// Hermes LAST, so a flash over this list leaves Hermes frontmost.
    private static func pairWindowIds(_ name: String) -> [String] {
        var entry = PairState.loadPairsDb()[name] as? [String: Any] ?? [:]
        if entry.isEmpty {
            let cur = Pong.loadJSON(PairState.activePath)
            if cur["session"] as? String == name { entry = cur }
        }
        var ids: [String] = []
        for w in Workers.list(from: entry) {
            let s = "\(w["window_id"] ?? "")"
            if Int(s) != nil, !ids.contains(s) { ids.append(s) }
        }
        let h = "\(entry["hermes_window_id"] ?? "")"
        if Int(h) != nil, !ids.contains(h) { ids.append(h) }
        return ids
    }

    /// Hide/show a pair's windows. Per-window try so one dead id never breaks
    /// the rest; `visible` is preferred, miniaturize is the fallback. No TUI
    /// injection, no tmux detach, no pane kills — the pair stays fully alive.
    private static func setPairWindowsVisible(_ name: String, visible: Bool) {
        let ids = pairWindowIds(name)
        guard !ids.isEmpty else { return }
        var lines = ["tell application \"Terminal\""]
        for wid in ids {
            lines += [
                "  try",
                "    set visible of window id \(wid) to \(visible ? "true" : "false")",
                "  on error",
                "    try",
                "      set miniaturized of window id \(wid) to \(visible ? "false" : "true")",
                "    end try",
                "  end try",
            ]
        }
        lines.append("end tell")
        Pong.osascript(lines.joined(separator: "\n"))
    }

    /// Stow: alive but off-screen. Idempotent; missing window ids are skipped
    /// but the flag is still recorded so the UI shows the pair as hidden.
    static func stow(_ name: String) {
        setPairWindowsVisible(name, visible: false)
        Workers.setStowed(name, true)
        Pong.log("stow \(name)")
    }

    static func unstow(_ name: String) {
        setPairWindowsVisible(name, visible: true)
        Workers.setStowed(name, false)
        Pong.log("unstow \(name)")
    }

    /// Focus this team: stow every OTHER live pair, then show + raise this one.
    static func focusTeam(_ name: String) {
        for other in PairState.listPairs() where other != name {
            stow(other)
        }
        unstow(name)
        bringToFront(name)
    }

    /// True if the Terminal tab already runs a Hermes/Claude TUI (not a bare shell).
    static func looksLikeTui(_ windowId: String) -> Bool {
        for (wid, title) in listTerminalWindows() where wid == windowId {
            let t = title.lowercased()
            return ["claude", "✳", "fable", "hermes", "⚕", "grok", "kimi", "codex", "opencode", "deepseek"].contains { t.contains($0) }
        }
        return false
    }

    /// New team: conductor (default Grok) + one or more workers.
    static func startFresh(worker: WorkerType = WorkerType.named("claude")) -> String {
        startFresh(workers: [worker], conductor: ConductorType.resolved("grok"))
    }

    static func startFresh(workers: [WorkerType], conductor: ConductorType = ConductorType.resolved("grok")) -> String {
        var list = workers
        if list.isEmpty { list = [WorkerType.named("claude")] }
        let name = PairState.nextPairName()
        let pathExport = "export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$PATH"
        let viewH = "\(name)-h"
        let cond = conductor
        let condLabel = cond.label.replacingOccurrences(of: " (recommended)", with: "")
        let condCmdRaw = cond.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let condCmd = condCmdRaw.isEmpty ? "grok" : condCmdRaw
        let safeCondCmd = condCmd.replacingOccurrences(of: "'", with: "'\\''")
        let skillHint: String = {
            switch cond.id {
            case "grok": return "grok-pong-bridge"
            case "hermes": return "hermes-pong-bridge"
            default: return "pong-bridge"
            }
        }()

        var toKill = [name, viewH, "\(name)-c"]
        for i in 0..<max(list.count, 8) { toKill.append("\(name)-w\(i)") }
        for s in toKill {
            Pong.sh("tmux has-session -t \(s) 2>/dev/null && tmux kill-session -t \(s) || true")
        }

        Pong.sh("tmux new-session -d -s \(name) -n Conductor")
        // Team identity: PONG_SESSION (+ legacy HERMES_PONG_SESSION for old skills)
        Pong.sh("tmux set-environment -t \(name) PONG_SESSION \(name)")
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_SESSION \(name)")
        Pong.sh("tmux set-environment -t \(name) PONG_ROLE conductor")
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_ROLE orchestra")
        let orchestraEnv = "export PONG_SESSION=\(name) HERMES_PONG_SESSION=\(name) PONG_ROLE=conductor HERMES_PONG_ROLE=orchestra"
        let writeBind = "python3 $HOME/bin/hermes_pong.py write-bind --session \(name) >/dev/null 2>&1 || python3 $HOME/bin/pong status -s \(name) >/dev/null 2>&1 || true"
        let banner = "CONDUCTOR · \(condLabel) · \(name):0"
        Pong.sh("tmux send-keys -t \(name):0 -l '\(pathExport); \(orchestraEnv); \(writeBind); printf \"\\n  \(banner)\\n  skill: \(skillHint) · pong gate · pong job create\\n\\n\"; \(safeCondCmd)'")
        usleep(80_000)
        Pong.sh("tmux send-keys -t \(name):0 Enter")

        var workerRecords: [[String: Any]] = []
        for (idx, worker) in list.enumerated() {
            let wCmd = worker.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            let launchCmd = wCmd.isEmpty ? "claude" : wCmd
            let winName = list.count == 1 ? "Worker" : "W\(idx + 1)"
            Pong.sh("tmux new-window -t \(name) -n \(winName)")
            let safeCmd = launchCmd.replacingOccurrences(of: "'", with: "'\\''")
            let wbanner = "WORKER · \(worker.label) · \(name):\(idx + 1)"
            Pong.sh("tmux send-keys -t \(name):\(idx + 1) -l '\(pathExport); export PONG_SESSION=\(name) HERMES_PONG_SESSION=\(name); printf \"\\n  \(wbanner)\\n\\n\"; \(safeCmd)'")
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
        for i in 0..<workerRecords.count {
            if i < windowIds.count, Int(windowIds[i]) != nil {
                workerRecords[i]["window_id"] = windowIds[i]
            } else {
                workerRecords[i]["window_id"] = NSNull()
            }
        }
        // Stack Terminal windows vertically (Hermes on top, workers below)
        tileWindowsVertically(hermesId: hid, workerIds: windowIds.filter { !$0.isEmpty })
        TerminalTheme.applyPair(name)
        // Titles + default colors (match by attach-session -t view token)
        TerminalTheme.applyPair(name)
        let primaryWid = windowIds.first(where: { Int($0) != nil })
        let teamLabel = list.count == 1 ? list[0].label : "\(list.count) workers"

        var condDict = cond.asDict()
        condDict["window_id"] = hid ?? NSNull()
        condDict["cmd"] = condCmd
        PairState.savePairState(
            name,
            hermesWindowId: hid,
            claudeWindowId: primaryWid,
            claudeMode: "tmux",
            workerType: list[0].id,
            workerLabel: teamLabel,
            workerCmd: list[0].cmd.isEmpty ? "claude" : list[0].cmd,
            workers: workerRecords,
            conductor: condDict,
            transportDefault: "job+paste"
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
        // Refresh the bind card: the copy written at hermes launch predates
        // savePairState, so it may lack the full roster.
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(name) >/dev/null 2>&1 || true")

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
        // Linked pairs get the same team binding as fresh ones.
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_SESSION \(name) 2>/dev/null || true")
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_ROLE orchestra 2>/dev/null || true")
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(name) >/dev/null 2>&1 || true")
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
        alert.messageText = "Enjoying Pong?"
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
    private var hasActivePair = false
    private var menuSignal: PongTheme.SystemSignal = .idle
    private var onboardingWindow: NSWindow?
    private var cachedSessions: [String] = []
    private var lastSessionPoll = Date.distantPast

    private var onboardedFlagPath: String { Pong.stateDir + "/onboarded" }
    private var isOnboarded: Bool { FileManager.default.fileExists(atPath: onboardedFlagPath) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = PongTheme.menuIcon(signal: .idle, phase: 0)
            button.image?.isTemplate = false
            button.title = ""
            button.toolTip = "Pong — agent mission control"
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
        let appMenu = NSMenu(title: "Pong")
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About Pong", action: #selector(showAbout), keyEquivalent: "")
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

        let quit = NSMenuItem(title: "Quit Pong", action: #selector(quitAll), keyEquivalent: "q")
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
        alert.messageText = "Pong"
        alert.informativeText = "Local agent mission control.\nOrchestrator + multi-CLI workers on a canvas.\nkulpio/Agent-Pong"
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
            "Pong pairs orchestrator and worker Terminal windows. macOS asks once for each permission below.",
            muted: true))

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("Automation", bold: true))
        stack.addArrangedSubview(label(
            "Pong can send tasks into Terminal windows. macOS prompts the first time — re-enable in Settings if you decline.",
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
        window.title = "Welcome to Pong"
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

    // MARK: - Verdict ledger (read-only monitoring surface)

    private struct LedgerSummary {
        let rounds: Int
        let acceptPct: Int
        let rejectStreak: Int
        let lastLine: String
    }

    private var ledgerDirPath: String { Pong.stateDir + "/ledger" }

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
        // Refresh signal ~every 1s (not every 0.1s) for snapshot I/O
        if Int(glowPhase * 10) % 10 == 0 {
            menuSignal = PongTheme.signalFromState()
        }
        glowPhase += 0.1
        if glowPhase > .pi * 2 { glowPhase -= .pi * 2 }
        let phase = CGFloat((sin(Double(glowPhase)) + 1) / 2)
        guard let button = statusItem?.button else { return }
        button.image = PongTheme.menuIcon(signal: menuSignal, phase: phase)
        button.image?.isTemplate = false
        button.title = ""
        switch menuSignal {
        case .idle:
            button.toolTip = "Pong — idle"
        case .orchestratorWorking:
            button.toolTip = "Pong — orchestrator working"
        case .humanNeeded:
            button.toolTip = "Pong — human input needed"
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
        menu.addItem(item("Quit Pong", #selector(quitAll)))
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
        guard let (conductor, workers) = Self.pickTeamLaunch() else {
            lastSessionPoll = .distantPast
            rebuildMenu()
            PanelController.shared.refreshUI()
            return
        }
        if workers.isEmpty { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Pairing.startFresh(workers: workers, conductor: conductor)
            DispatchQueue.main.async { [weak self] in
                self?.lastSessionPoll = .distantPast
                self?.rebuildMenu()
                PanelController.shared.refreshUI()
            }
        }
    }

    /// Pick conductor first (Grok recommended), then workers.
    /// Returns (conductor, workers) or nil if cancelled.
    static func pickTeamLaunch() -> (ConductorType, [WorkerType])? {
        NSApp.activate(ignoringOtherApps: true)
        let saved = SavedTeams.loadAll()

        let condAlert = NSAlert()
        condAlert.messageText = "New team — conductor"
        condAlert.informativeText =
            "Who receives your mission prompts?\n" +
            "Grok Build is recommended for coding teams. Hermes users can pick Hermes — no Grok required.\n" +
            "Workers (Claude, etc.) stay separate terminals you can jump into."
        for c in ConductorType.all where c.id != "custom" {
            condAlert.addButton(withTitle: c.label)
        }
        condAlert.addButton(withTitle: "Custom…")
        if !saved.isEmpty {
            condAlert.addButton(withTitle: "Show Teams")
        }
        condAlert.addButton(withTitle: "Cancel")
        let cr = condAlert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = cr.rawValue - first
        let fixed = ConductorType.all.filter { $0.id != "custom" }
        var conductor = ConductorType.resolved("grok")
        if idx >= 0 && idx < fixed.count {
            conductor = ConductorType.resolved(fixed[idx].id)
        } else if idx == fixed.count {
            // Custom conductor cmd
            let a2 = NSAlert()
            a2.messageText = "Custom conductor command"
            a2.informativeText = "Shell command for the conductor TUI (e.g. grok, hermes chat)."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = "grok"
            a2.accessoryView = field
            a2.addButton(withTitle: "Use")
            a2.addButton(withTitle: "Cancel")
            guard a2.runModal() == .alertFirstButtonReturn else { return nil }
            let cmd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.isEmpty { return nil }
            conductor = ConductorType(id: "custom", label: cmd, cmd: cmd, recommended: false)
        } else if !saved.isEmpty && idx == fixed.count + 1 {
            TeamsManagerPanel.shared.show { PanelController.shared.refreshUI() }
            return nil
        } else {
            return nil
        }

        let gate = NSAlert()
        gate.messageText = "Staff workers"
        gate.informativeText = "Conductor: \(conductor.label)\nAdd workers under this team (implementers)."
        gate.addButton(withTitle: "Claude")
        gate.addButton(withTitle: "Other Model")
        gate.addButton(withTitle: "Team")
        gate.addButton(withTitle: "Cancel")
        let g = gate.runModal()
        let gf = NSApplication.ModalResponse.alertFirstButtonReturn
        if g == gf {
            return (conductor, [WorkerType.resolved("claude")])
        }
        if g == NSApplication.ModalResponse(rawValue: gf.rawValue + 1) {
            guard let ws = TeamBuilderPanel.run(mode: .oneModel) else { return nil }
            return (conductor, ws)
        }
        if g == NSApplication.ModalResponse(rawValue: gf.rawValue + 2) {
            guard let ws = TeamBuilderPanel.run(mode: .team) else { return nil }
            return (conductor, ws)
        }
        return nil
    }

    /// New pair worker selection (legacy helper).
    static func pickWorkerTypes() -> [WorkerType]? {
        pickTeamLaunch()?.1
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
            a.informativeText = "Open an Active pair → Options on the Hermes row (Save Team lives inside)."
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

// MARK: - Team activity (read session bridge artifacts; no stream window)

/// Team-level status derived from sessions/<session>/last-{sent,claude}.txt
/// mtimes and the CLAIM tail. Read-only file peeking on panel refresh; the
/// bridge remains the only handoff path and nothing streams live tokens.
enum TeamActivity {
    struct Info {
        let status: String      // "Working" | "Done" | "Idle"
        let claim: String       // notes: else files: line of the last CLAIM, or ""
        let sentAge: String     // "2m ago" or ""
        let replyPath: String
        let sentPath: String
    }

    /// STRICTLY session-scoped. No fallback to the global last-*.txt: those
    /// mirror whichever session is active, so reading them here would show
    /// pair A's status/claim under pair B. Missing file = no activity yet.
    static func sessionFile(_ session: String, _ name: String) -> String {
        Pong.stateDir + "/sessions/\(session)/\(name)"
    }

    static func info(for session: String) -> Info {
        let replyPath = sessionFile(session, "last-claude.txt")
        let sentPath = sessionFile(session, "last-sent.txt")
        func mtime(_ p: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        }
        let replyM = mtime(replyPath)
        let sentM = mtime(sentPath)
        let tail = tailOfFile(replyPath, maxBytes: 4096)
        let hasMarker = tail.contains("##CLAUDE_DONE##") || tail.contains("##WORKER_DONE##")
        var status = "Idle"
        if let s = sentM, s > (replyM ?? .distantPast) {
            status = "Working" // handoff in flight, no reply captured since
        } else if replyM != nil, hasMarker {
            status = "Done"
        }
        return Info(status: status, claim: claimLine(from: tail),
                    sentAge: age(sentM), replyPath: replyPath, sentPath: sentPath)
    }

    /// Last `notes:` line of the CLAIM tail, else `files:`, truncated to 80.
    static func claimLine(from tail: String) -> String {
        var files = "", notes = ""
        for raw in tail.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("notes:") {
                notes = String(line.dropFirst("notes:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("files:") {
                files = String(line.dropFirst("files:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        var out = notes.isEmpty ? files : notes
        if out.count > 80 { out = String(out.prefix(80)) + "…" }
        return out
    }

    static func tailOfFile(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func age(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

// MARK: - Reply viewer (native, scrollable; opened by the user, never auto)

/// Read-only view of a session's last-claude/last-sent file. Deliberately not
/// a stream: it loads a file on demand, refresh is manual.
final class ReplyViewerController: NSObject, NSWindowDelegate {
    static let shared = ReplyViewerController()
    enum Kind { case reply, sent }

    private var window: NSWindow?
    private var textView: NSTextView!
    private var pathLabel: NSTextField!
    private var session = ""
    private var kind: Kind = .reply
    private var currentPath = ""

    func show(session: String, kind: Kind) {
        self.session = session
        self.kind = kind
        if window == nil { buildWindow() }
        loadContent()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let W: CGFloat = 680, H: CGFloat = 480
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 78, width: W - 24, height: H - 90))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height))
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 14, y: 56, width: W - 28, height: 16)
        pathLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(pathLabel)

        func makeButton(_ title: String, _ sel: Selector, _ frame: NSRect) -> NSButton {
            let b = NSButton(frame: frame)
            b.title = title
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
            b.autoresizingMask = [.minYMargin]
            return b
        }
        content.addSubview(makeButton("Refresh", #selector(refreshPressed),
            NSRect(x: 12, y: 16, width: 92, height: 30)))
        content.addSubview(makeButton("Reveal in Finder", #selector(revealPressed),
            NSRect(x: 112, y: 16, width: 132, height: 30)))
        let close = makeButton("Close", #selector(closePressed),
            NSRect(x: W - 104, y: 16, width: 92, height: 30))
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.keyEquivalent = "\u{1b}"
        content.addSubview(close)

        win.contentView = content
        window = win
    }

    private func loadContent() {
        let file = kind == .reply ? "last-claude.txt" : "last-sent.txt"
        let p = TeamActivity.sessionFile(session, file)
        currentPath = p
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let display = ((entry["display_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let who = display.isEmpty ? session : display
        window?.title = "\(kind == .reply ? "Reply" : "Sent") · \(who) · team"
        pathLabel.stringValue = p
        // Session file only — never fall back to the global mirror, which can
        // hold ANOTHER pair's traffic. Missing file = clean empty state.
        var text: String
        if let content = try? String(contentsOfFile: p, encoding: .utf8) {
            text = content
            let cap = 1_500_000
            if text.utf8.count > cap {
                text = "(file is large; showing the last 1.5MB)\n\n" + String(text.suffix(cap))
            }
        } else {
            text = kind == .reply
                ? "No reply yet for this pair."
                : "No handoff sent yet for this pair."
        }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func refreshPressed() { loadContent() }

    @objc private func revealPressed() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
    }

    @objc private func closePressed() { window?.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {
        // isReleasedWhenClosed = false
    }
}

// PanelController lives in PanelController.swift (modern SuperGrok-inspired UI)

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
        let H: CGFloat = mode == .oneModel ? 420 : 620
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

        // Saved teams FIRST (team mode) so Load is obvious
        if mode == .team {
            let saved = SavedTeams.loadAll()
            if !saved.isEmpty {
                y -= 18
                let sh = NSTextField(labelWithString: "LOAD SAVED TEAM")
                sh.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
                sh.textColor = NSColor(calibratedRed: 0.45, green: 0.7, blue: 1.0, alpha: 1)
                sh.frame = NSRect(x: 20, y: y, width: W - 40, height: 14)
                content.addSubview(sh)
                for t in saved.prefix(8) {
                    y -= 36
                    let b = NSButton(frame: NSRect(x: 20, y: y, width: W - 40, height: 32))
                    b.title = "Load  \(t.name)  (\(t.workers.count) workers)"
                    b.bezelStyle = .rounded
                    b.target = self
                    b.action = #selector(spawnSaved(_:))
                    b.identifier = NSUserInterfaceItemIdentifier(t.id)
                    content.addSubview(b)
                }
                y -= 12
                let div = NSTextField(labelWithString: "— or build a new team —")
                div.font = NSFont.systemFont(ofSize: 10)
                div.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
                div.alignment = .center
                div.frame = NSRect(x: 20, y: y, width: W - 40, height: 14)
                content.addSubview(div)
            } else {
                y -= 18
                let sh = NSTextField(labelWithString: "No saved teams yet. Options on an Active pair, then Save team.")
                sh.font = NSFont.systemFont(ofSize: 10)
                sh.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
                sh.frame = NSRect(x: 20, y: y, width: W - 40, height: 14)
                content.addSubview(sh)
            }
        }

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
        let hint = NSTextField(labelWithString: "Background · Text · Marker (bold/cursor).")
        hint.frame = NSRect(x: 24, y: y, width: W - 48, height: 18)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        hint.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(hint)
        y -= 40
        bgWell = row("Background", y: y)
        y -= 40
        textWell = row("Text", y: y)
        y -= 40
        hiWell = row("Marker", y: y)

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




/// AppKit y-up is awkward for lists — flipped views lay out top→bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Show Teams manager

final class TeamsManagerPanel: NSObject {
    static let shared = TeamsManagerPanel()
    private var window: NSWindow?
    private var scrollView: NSScrollView!
    private var listBox: FlippedView!
    private var onChange: (() -> Void)?
    private let winW: CGFloat = 420
    private let winH: CGFloat = 520
    private let footerH: CGFloat = 52
    private let headerH: CGFloat = 72

    func show(onChange: (() -> Void)? = nil) {
        self.onChange = onChange
        if window == nil { build() }
        rebuildList()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let W = winW, H = winH
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Saved teams"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // Header (fixed)
        let title = NSTextField(labelWithString: "Teams")
        title.font = .boldSystemFont(ofSize: 16)
        title.textColor = .white
        title.frame = NSRect(x: 20, y: H - 40, width: 200, height: 22)
        content.addSubview(title)

        let hint = NSTextField(labelWithString: "Click a team to open. Duplicate / Delete on the right.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        hint.frame = NSRect(x: 20, y: H - 58, width: W - 40, height: 16)
        content.addSubview(hint)

        // Scroll region between header and sticky footer
        let scrollY = footerH
        let scrollH = H - headerH - footerH
        scrollView = NSScrollView(frame: NSRect(x: 16, y: scrollY, width: W - 32, height: scrollH))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false

        listBox = FlippedView(frame: NSRect(x: 0, y: 0, width: W - 32, height: scrollH))
        scrollView.documentView = listBox
        content.addSubview(scrollView)

        // Sticky footer — always above scroll content
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: W, height: footerH))
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor
        let close = NSButton(frame: NSRect(x: W - 100, y: 12, width: 80, height: 30))
        close.title = "Close"
        close.bezelStyle = .rounded
        close.target = self
        close.action = #selector(closePressed)
        footer.addSubview(close)
        content.addSubview(footer)

        win.contentView = content
        window = win
    }

    private func rebuildList() {
        listBox.subviews.forEach { $0.removeFromSuperview() }
        let teams = SavedTeams.loadAll()
        let rowH: CGFloat = 52
        let gap: CGFloat = 8
        let pad: CGFloat = 8
        let width = max(scrollView.contentSize.width, winW - 32)

        if teams.isEmpty {
            let h = max(scrollView.contentSize.height, 200)
            listBox.setFrameSize(NSSize(width: width, height: h))
            let empty = NSTextField(labelWithString: "No saved teams yet.\nOptions on an Active pair Hermes row, then Save team.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
            empty.alignment = .center
            empty.maximumNumberOfLines = 3
            empty.frame = NSRect(x: 10, y: 40, width: width - 20, height: 60)
            listBox.addSubview(empty)
            return
        }

        let contentH = pad + CGFloat(teams.count) * (rowH + gap) + pad
        let minH = max(scrollView.contentSize.height, 100)
        listBox.setFrameSize(NSSize(width: width, height: max(contentH, minH)))

        var y = pad
        for t in teams {
            let row = NSView(frame: NSRect(x: 4, y: y, width: width - 8, height: rowH))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
            row.layer?.cornerRadius = 8

            let nameBtn = NSButton(frame: NSRect(x: 10, y: 11, width: max(140, width - 200), height: 30))
            nameBtn.title = "\(t.name)  (\(t.workers.count))"
            nameBtn.bezelStyle = .inline
            nameBtn.isBordered = false
            nameBtn.alignment = .left
            nameBtn.font = .boldSystemFont(ofSize: 12)
            nameBtn.contentTintColor = NSColor(calibratedWhite: 0.95, alpha: 1)
            nameBtn.target = self
            nameBtn.action = #selector(openPressed(_:))
            nameBtn.identifier = NSUserInterfaceItemIdentifier(t.id)
            nameBtn.toolTip = "Open / launch this team"
            row.addSubview(nameBtn)

            let del = smallBtn("Delete", #selector(deletePressed(_:)),
                               NSRect(x: width - 80, y: 13, width: 64, height: 26), t.id)
            let dup = smallBtn("Duplicate", #selector(dupPressed(_:)),
                               NSRect(x: width - 176, y: 13, width: 88, height: 26), t.id)
            row.addSubview(dup)
            row.addSubview(del)
            listBox.addSubview(row)
            y += rowH + gap
        }

        // Start at top of flipped view
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func smallBtn(_ title: String, _ sel: Selector, _ frame: NSRect, _ id: String) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        b.target = self
        b.action = sel
        b.identifier = NSUserInterfaceItemIdentifier(id)
        return b
    }

    @objc private func openPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let team = SavedTeams.loadAll().first(where: { $0.id == id }) else { return }
        window?.orderOut(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SavedTeams.spawn(team)
            DispatchQueue.main.async {
                self.onChange?()
                PanelController.shared.refreshUI()
            }
        }
    }

    @objc private func dupPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        _ = SavedTeams.duplicate(id: id)
        rebuildList()
        onChange?()
    }

    @objc private func deletePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let team = SavedTeams.loadAll().first(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(team.name)”?"
        a.informativeText = "This only removes the saved pack. Running pairs are untouched."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SavedTeams.delete(id: id)
        rebuildList()
        onChange?()
        // If last team gone, close manager
        if SavedTeams.loadAll().isEmpty {
            window?.orderOut(nil)
        }
    }

    @objc private func closePressed() {
        window?.orderOut(nil)
        onChange?()
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
    private var fullPresetBtn: NSButton!
    private var askPresetBtn: NSButton!
    private var selectedPresetId: String? = nil  // "full" | "ask_each" | user id | nil

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
        fullPresetBtn = makeButton("Full access", #selector(applyFullPreset),
            NSRect(x: x, y: y - btnH, width: fullW, height: btnH))
        content.addSubview(fullPresetBtn)
        x += fullW + gap
        askPresetBtn = makeButton("Ask each time", #selector(applyAskPreset),
            NSRect(x: x, y: y - btnH, width: askW, height: btnH))
        content.addSubview(askPresetBtn)
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

    private func applyPermissionsToUI(_ perms: [String: Any], status: String, presetId: String? = nil) {
        var merged = PairState.defaultPermissions()
        for (k, v) in perms { merged[k] = v }
        for (key, box) in boxes {
            box.state = ((merged[key] as? Bool) == true) ? .on : .off
        }
        noteView?.string = (merged["custom_prompt"] as? String) ?? ""
        presetStatus?.stringValue = status
        if let presetId {
            selectedPresetId = presetId
        } else if permissionsEqual(merged, PairState.fullAccessPermissions()) {
            selectedPresetId = "full"
        } else if permissionsEqual(merged, PairState.askEachPermissions()) {
            selectedPresetId = "ask_each"
        } else {
            // keep explicit id if status starts with Saved:
            if status.hasPrefix("Saved:") || status.hasPrefix("Preset:") {
                // leave selectedPresetId if caller set via presetId
            } else {
                selectedPresetId = nil
            }
        }
        if presetId != nil {
            selectedPresetId = presetId
        }
        highlightPresetButtons()
    }

    private func highlightPresetButtons() {
        stylePreset(fullPresetBtn, on: selectedPresetId == "full")
        stylePreset(askPresetBtn, on: selectedPresetId == "ask_each")
    }

    private func stylePreset(_ btn: NSButton?, on: Bool) {
        guard let btn else { return }
        btn.wantsLayer = true
        if on {
            btn.bezelColor = NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.95, alpha: 1)
            btn.contentTintColor = .white
            btn.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.92, alpha: 0.95).cgColor
            btn.layer?.cornerRadius = 6
            btn.font = .boldSystemFont(ofSize: 12)
        } else {
            btn.bezelColor = nil
            btn.contentTintColor = nil
            btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
            btn.layer?.cornerRadius = 6
            btn.font = .systemFont(ofSize: 12)
        }
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
        selectedPresetId = nil
        highlightPresetButtons()
    }

    func textDidChange(_ notification: Notification) {
        presetStatus?.stringValue = "Custom for this pair"
        selectedPresetId = nil
        highlightPresetButtons()
    }

    @objc private func applyFullPreset() {
        applyPermissionsToUI(PairState.fullAccessPermissions(), status: "Preset: Full access", presetId: "full")
    }

    @objc private func applyAskPreset() {
        applyPermissionsToUI(PairState.askEachPermissions(), status: "Preset: Ask each time", presetId: "ask_each")
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
            applyPermissionsToUI(item.permissions, status: "Saved: \(item.name)", presetId: item.id)
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
        applyPermissionsToUI(PairState.defaultPermissions(), status: "Custom for this pair", presetId: nil)
        selectedPresetId = nil
        highlightPresetButtons()
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

// MARK: - Team options sheet (display name · project root · team brief · Save team)

/// Options on the Hermes row. Save Team lives here now, next to the Task-1
/// project settings: a per-pair project root and team brief that the bridge
/// injects on every handoff so pairs on different projects cannot bleed.
final class TeamOptionsSheetController: NSObject, NSWindowDelegate {
    static let shared = TeamOptionsSheetController()

    private var window: NSWindow?
    private var pairName = ""
    private var onSaved: (() -> Void)?
    private var nameField: NSTextField!
    private var rootField: NSTextField!
    private var briefView: NSTextView!
    private var boundLabel: NSTextField!

    func show(for pair: String, onSaved: @escaping () -> Void) {
        self.pairName = pair
        self.onSaved = onSaved
        if window == nil { buildWindow() }
        loadIntoUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless() // above the control panel, always
    }

    private func buildWindow() {
        let W: CGFloat = 460, H: CGFloat = 660
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Team options"
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
        win.delegate = self
        win.level = .floating

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let PAD: CGFloat = 22
        var y = H - PAD - 8

        let title = NSTextField(labelWithString: "Team options")
        title.font = .boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: PAD, y: y - 20, width: W - 2 * PAD, height: 22)
        content.addSubview(title)
        y -= 34

        let nameLbl = NSTextField(labelWithString: "Display name")
        nameLbl.font = .systemFont(ofSize: 11)
        nameLbl.textColor = .secondaryLabelColor
        nameLbl.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(nameLbl)
        y -= 20
        nameField = NSTextField(frame: NSRect(x: PAD, y: y - 24, width: W - 2 * PAD, height: 24))
        nameField.placeholderString = "Shown in the panel and Terminal titles"
        nameField.font = .systemFont(ofSize: 13)
        content.addSubview(nameField)
        y -= 34

        let rootLbl = NSTextField(labelWithString: "Project root")
        rootLbl.font = .systemFont(ofSize: 11)
        rootLbl.textColor = .secondaryLabelColor
        rootLbl.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(rootLbl)
        y -= 20
        let chooseW: CGFloat = 86
        rootField = NSTextField(frame: NSRect(x: PAD, y: y - 24, width: W - 2 * PAD - chooseW - 8, height: 24))
        rootField.placeholderString = "/absolute/path/to/repo (empty = unset)"
        rootField.font = .systemFont(ofSize: 13)
        content.addSubview(rootField)
        content.addSubview(makeButton("Choose…", #selector(choosePressed),
            NSRect(x: W - PAD - chooseW, y: y - 26, width: chooseW, height: 28)))
        y -= 32
        let rootHelp = NSTextField(wrappingLabelWithString:
            "All handoffs tell workers to stay in this folder. Different pairs = different projects.")
        rootHelp.font = .systemFont(ofSize: 11)
        rootHelp.textColor = .secondaryLabelColor
        rootHelp.frame = NSRect(x: PAD, y: y - 28, width: W - 2 * PAD, height: 28)
        content.addSubview(rootHelp)
        y -= 36

        let briefLbl = NSTextField(labelWithString: "Team brief")
        briefLbl.font = .systemFont(ofSize: 11)
        briefLbl.textColor = .secondaryLabelColor
        briefLbl.frame = NSRect(x: PAD, y: y - 16, width: W - 2 * PAD, height: 16)
        content.addSubview(briefLbl)
        y -= 20
        let briefH: CGFloat = 150
        let scroll = NSScrollView(frame: NSRect(x: PAD, y: y - briefH, width: W - 2 * PAD, height: briefH))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: briefH))
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.isEditable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        content.addSubview(scroll)
        briefView = tv
        y -= briefH + 6
        let briefHelp = NSTextField(wrappingLabelWithString:
            "Injected at the top of every handoff for this pair only. What this team is building, constraints, definition of done.\n" +
            "Example: This team builds App X only. Repo: ~/src/app-x. Never touch other projects' repos.")
        briefHelp.font = .systemFont(ofSize: 11)
        briefHelp.textColor = .secondaryLabelColor
        briefHelp.frame = NSRect(x: PAD, y: y - 58, width: W - 2 * PAD, height: 58)
        content.addSubview(briefHelp)
        y -= 66

        boundLabel = NSTextField(wrappingLabelWithString: "")
        boundLabel.font = .systemFont(ofSize: 11)
        boundLabel.textColor = .secondaryLabelColor
        boundLabel.frame = NSRect(x: PAD, y: y - 28, width: W - 2 * PAD, height: 28)
        content.addSubview(boundLabel)
        y -= 36

        let winLbl = NSTextField(labelWithString: "WINDOWS")
        winLbl.font = .systemFont(ofSize: 10)
        winLbl.textColor = .secondaryLabelColor
        winLbl.frame = NSRect(x: PAD, y: y - 14, width: 120, height: 14)
        content.addSubview(winLbl)
        y -= 20
        content.addSubview(makeButton("Hide team windows", #selector(hideWindowsPressed),
            NSRect(x: PAD, y: y - 28, width: 152, height: 28)))
        content.addSubview(makeButton("Show team windows", #selector(showWindowsPressed),
            NSRect(x: PAD + 160, y: y - 28, width: 156, height: 28)))
        y -= 34
        content.addSubview(makeButton("Focus this team", #selector(focusTeamPressed),
            NSRect(x: PAD, y: y - 28, width: 152, height: 28)))
        y -= 34
        let winHelp = NSTextField(wrappingLabelWithString:
            "Hides Terminal windows only. Pair and tmux keep running. Bridge still works. Focus stows every other pair, then shows this one.")
        winHelp.font = .systemFont(ofSize: 11)
        winHelp.textColor = .secondaryLabelColor
        winHelp.frame = NSRect(x: PAD, y: y - 28, width: W - 2 * PAD, height: 28)
        content.addSubview(winHelp)

        content.addSubview(makeButton("Save team…", #selector(saveTeamPressed),
            NSRect(x: PAD, y: 18, width: 108, height: 32)))
        let cancel = makeButton("Cancel", #selector(cancelPressed),
            NSRect(x: W - PAD - 196, y: 18, width: 92, height: 32))
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        let done = makeButton("Done", #selector(donePressed),
            NSRect(x: W - PAD - 96, y: 18, width: 96, height: 32))
        done.keyEquivalent = "\r"
        content.addSubview(done)

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

    private func loadIntoUI() {
        let entry = PairState.loadPairsDb()[pairName] as? [String: Any] ?? [:]
        let display = ((entry["display_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        window?.title = "Team options · \(display.isEmpty ? pairName : display)"
        nameField.stringValue = display
        rootField.stringValue = (entry["project_root"] as? String) ?? ""
        briefView.string = (entry["team_brief"] as? String) ?? ""
        boundLabel.stringValue = "Bound session: \(pairName). Workers cannot see other pairs."
    }

    /// Write the sheet fields onto the live pair (pairs.json + active-pair.json
    /// when this session is active) and mirror the brief file.
    private func persistFields() {
        Workers.setTeamOptions(pairName,
                               displayName: nameField.stringValue,
                               projectRoot: rootField.stringValue,
                               teamBrief: briefView.string)
    }

    @objc private func choosePressed() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let cur = rootField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cur.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (cur as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            rootField.stringValue = url.path
        }
    }

    @objc private func saveTeamPressed() {
        persistFields() // snapshot includes what's on screen right now
        let suggestion = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = suggestion.isEmpty ? pairName : suggestion
        let alert = NSAlert()
        alert.messageText = "Save team as…"
        alert.informativeText = "Reusable under Show Teams: workers, names, colors, perms, project root, and team brief."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = seed
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let a = NSAlert()
        if SavedTeams.saveFromLivePair(pairName, teamName: name) != nil {
            a.messageText = "Team saved"
            a.informativeText =
                "“\(name)” is under Show Teams…\n" +
                "Includes workers, names, colors, per-worker perms, project root, and team brief."
        } else {
            a.messageText = "Nothing to save"
            a.informativeText = "This pair has no workers yet."
        }
        a.addButton(withTitle: "OK")
        a.runModal()
        onSaved?()
    }

    @objc private func hideWindowsPressed() {
        let pair = pairName
        DispatchQueue.global(qos: .userInitiated).async {
            Pairing.stow(pair)
            DispatchQueue.main.async { self.onSaved?() }
        }
    }

    @objc private func showWindowsPressed() {
        let pair = pairName
        DispatchQueue.global(qos: .userInitiated).async {
            Pairing.unstow(pair)
            DispatchQueue.main.async { self.onSaved?() }
        }
    }

    @objc private func focusTeamPressed() {
        let pair = pairName
        DispatchQueue.global(qos: .userInitiated).async {
            Pairing.focusTeam(pair)
            DispatchQueue.main.async { self.onSaved?() }
        }
    }

    @objc private func donePressed() {
        persistFields()
        window?.orderOut(nil)
        onSaved?()
    }

    @objc private func cancelPressed() {
        window?.orderOut(nil)
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
        win.title = "Pong — Link team"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bgElevated

        let content = NSView(frame: NSRect(x: 0, y: 0, width: GW, height: GH))
        content.wantsLayer = true
        content.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        stepLabel = PanelController.label("Step 1",
            frame: NSRect(x: 16, y: GH - 36, width: GW - 32, height: 18), size: 11, secondary: true)
        titleLabel = PanelController.label("Click the Orchestrator Terminal",
            frame: NSRect(x: 16, y: GH - 68, width: GW - 32, height: 28), bold: true, size: 15)
        hermesMark = PanelController.label("○  Orchestrator  —  not selected",
            frame: NSRect(x: 16, y: GH - 110, width: GW - 32, height: 22), size: 13)
        workersMark = PanelController.label("○  Workers  —  none yet",
            frame: NSRect(x: 16, y: GH - 168, width: GW - 32, height: 48), size: 12)
        workersMark.maximumNumberOfLines = 4
        hintLabel = PanelController.label(
            "First: orchestrator (Grok / Hermes / …). Then workers.",
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
            stepLabel.stringValue = "Step 1 — Orchestrator"
            titleLabel.stringValue = "Click the Orchestrator Terminal"
            hintLabel.stringValue = "Grok Build, Hermes, Claude — whichever leads the team. Then add workers."
            doneBtn.isHidden = true
        case .workers:
            stepLabel.stringValue = "Step 2 — Workers (\(workerIds.count))"
            titleLabel.stringValue = workerIds.isEmpty
                ? "Click a worker Terminal"
                : "Add another worker, or Done"
            hintLabel.stringValue = "Claude, Codex, Kimi, Grok worker…\nPress Done when the team is complete."
            doneBtn.isHidden = workerIds.isEmpty
            doneBtn.isEnabled = !workerIds.isEmpty
            doneBtn.title = "Done (\(workerIds.count))"
        case .wiring:
            stepLabel.stringValue = "Linking…"
            titleLabel.stringValue = "Registering windows"
            hintLabel.stringValue = "Workers keep their sessions — nothing injected into TUIs."
            doneBtn.isHidden = true
        case .done:
            stepLabel.stringValue = "Done"
            titleLabel.stringValue = "Team linked"
            hintLabel.stringValue = "Arrange on Canvas · jobs via pong job create"
            doneBtn.isHidden = true
        case .idle:
            break
        }
        hermesMark.stringValue = hermesId != nil
            ? "✓  Orchestrator  —  \(titleFor(hermesId))" : "○  Orchestrator  —  not selected"
        if workerIds.isEmpty {
            workersMark.stringValue = "○  Workers  —  none yet"
        } else {
            let lines = workerIds.enumerated().map { i, id in
                "✓  w\(i + 1)  —  \(titleFor(id))"
            }
            workersMark.stringValue = lines.joined(separator: "\n")
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
                hintLabel.stringValue = "That’s the orchestrator. Click a worker Terminal."
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
            Pong.log("selected ORCHESTRATOR id=\(wid)")
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

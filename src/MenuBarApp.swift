import AppKit
import Foundation

/// CyberPong — menu bar icon + control panel.
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
    /// CLI tools for Guide headless + agent panes (Dock-launched apps get a bare PATH).
    static var extraPath: String {
        let home = NSHomeDirectory()
        return [
            "\(home)/.grok/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/bin",
        ].joined(separator: ":")
    }

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

// MARK: - Cross-team isolation helpers (Addendum 2)

enum Isolation {
    /// PYTHONPATH root that contains the `pong` package.
    /// Prefer installed control plane (`~/.pong/lib`); never the stale `~/src/Agent-Pong` tree.
    static var pythonPath: String {
        // Prefer bundle (self-contained zip) → installed lib → optional dev checkout
        let home = NSHomeDirectory()
        var candidates: [String] = [
            Bundle.main.resourcePath.map { $0 + "/python" } ?? "",
            home + "/.pong/lib",
        ]
        // Dev only — avoid baking Personal/Projects into release Mach-O
        let dev = home + "/Personal/Projects/HermesPong/python"
        if FileManager.default.fileExists(atPath: dev + "/pong/__init__.py") {
            candidates.append(dev)
        }
        for c in candidates where !c.isEmpty {
            if FileManager.default.fileExists(atPath: c + "/pong")
                || FileManager.default.fileExists(atPath: c + "/pong/__init__.py") {
                return c
            }
        }
        return Bundle.main.resourcePath.map { $0 + "/python" } ?? (home + "/.pong/lib")
    }

    /// Seed `~/.pong/lib/pong` from the app bundle on first run (fresh zip installs).
    static func seedControlPlaneIfNeeded() {
        let dest = NSHomeDirectory() + "/.pong/lib"
        let destPkg = dest + "/pong"
        let src = Bundle.main.resourcePath.map { $0 + "/python/pong" } ?? ""
        guard !src.isEmpty, FileManager.default.fileExists(atPath: src) else { return }
        // Refresh if missing or older than bundle package
        let need: Bool = {
            if !FileManager.default.fileExists(atPath: destPkg + "/__init__.py") { return true }
            // Always ensure __init__ exists
            return false
        }()
        guard need else { return }
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: destPkg)
        do {
            try FileManager.default.copyItem(atPath: src, toPath: destPkg)
            Pong.log("Isolation seeded control plane → \(destPkg)")
        } catch {
            Pong.log("Isolation seed failed: \(error)")
        }
    }

    /// Create/read per-session token; returns token string (empty on failure).
    static func ensureToken(session: String) -> String {
        let safe = session.replacingOccurrences(of: "'", with: "")
        let py = "import sys; sys.path.insert(0, '\(pythonPath)'); from pong.routing import ensure_session_token; print(ensure_session_token('\(safe)'), end='')"
        let out = Pong.sh("python3 -c \(shellQuote(py))")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Register immutable tmux pane id for a seat; returns pane_id.
    @discardableResult
    static func registerPane(session: String, workerId: String, tmuxTarget: String, startCommand: String) -> String {
        let paneId = Pong.sh("tmux display-message -p -t \(tmuxTarget) '#{pane_id}' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneId.isEmpty else {
            Pong.log("isolation pane register miss target=\(tmuxTarget)")
            return ""
        }
        let title = TerminalTheme.exactSeatTitle(pair: session, seat: workerId)
        let safeSess = session.replacingOccurrences(of: "'", with: "")
        let safeW = workerId.replacingOccurrences(of: "'", with: "")
        let safePane = paneId.replacingOccurrences(of: "'", with: "")
        let safeTitle = title.replacingOccurrences(of: "'", with: "")
        let safeCmd = startCommand.replacingOccurrences(of: "'", with: "")
        let py = "import sys; sys.path.insert(0, '\(pythonPath)'); from pong.routing import register_worker_pane; register_worker_pane('\(safeSess)', '\(safeW)', pane_id='\(safePane)', start_command='\(safeCmd)', title='\(safeTitle)')"
        _ = Pong.sh("python3 -c \(shellQuote(py))")
        // Also pin pane title in tmux
        _ = Pong.sh("tmux select-pane -t \(tmuxTarget) -T '\(safeTitle)' 2>/dev/null || true")
        Pong.log("isolation pane register session=\(session) seat=\(workerId) pane=\(paneId)")
        return paneId
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Pair state (contracts identical to the Python panel)

enum PairState {
    static var pairsPath: String { Pong.stateDir + "/pairs.json" }
    static var activePath: String { Pong.stateDir + "/active-pair.json" }
    static var settingsPath: String { Pong.stateDir + "/settings.json" }

    static func isPairName(_ s: String) -> Bool {
        // View sessions are not pairs (conductor view, legacy Claude view, worker views).
        // Subagent/worker attach sessions must never appear as whole teams.
        if s.hasSuffix("-h") || s.hasSuffix("-c") { return false }
        // *-w0 / *-w2 — worker view sessions
        if s.range(of: #"-w\d+$"#, options: .regularExpression) != nil { return false }
        // Never treat map preview / synthetic ids as teams
        if s == "preview" || s.hasPrefix("preview-") { return false }
        return s == "pong-team" || s.hasPrefix("pong-team-")
            || s == "hermes-claude" || s.hasPrefix("hermes-claude-")
            || s == "hermes-pair" || s.hasPrefix("hermes-pair-")
    }

    static func loadPairsDb() -> [String: Any] { Pong.loadJSON(pairsPath) }

    /// Cached **visible** pair names — never shell `tmux` on the main-thread hot path.
    private static var pairsCache: [String] = []
    private static var pairsCacheAt: TimeInterval = 0
    private static var pairsRefreshInFlight = false
    private static var lastPruneAt: TimeInterval = 0

    /// Teams shown in the switcher / map: live tmux **or** intentionally stowed.
    /// Ghost `pairs.json` keys (no tmux, not stowed) are pruned off the main thread.
    static func listPairs() -> [String] {
        let now = Date().timeIntervalSince1970
        if now - pairsCacheAt > 4.0 || pairsCache.isEmpty {
            refreshPairsCacheAsync()
        }
        if !pairsCache.isEmpty {
            return pairsCache
        }
        // File-only fallback until async refresh lands: skip hollow non-stowed tombs
        return loadPairsDb().keys
            .filter { isPairName($0) && isReasonableDbEntry($0) }
            .sorted()
    }

    /// Alias — same as `listPairs` (visible live/stowed only after refresh).
    static func listLivePairs() -> [String] { listPairs() }

    /// Count for status chip — file only, no subprocess; excludes hollow tombs.
    static func pairCountFromDb() -> Int {
        loadPairsDb().keys.filter { isPairName($0) && isReasonableDbEntry($0) }.count
    }

    /// Entry has conductor and/or workers, or is stowed (intentionally kept).
    private static func isReasonableDbEntry(_ name: String) -> Bool {
        guard let entry = loadPairsDb()[name] as? [String: Any] else { return false }
        if (entry["stowed"] as? Bool) == true { return true }
        return !isHollowPairEntry(entry)
    }

    /// No conductor identity and no workers — half-created / cancelled setup residue.
    static func isHollowPairEntry(_ entry: [String: Any]) -> Bool {
        let workers = Workers.list(from: entry)
        if !workers.isEmpty { return false }
        guard let cond = entry["conductor"] as? [String: Any] else { return true }
        let typ = ((cond["type"] as? String) ?? (cond["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = ((cond["cmd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lab = ((cond["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typ.isEmpty && cmd.isEmpty && lab.isEmpty
    }

    private static func tmuxSessionNames() -> Set<String> {
        let out = Pong.sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        return Set(out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    private static func refreshPairsCacheAsync() {
        guard !pairsRefreshInFlight else { return }
        pairsRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let tmuxAll = tmuxSessionNames()
            let tmuxPairs = Set(tmuxAll.filter { isPairName($0) })
            var db = loadPairsDb()
            var dbChanged = false
            let now = Date().timeIntervalSince1970
            // Prune at most every 8s
            let doPrune = now - lastPruneAt > 8.0
            if doPrune { lastPruneAt = now }

            var visible = Set<String>()

            // DB entries: keep stowed always; keep live tmux; prune dead ghosts
            for key in db.keys where isPairName(key) {
                let entry = db[key] as? [String: Any] ?? [:]
                let stowed = (entry["stowed"] as? Bool) == true
                let live = tmuxPairs.contains(key)
                if stowed {
                    visible.insert(key)
                    continue
                }
                if live {
                    // Hollow + live: allow briefly during create; drop if stale hollow
                    if isHollowPairEntry(entry) {
                        let updated = (entry["updated"] as? Double) ?? (entry["created"] as? Double) ?? now
                        if now - updated > 120 {
                            if doPrune {
                                db.removeValue(forKey: key)
                                dbChanged = true
                                Pong.log("ghost-team-pruned session=\(key) reason=hollow-stale")
                            }
                            continue
                        }
                    }
                    visible.insert(key)
                    continue
                }
                // No tmux, not stowed → ghost tombstone
                if doPrune {
                    db.removeValue(forKey: key)
                    dbChanged = true
                    Pong.log("ghost-team-pruned session=\(key) reason=no-tmux")
                }
            }

            // Live tmux pair sessions not yet in DB (mid-create) still show
            for name in tmuxPairs {
                if visible.contains(name) { continue }
                if let entry = db[name] as? [String: Any], isHollowPairEntry(entry) {
                    let updated = (entry["updated"] as? Double) ?? now
                    if now - updated > 120 { continue }
                }
                visible.insert(name)
            }

            if dbChanged {
                Pong.writeJSON(pairsPath, db)
            }

            let sorted = visible.sorted()
            DispatchQueue.main.async {
                pairsCache = sorted
                pairsCacheAt = Date().timeIntervalSince1970
                pairsRefreshInFlight = false
            }
        }
    }

    /// Force a ghost prune + cache rebuild (call after kill team / failed create).
    static func invalidatePairsCache() {
        pairsCacheAt = 0
        pairsCache = []
        refreshPairsCacheAsync()
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
        // Control plane lives at ~/.pong/lib (setup.sh); ~/bin/hermes_pong.py is the install shim.
        Pong.sh("python3 \"$HOME/bin/hermes_pong.py\" write-bind --session \(session) >/dev/null 2>&1 || "
            + "PYTHONPATH=\"$HOME/.pong/lib${PYTHONPATH:+:$PYTHONPATH}\" python3 -m pong.cli status -s \(session) >/dev/null 2>&1 || true")
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

// MARK: - Worker types (agent seats — same CLIs as conductors where useful)

/// Built-in worker seeds. User signs into each CLI themselves; we only launch the cmd.
/// Hermes is valid as an **agent** too (not only orchestrator).
struct WorkerType: Equatable {
    let id: String
    let label: String
    let cmd: String
    let tmuxWindowName: String

    static let all: [WorkerType] = [
        WorkerType(id: "claude", label: "Claude Code", cmd: "claude", tmuxWindowName: "Worker"),
        WorkerType(id: "hermes", label: "Hermes Agent", cmd: "hermes chat", tmuxWindowName: "Worker"),
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
    /// `parentId` when set marks a subagent under that worker (3D SUB layer).
    /// `skipAuth` when the caller already ran `ProviderAuth.ensureLoggedIn`.
    @discardableResult
    static func addWorker(pair: String, type: WorkerType, parentId: String? = nil, skipAuth: Bool = false) -> String? {
        if !skipAuth {
            let gate = ProviderAuth.ensureLoggedInBlocking(
                typeId: type.id,
                reason: parentId == nil ? "add agent" : "add sub-agent"
            )
            switch gate {
            case .ok: break
            case .missingCLI(let msg):
                Pong.log("addWorker blocked: \(msg)")
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = "CLI not installed"
                    a.informativeText = msg
                    a.runModal()
                }
                return nil
            case .cancelled:
                Pong.log("addWorker login cancelled type=\(type.id)")
                return nil
            case .failed(let msg):
                Pong.log("addWorker auth failed: \(msg)")
                return nil
            }
        }
        let db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        let ws = list(from: entry)
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
        let pathExport = TerminalTheme.panePathExport()
        let safeCmd = launch.replacingOccurrences(of: "'", with: "'\\''")
        let sessionToken = Isolation.ensureToken(session: pair)
        let seatExact = TerminalTheme.exactSeatTitle(pair: pair, seat: id)
        let seatLabel = parentId != nil ? "\(type.label) sub" : type.label
        let seatFriendly = TerminalTheme.friendlySeatTitle(pair: pair, seat: id, seatLabel: seatLabel)

        // Ensure base tmux session exists
        Pong.sh("tmux has-session -t \(pair) 2>/dev/null || tmux new-session -d -s \(pair) -n Conductor")
        TmuxScroll.apply(session: pair)
        Pong.sh("tmux new-window -t \(pair) -n '\(seatLabel.replacingOccurrences(of: "'", with: ""))'")
        // attach window index: use last window
        let idxOut = Pong.sh("tmux display-message -p -t \(pair) '#{window_index}' 2>/dev/null || echo \(tmuxIndex)")
        let actualIdx = Int(idxOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? tmuxIndex
        let roleTag = parentId != nil ? "SUBAGENT" : "WORKER"
        var wParts: [String] = [
            pathExport,
            "export PONG_SESSION=\(pair)",
            "export HERMES_PONG_SESSION=\(pair)",
            "export PONG_SEAT=\(id)",
        ]
        if !sessionToken.isEmpty {
            wParts.append("export PONG_TOKEN=\(sessionToken)")
        }
        wParts.append("printf \"\\n  \(roleTag) · \(type.label) · \(pair):\(actualIdx)\\n\\n\"")
        wParts.append("exec \(safeCmd)")
        let wLaunch = TerminalTheme.joinShell(wParts)
        let wQ = wLaunch.replacingOccurrences(of: "'", with: "'\\''")
        Pong.sh("tmux send-keys -t \(pair):\(actualIdx) -l '\(wQ)'")
        usleep(80_000)
        Pong.sh("tmux send-keys -t \(pair):\(actualIdx) Enter")
        TerminalTheme.tmuxTitle(baseSession: pair, tmuxIndex: actualIdx, displayTitle: seatLabel)
        let paneId = Isolation.registerPane(session: pair, workerId: id, tmuxTarget: "\(pair):\(actualIdx)", startCommand: launch)
        _ = seatExact

        // Open Terminal attached to a single-seat view (not the full team group)
        let view = "\(pair)-w\(actualIdx - 1)"
        Pairing.ensureSeatViewSession(view: view, base: pair, windowIndex: actualIdx)
        let newId = Pairing.openAttachSession(view, displayTitle: seatFriendly)

        let rec = makeWorker(
            id: id,
            type: type.id,
            label: parentId != nil ? "\(type.label) sub" : type.label,
            windowId: newId ?? "",
            mode: "tmux",
            cmd: launch,
            tmuxIndex: actualIdx
        )
        var recMut = rec
        // Never force-unwrap newId — Automation denial / openAttachSession miss must not crash.
        if let wid = newId, !wid.isEmpty {
            recMut["window_id"] = wid
        } else {
            recMut["window_id"] = NSNull()
            Pong.log("addWorker: no Terminal window id for \(pair)/\(id) (attach failed or permission denied)")
        }
        if !paneId.isEmpty {
            recMut["pane_id"] = paneId
        } else {
            Pong.log("addWorker: no tmux pane id for \(pair)/\(id) — isolation paste may refuse until re-register")
        }
        if let parentId { recMut["parent_id"] = parentId }
        // Re-read pairs.json fresh under the write lock and append only the new
        // seat. The ~80 lines above block on tmux + Terminal automation for
        // seconds; writing back the whole-db `db` snapshot read at the top would
        // clobber any concurrent locked write (seat drag, rename, edge edit) that
        // landed meanwhile — the intermittent "had to restart to see it" bug.
        PairState.mutate(pair) { fresh in
            var freshWs = list(from: fresh)
            freshWs.append(recMut)
            fresh["workers"] = freshWs
            if let first = freshWs.first {
                fresh["claude_window_id"] = first["window_id"] ?? NSNull()
                fresh["worker_window_id"] = first["window_id"] ?? NSNull()
            }
        }
        entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? entry
        // Topology: orch→worker or parent→sub so 3D lines + SUB deck stay in sync
        if let parentId {
            FlowGraph.addEdge(pair: pair, from: parentId, to: id, kind: "sub")
        } else {
            let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
            FlowGraph.addEdge(pair: pair, from: condId, to: id, kind: "delegate")
        }
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
    /// Delegates to `TeamSanitizer.removeSeat` so edges + canvas/3D positions are pruned.
    @discardableResult
    static func removeWorker(pair: String, workerId: String) -> Bool {
        TeamSanitizer.removeSeat(pair: pair, workerId: workerId)
    }

    /// Live switch of a worker seat’s CLI/model. Keeps tmux window index + seat id.
    /// - Captures scrollback when `includeHistory` is true (bounded).
    /// - Updates pair state type/cmd, respawns pane, re-primes with seat identity.
    /// Call off the main thread (AppleScript/tmux). Auth gate may present UI.
    @discardableResult
    static func switchWorkerModel(
        pair: String,
        workerId: String,
        newTypeId: String,
        includeHistory: Bool
    ) -> (ok: Bool, message: String) {
        let tid = newTypeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tid.isEmpty, workerId != "c1", !workerId.hasPrefix("c") else {
            return (false, "Invalid seat or model")
        }
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else {
            return (false, "Seat \(workerId) not found")
        }
        let oldType = ((ws[idx]["type"] as? String) ?? "").lowercased()
        if oldType == tid {
            return (false, "Already \(WorkerType.resolved(tid).label)")
        }

        let gate = ProviderAuth.ensureLoggedInBlocking(typeId: tid, reason: "switch model")
        switch gate {
        case .ok: break
        case .missingCLI(let msg): return (false, msg)
        case .cancelled: return (false, "Login cancelled")
        case .failed(let msg): return (false, msg)
        }

        let wt = WorkerType.resolved(tid)
        let launch = wt.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "claude" : wt.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmuxIdx = (ws[idx]["tmux_index"] as? Int) ?? (idx + 1)
        let target: String = {
            if let pid = ws[idx]["pane_id"] as? String, !pid.isEmpty { return pid }
            return "\(pair):\(tmuxIdx)"
        }()
        let oldLabel = (ws[idx]["label"] as? String) ?? workerId
        let oldTypeLabel = WorkerType.resolved(oldType.isEmpty ? "claude" : oldType).label
        // Keep custom seat names; replace auto labels that were just the old model name.
        let nextLabel: String = {
            let trimmed = oldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == oldTypeLabel || trimmed == oldType
                || trimmed.hasSuffix(" sub") && trimmed.hasPrefix(oldTypeLabel) {
                return wt.label
            }
            return trimmed
        }()

        // Bounded scrollback for optional history paste
        var historyBlock = ""
        if includeHistory {
            let raw = Pong.sh("tmux capture-pane -p -J -t '\(target)' -S -400 2>/dev/null")
            historyBlock = Self.boundedHistory(raw, maxBytes: 14_000, maxLines: 220)
        }

        // Update pair state before respawn so bind/prime see new type
        PairState.mutate(pair) { fresh in
            var list = self.list(from: fresh)
            guard let i = list.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return }
            list[i]["type"] = wt.id
            list[i]["cmd"] = launch
            list[i]["label"] = nextLabel
            list[i]["done_marker"] = wt.id == "claude" ? "##CLAUDE_DONE##" : "##WORKER_DONE##"
            fresh["workers"] = list
            if i == 0 {
                fresh["worker_type"] = wt.id
                fresh["worker_label"] = nextLabel
                fresh["worker_cmd"] = launch
            }
        }

        // Respawn same pane with new CLI (keeps window / view attach)
        let pathExport = TerminalTheme.panePathExport()
        let sessionToken = Isolation.ensureToken(session: pair)
        let safeCmd = launch.replacingOccurrences(of: "'", with: "'\\''")
        var wParts: [String] = [
            pathExport,
            "export PONG_SESSION=\(pair)",
            "export HERMES_PONG_SESSION=\(pair)",
            "export PONG_SEAT=\(workerId)",
        ]
        if !sessionToken.isEmpty {
            wParts.append("export PONG_TOKEN=\(sessionToken)")
        }
        wParts.append("printf \"\\n  WORKER · \(wt.label) · \(pair):\(tmuxIdx) (model switch)\\n\\n\"")
        wParts.append("exec \(safeCmd)")
        let shellLine = TerminalTheme.joinShell(wParts)
        // Escape for nested single quotes in tmux command string
        let q = shellLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let respawn = Pong.sh("""
            tmux has-session -t '\(pair)' 2>/dev/null || exit 1
            tmux respawn-pane -k -t '\(target)' \"\(q)\" 2>/dev/null || \
              (tmux send-keys -t '\(target)' C-c; sleep 0.2; tmux send-keys -t '\(target)' -l '\(shellLine.replacingOccurrences(of: "'", with: "'\\''"))'; sleep 0.05; tmux send-keys -t '\(target)' Enter)
            echo OK
            """)
        if !respawn.contains("OK") {
            return (false, "tmux respawn failed for \(workerId)")
        }

        let paneId = Isolation.registerPane(
            session: pair,
            workerId: workerId,
            tmuxTarget: "\(pair):\(tmuxIdx)",
            startCommand: launch
        )
        if !paneId.isEmpty {
            PairState.mutate(pair) { fresh in
                var list = self.list(from: fresh)
                if let i = list.firstIndex(where: { ($0["id"] as? String) == workerId }) {
                    list[i]["pane_id"] = paneId
                    fresh["workers"] = list
                }
            }
        }
        TerminalTheme.tmuxTitle(baseSession: pair, tmuxIndex: tmuxIdx, displayTitle: nextLabel)
        TerminalTheme.applySeatRename(pair: pair, seat: workerId, label: nextLabel)
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")

        // Wait briefly for new CLI TUI
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.45)
            if ConductorKickoff.seatLooksReady(session: pair, seatId: workerId) { break }
        }

        if includeHistory, !historyBlock.isEmpty {
            let histText = """
            ## Previous model history (user requested)

            Switched from **\(oldTypeLabel)** → **\(wt.label)** on seat `\(workerId)`.
            Scrollback below is a bounded capture from the previous session.

            ```
            \(historyBlock)
            ```

            ---
            End of previous model history. Continue with your seat identity below.

            """
            _ = ConductorKickoff.pasteIntoSeat(session: pair, seatId: workerId, text: histText)
            Thread.sleep(forTimeInterval: 0.35)
        }

        let prime = ConductorKickoff.buildWorkerPrimePrompt(session: pair, seatId: workerId)
        let primed = ConductorKickoff.pasteIntoSeat(session: pair, seatId: workerId, text: prime)
        Pong.log("switchWorkerModel \(pair)/\(workerId) \(oldType)→\(tid) hist=\(includeHistory) prime=\(primed)")
        return (true, "Switched \(workerId) to \(wt.label)")
    }

    /// Cap scrollback for paste safety (~14KB / line cap).
    private static func boundedHistory(_ raw: String, maxBytes: Int, maxLines: Int) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        var out = lines.joined(separator: "\n")
        if out.utf8.count > maxBytes {
            // Keep the tail (most recent)
            let data = Data(out.utf8.suffix(maxBytes))
            out = String(data: data, encoding: .utf8) ?? String(out.suffix(maxBytes / 2))
            if let r = out.range(of: "\n") {
                out = String(out[r.upperBound...])
            }
            out = "…(truncated)…\n" + out
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setWorkerLabel(pair: String, workerId: String, label: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else {
            Pong.log("rename worker FAIL \(pair)/\(workerId) not in workers list")
            return
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ws[idx]["label"] = trimmed
        entry["workers"] = ws
        if idx == 0 { entry["worker_label"] = trimmed }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        // Force title on the open Terminal + view session (was blocked once friendly titles set)
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalTheme.applySeatRename(pair: pair, seat: workerId, label: trimmed)
        }
        Pong.log("rename worker \(pair)/\(workerId) → \(trimmed)")
    }

    /// Rename conductor seat label (map / Focus display name).
    static func setConductorLabel(pair: String, label: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var cond = entry["conductor"] as? [String: Any] ?? [:]
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cond["label"] = trimmed
        entry["conductor"] = cond
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        var active = Pong.loadJSON(PairState.activePath)
        if active["session"] as? String == pair {
            active["conductor"] = cond
            active["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(PairState.activePath, active)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalTheme.applySeatRename(pair: pair, seat: "c1", label: trimmed)
        }
        Pong.log("rename conductor \(pair) → \(trimmed)")
    }

    static func setWorkerColors(
        pair: String,
        workerId: String,
        colors: TerminalTheme.Colors,
        applyTheme: Bool = true
    ) {
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
        if applyTheme {
            if Thread.isMainThread {
                DispatchQueue.global(qos: .userInitiated).async {
                    TerminalTheme.applyPair(pair)
                }
            } else {
                TerminalTheme.applyPair(pair)
            }
        }
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
    /// Persist team options. Slow work (bind-card shell + Terminal theming) runs
    /// on a background queue when called from the main thread so sheets stay responsive.
    /// Pass `applyTheme: false` when a subsequent reload will re-theme, or when the
    /// caller will theme once after a batch of mutations.
    static func setTeamOptions(
        _ pair: String,
        displayName: String,
        projectRoot: String,
        teamBrief: String,
        applyTheme: Bool = true
    ) {
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
        Pong.log("team options \(pair) root=\(root.isEmpty ? "(unset)" : root) brief_chars=\(brief.count)")

        let slowWork = {
            // Keep the orchestra bind card in step with the fields just saved.
            Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")
            if applyTheme {
                TerminalTheme.applyPair(pair)
            }
        }
        // Bind + applyPair are AppleScript/shell — never block the main click path.
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async(execute: slowWork)
        } else {
            slowWork()
        }
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

    static func setPairColors(_ pair: String, colors: TerminalTheme.Colors, applyTheme: Bool = true) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["colors"] = colors.asDict()
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
        if applyTheme {
            if Thread.isMainThread {
                DispatchQueue.global(qos: .userInitiated).async {
                    TerminalTheme.applyPair(pair)
                }
            } else {
                TerminalTheme.applyPair(pair)
            }
        }
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

    /// Raise this worker’s Terminal, or re-open a new one attached to the same
    /// tmux view (history intact). Closing the Terminal window only detaches the
    /// client — it does not kill the agent or clear scrollback.
    static func frontWorker(pair: String, workerId: String) {
        Pong.log("frontWorker begin \(pair)/\(workerId)")
        DispatchQueue.global(qos: .userInitiated).async {
            // Drop free Grok/Claude window ids that were mis-bound earlier
            scrubInvalidWindowIds(pair: pair)
            let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
            let ws = list(from: entry)
            guard let w = ws.first(where: { ($0["id"] as? String) == workerId }) else {
                Pong.log("frontWorker miss \(pair)/\(workerId) workers=\(ws.map { $0["id"] as? String ?? "?" })")
                return
            }
            let ti = (w["tmux_index"] as? Int) ?? 1
            let view = TerminalTheme.viewToken(pair: pair, role: workerId)
            // Ignore stored id unless it is a real attach for THIS view
            let stored = "\(w["window_id"] ?? "")"
            let storedOpt: String? = {
                guard Int(stored) != nil else { return nil }
                let title = TerminalTheme.listWindows().first(where: { $0.id == stored })?.title ?? ""
                if TerminalTheme.isPairAttachTitle(title, viewToken: view) { return stored }
                Pong.log("frontWorker ignore bad stored id=\(stored) title=\(title)")
                return nil
            }()
            Pong.log("frontWorker resolve pair=\(pair) id=\(workerId) view=\(view) tmux=\(ti) stored=\(storedOpt ?? "-")")
            guard let live = Pairing.frontOrReopenAttach(
                pair: pair, view: view, tmuxIndex: ti, storedWindowId: storedOpt
            ) else {
                Pong.log("frontWorker reopen failed \(pair)/\(workerId) view=\(view)")
                return
            }
            // Final gate: never raise a free Grok/Claude window
            guard Pairing.raiseOnlyIfPairAttach(live, viewToken: view) else {
                Pong.log("frontWorker refused raise id=\(live) — not pair attach for \(view)")
                // Clear poison id and try a forced reopen once
                setWorkerWindowId(pair: pair, workerId: workerId, windowId: "")
                if let again = Pairing.openAttachSession(view),
                   Pairing.raiseOnlyIfPairAttach(again, viewToken: view) {
                    setWorkerWindowId(pair: pair, workerId: workerId, windowId: again)
                    TerminalTheme.apply(windowId: again,
                        displayTitle: (w["label"] as? String) ?? workerId,
                        viewToken: view,
                        colors: TerminalTheme.Colors.from(w["colors"]),
                        profile: TerminalTheme.profileName(pair: pair, role: workerId))
                    Pong.log("frontWorker ok after retry \(pair)/\(workerId) → \(again)")
                }
                return
            }
            setWorkerWindowId(pair: pair, workerId: workerId, windowId: live)
            // Theme ONLY this seat’s window — never applyPair (touches other windows)
            TerminalTheme.apply(windowId: live,
                displayTitle: (w["label"] as? String) ?? workerId,
                viewToken: view,
                colors: TerminalTheme.Colors.from(w["colors"]),
                profile: TerminalTheme.profileName(pair: pair, role: workerId))
            Pong.log("frontWorker ok \(pair)/\(workerId) → window \(live)")
        }
    }

    /// Clear window_ids that point at free Grok/Claude UIs or dead ids.
    static func scrubInvalidWindowIds(pair: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var changed = false
        var ws = list(from: entry)
        let wins = TerminalTheme.listWindows()
        for i in ws.indices {
            let id = (ws[i]["id"] as? String) ?? "w\(i+1)"
            let wid = "\(ws[i]["window_id"] ?? "")"
            guard Int(wid) != nil else { continue }
            let token = TerminalTheme.viewToken(pair: pair, role: id)
            let title = wins.first(where: { $0.id == wid })?.title ?? ""
            if title.isEmpty || !TerminalTheme.isPairAttachTitle(title, viewToken: token) {
                Pong.log("scrub window_id pair=\(pair) seat=\(id) was=\(wid) title=\(title)")
                ws[i]["window_id"] = NSNull()
                changed = true
            }
        }
        var cond = entry["conductor"] as? [String: Any] ?? [:]
        let hWid = "\(entry["hermes_window_id"] ?? cond["window_id"] ?? "")"
        if Int(hWid) != nil {
            let hTok = TerminalTheme.viewToken(pair: pair, role: "hermes")
            let title = wins.first(where: { $0.id == hWid })?.title ?? ""
            if title.isEmpty || !TerminalTheme.isPairAttachTitle(title, viewToken: hTok) {
                Pong.log("scrub hermes_window_id pair=\(pair) was=\(hWid) title=\(title)")
                entry["hermes_window_id"] = NSNull()
                entry["conductor_window_id"] = NSNull()
                cond["window_id"] = NSNull()
                entry["conductor"] = cond
                changed = true
            }
        }
        if changed {
            entry["workers"] = ws
            if let first = ws.first {
                entry["claude_window_id"] = first["window_id"] ?? NSNull()
                entry["worker_window_id"] = first["window_id"] ?? NSNull()
            }
            entry["updated"] = Date().timeIntervalSince1970
            db[pair] = entry
            Pong.writeJSON(PairState.pairsPath, db)
            syncActive(pair, entry: entry)
        }
    }

    static func setWorkerWindowId(pair: String, workerId: String, windowId: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        var ws = list(from: entry)
        guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else { return }
        if windowId.isEmpty {
            ws[idx]["window_id"] = NSNull()
        } else {
            ws[idx]["window_id"] = windowId
        }
        entry["workers"] = ws
        if idx == 0 {
            entry["claude_window_id"] = windowId.isEmpty ? NSNull() : windowId
            entry["worker_window_id"] = windowId.isEmpty ? NSNull() : windowId
        }
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
    }

    static func setConductorWindowId(pair: String, windowId: String) {
        var db = PairState.loadPairsDb()
        var entry = db[pair] as? [String: Any] ?? [:]
        entry["hermes_window_id"] = windowId
        entry["conductor_window_id"] = windowId
        var cond = entry["conductor"] as? [String: Any] ?? [:]
        cond["window_id"] = windowId
        entry["conductor"] = cond
        entry["updated"] = Date().timeIntervalSince1970
        db[pair] = entry
        Pong.writeJSON(PairState.pairsPath, db)
        syncActive(pair, entry: entry)
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
        // Prefer osascript (reliable off main thread); NSAppleScript often returns empty
        // from background queues which broke “reopen closed Terminal”.
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

    /// Exact recovery token `pong.<session>.<seat>` — no fuzzy Claude title match (V5).
    static func exactSeatTitle(pair: String, seat: String) -> String {
        "pong.\(pair).\(seat)"
    }

    /// Human-facing Terminal title: **`Agent · Team`** (agent first, after macOS username).
    /// Never session id alone or bare model type when a label exists.
    static func friendlySeatTitle(pair: String, seat: String, seatLabel: String? = nil) -> String {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let team = (entry["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let teamPart = (team?.isEmpty == false) ? team! : pair

        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        func agentFirst(_ agent: String) -> String {
            // "Sub · " noise → short agent name only
            let short = agent.hasPrefix("Sub · ") ? String(agent.dropFirst(6)) : agent
            return "\(short) · \(teamPart)"
        }
        if let lab = clean(seatLabel) {
            return agentFirst(lab)
        }
        if seat == "c1" || seat == "hermes" {
            let cond = entry["conductor"] as? [String: Any]
            if let cl = clean(cond?["label"] as? String) { return agentFirst(cl) }
            return agentFirst("Orchestrator")
        }
        if let w = Workers.list(from: entry).first(where: { ($0["id"] as? String) == seat }) {
            if let lab = clean(w["label"] as? String) {
                return agentFirst(lab)
            }
            if let typ = clean(w["type"] as? String) {
                // Prefer a human label over raw type id when possible
                let pretty = WorkerType.named(typ).label
                return agentFirst(pretty)
            }
        }
        return agentFirst(seat)
    }

    /// Patch HP-* profile: no process/size in title + close without “Terminate?” prompt.
    /// Process title keys aren’t in AppleScript sdef; close prefs are reinforced via AS too.
    static func ensureProfileHidesProcessChrome(profile: String) {
        let prof = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prof.isEmpty else { return }
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.Terminal.plist"
        let url = URL(fileURLWithPath: path)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = obj as? [String: Any] {
            root = dict
        }
        var ws = root["Window Settings"] as? [String: Any] ?? [:]
        var conf = ws[prof] as? [String: Any] ?? [:]
        conf["name"] = prof
        conf["type"] = "Window Settings"
        if conf["ProfileCurrentVersion"] == nil { conf["ProfileCurrentVersion"] = 2.09 }
        // Kill process/argv in title (this is what shows “tmux attach-session -t …”)
        for k in [
            "ShowActiveProcessInTitle", "ShowActiveProcessArgumentsInTitle",
            "ShowActiveProcessInTabTitle", "ShowActiveProcessArgumentsInTabTitle",
            "ShowCommandKeyInTitle", "ShowWindowSettingsNameInTitle",
        ] {
            conf[k] = false
        }
        // 2 = close if the shell exited cleanly (detach/close client → no hang)
        conf["shellExitAction"] = 2
        ws[prof] = conf
        root["Window Settings"] = ws
        guard let out = try? PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        ) else { return }
        let tmp = path + ".tmp-pong"
        do {
            try out.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
            _ = Pong.sh("defaults read com.apple.Terminal >/dev/null 2>&1 || true")
        } catch {
            Pong.log("profile title chrome write failed \(prof): \(error)")
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    /// AppleScript fragment for Terminal settings we can actually set via sdef.
    /// Do NOT use GUI-only prefs like "close if shell exited cleanly" — they fail to
    /// compile and poison the whole theme script (log spam + titles never apply).
    /// Close-without-prompt is handled by ensureProfileHidesProcessChrome (shellExitAction).
    private static func closeFriendlyAS(themeVar: String = "theme") -> String {
        """
        try
          set clean commands of \(themeVar) to {"tmux", "login", "bash", "zsh", "sh", "fish", "screen", "mosh", "ssh", "-zsh", "-bash", "reattach-to-user-namespace"}
        end try
        """
    }

    /// PATH for agent panes — includes Grok Build (`~/.grok/bin`) and common install roots.
    static func panePathExport() -> String {
        "export PATH=\"$HOME/.grok/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$PATH\""
    }

    /// Join shell fragments with single `;` — never produces `;;` (broke conductor launch).
    static func joinShell(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { p in
                var s = p
                while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
                while s.hasPrefix(";") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return s
            }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    /// True when title is exactly the isolation token (or equals it as custom title).
    static func isExactSeatTitle(_ title: String, pair: String, seat: String) -> Bool {
        let want = exactSeatTitle(pair: pair, seat: seat)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == want { return true }
        // Terminal may prefix path or other chrome — require whole-token boundary match
        if t.contains(want) {
            // reject fuzzy agent titles that merely mention session name
            if t.localizedCaseInsensitiveContains("claude code") && !t.contains("pong.") {
                return false
            }
            return true
        }
        return false
    }

    /// True only for a real pair attach client — never a free-floating Grok/Claude TUI.
    static func isPairAttachTitle(_ title: String, viewToken: String) -> Bool {
        let t = title.lowercased()
        let token = viewToken.lowercased()
        // Free agent GUIs (not our tmux clients) — never rebind by fuzzy Claude titles
        if t.contains("grok ▸") { return false }
        if t.contains("hermes ▸") { return false }
        if t.contains("osascript") { return false }
        if t.contains("claude code") && !t.contains("attach-session -t") && !t.contains("pong.") {
            return false
        }
        // Must be an attach to THIS view session (exact token after -t)
        let needle = "attach-session -t \(token)"
        guard t.contains(needle) else { return false }
        // Avoid prefix collisions (e.g. pair-w1 matching pair-w10)
        if let r = t.range(of: needle) {
            let after = t[r.upperBound...]
            if let c = after.first, c.isLetter || c.isNumber || c == "-" || c == "_" {
                return false
            }
        }
        return true
    }

    /// Strict recovery: exact `pong.<session>.<seat>` title OR attach-session -t <viewToken>
    /// OR a still-valid stored window id (friendly titles like "Team · Agent" no longer embed the token).
    /// Never fuzzy-match free Grok/Claude app windows (V5).
    static func resolvePairWindow(stored: String?, viewToken: String, pair: String? = nil, seat: String? = nil) -> String? {
        let wins = listWindows()
        func matches(_ title: String) -> Bool {
            if isPairAttachTitle(title, viewToken: viewToken) { return true }
            if let pair, let seat, isExactSeatTitle(title, pair: pair, seat: seat) { return true }
            // Friendly "Team · Label" titles after theming
            if title.lowercased().contains(viewToken.lowercased()) { return true }
            if let pair, title.lowercased().contains(pair.lowercased()) { return true }
            return false
        }
        if let s = stored, Int(s) != nil {
            if let title = wins.first(where: { $0.id == s })?.title {
                if matches(title) { return s }
                // Trust stored id if the window still exists and is not a free agent GUI
                let t = title.lowercased()
                if !t.contains("grok ▸") && !t.contains("hermes ▸") {
                    return s
                }
            }
        }
        for (id, title) in wins where matches(title) {
            return id
        }
        Pong.log("theme resolve miss token=\(viewToken) pair=\(pair ?? "") seat=\(seat ?? "") windows=\(wins.map { $0.title }.joined(separator: " || "))")
        return nil
    }

    /// True if this window is a CyberPong attach client we are allowed to theme.
    /// Accepts attach-session token, PONGATTACH marker, exact pong.<session>.seat title,
    /// **and already-friendly titles** ("Team · Agent") so rename can update the bar.
    static func isThemeableTitle(_ title: String, viewToken: String, displayTitle: String,
                                 pair: String? = nil) -> Bool {
        let t = title.lowercased()
        if t.contains("hermes ▸") || t.contains("grok ▸") {
            // Free floating agent apps — never restyle as pair panes
            if !t.contains("attach-session") && !t.contains("pongattach:") && !t.contains("pong.") {
                return false
            }
        }
        if isPairAttachTitle(title, viewToken: viewToken) { return true }
        if t.contains("pongattach:\(viewToken.lowercased())") { return true }
        if t.contains("pongattach:") && t.contains(viewToken.lowercased()) { return true }
        if t.contains(viewToken.lowercased()) { return true }
        let want = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !want.isEmpty, t == want || t.contains(want) { return true }
        // Already themed: "Team - Agent" / "Team · Agent" — must stay themeable for renames
        if t.contains(" - ") || t.contains(" · ") || t.contains("·") {
            return true
        }
        // Team / session name already in the title bar
        if let pair {
            let pl = pair.lowercased()
            if !pl.isEmpty, t.contains(pl) { return true }
            if let entry = PairState.loadPairsDb()[pair] as? [String: Any],
               let dn = (entry["display_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !dn.isEmpty, t.contains(dn) {
                return true
            }
        }
        // Team part of the *new* friendly title (rename path: old label ≠ new label)
        let teamPart = displayTitle
            .components(separatedBy: " · ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !teamPart.isEmpty, t.contains(teamPart) { return true }
        // Fresh .command launch often titles itself after the script name / “bash”
        if t.contains("tmux") || t.contains(".command") || t.contains("bash") || t.isEmpty {
            return true
        }
        return false
    }

    /// Title + colors on ONE pair pane. Uses NSAppleScript + tab properties.
    /// colors.highlight = Marker accent (bold + cursor). Terminal has no title-bar color API.
    /// - Parameter force: when true (rename), skip themeable gate except free-agent GUIs.
    static func apply(windowId: String?, displayTitle: String, viewToken: String, colors: Colors?,
                      profile: String, force: Bool = false, pair: String? = nil) {
        guard let wid = windowId, Int(wid) != nil else {
            Pong.log("theme apply skip — no window for \(viewToken)")
            return
        }
        if let title = listWindows().first(where: { $0.id == wid })?.title {
            let freeAgent: Bool = {
                let t = title.lowercased()
                return (t.contains("hermes ▸") || t.contains("grok ▸"))
                    && !t.contains("attach-session") && !t.contains("pongattach:") && !t.contains("pong.")
            }()
            if freeAgent {
                Pong.log("theme APPLY BLOCKED free-agent window=\(wid) token=\(viewToken) title=\(title)")
                return
            }
            if !force, !isThemeableTitle(title, viewToken: viewToken, displayTitle: displayTitle, pair: pair) {
                Pong.log("theme APPLY BLOCKED window=\(wid) token=\(viewToken) title=\(title)")
                return
            }
        }

        // Patch HP profile so Terminal stops appending process argv / size
        ensureProfileHidesProcessChrome(profile: profile)

        let safeTitle = escapeAS(String(displayTitle.prefix(56))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: ""))
        let prof = escapeAS(profile)

        let closeAS = closeFriendlyAS(themeVar: "theme")
        let closeCurAS = closeFriendlyAS(themeVar: "S")
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
            -- Close client without “Terminate processes?” (tmux stays a clean command)
            \(closeAS)
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
        } else {
            // Always ensure HP profile + close-friendly prefs (open/reopen path)
            colorLines = """

            set setName to "\(prof)"
            try
              set theme to settings set setName
            on error
              set theme to make new settings set with properties {name:setName}
            end try
            \(closeAS)
            set current settings of T to theme
            """
        }

        // Custom title only: Agent - Team (username stays as Terminal’s first segment).
        // Process name hidden via ensureProfileHidesProcessChrome — never exec -a rename.
        let barTitle = safeTitle
            .replacingOccurrences(of: " · ", with: " - ")
            .replacingOccurrences(of: "·", with: "-")
        let source = """
        tell application "Terminal"
          try
            set W to window id \(wid)
            set T to selected tab of W
            \(colorLines)
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
            set custom title of T to "\(barTitle)"
            try
              set S to current settings of T
              \(closeCurAS)
              set title displays custom title of S to true
              set title displays device name of S to false
              set title displays shell path of S to false
              set title displays window size of S to false
              try
                set title displays settings name of S to false
              end try
            end try
            return "OK"
          on error errMsg
            return "ERR:" & errMsg
          end try
        end tell
        """
        let out = Pong.appleScript(source)
        // Second pass: reassert title + close-friendly (tmux may rebind settings)
        if out == "OK" || out.isEmpty || out.hasPrefix("OK") {
            usleep(200_000)
            _ = Pong.appleScript("""
            tell application "Terminal"
              try
                set T to selected tab of window id \(wid)
                set title displays custom title of T to true
                set title displays window size of T to false
                set title displays shell path of T to false
                set title displays device name of T to false
                set custom title of T to "\(barTitle)"
                try
                  set S to current settings of T
                  set clean commands of S to {"tmux", "login", "bash", "zsh", "sh", "fish", "screen", "mosh", "ssh", "-zsh", "-bash", "reattach-to-user-namespace"}
                end try
              end try
            end tell
            """)
        }
        Pong.log("theme apply window=\(wid) token=\(viewToken) title=\(barTitle) → \(out.isEmpty ? "(empty)" : out)")
    }

    static func tmuxTitle(baseSession: String, tmuxIndex: Int, displayTitle: String) {
        let safe = displayTitle
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        let bar = safe
            .replacingOccurrences(of: " · ", with: " - ")
            .replacingOccurrences(of: "·", with: "-")
        _ = Pong.sh("tmux set-option -t \(baseSession):\(tmuxIndex) automatic-rename off 2>/dev/null || true")
        _ = Pong.sh("tmux rename-window -t \(baseSession):\(tmuxIndex) '\(bar)' 2>/dev/null || true")
        // Prefer our string if the client allows titles; still hide argv via Terminal profile.
        _ = Pong.sh("tmux set-option -t \(baseSession) set-titles on 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -t \(baseSession) set-titles-string '\(bar)' 2>/dev/null || true")
    }

    /// Apply titles/colors for a pair. `force` is used after rename so already-friendly
    /// window titles still get updated (otherwise isThemeableTitle could block).
    static func applyPair(_ pair: String, force: Bool = false) {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hermesLabel = (display?.isEmpty == false) ? display! : pair
        let hColors = Colors.from(entry["colors"]) ?? .hermesDefault
        let storedH = entry["hermes_window_id"].flatMap { v -> String? in
            let s = "\(v)"; return (s == "<null>" || s.isEmpty) ? nil : s
        }
        let hToken = viewToken(pair: pair, role: "hermes")
        let hid = resolvePairWindow(stored: storedH, viewToken: hToken, pair: pair, seat: "c1")
        let condType = (entry["conductor"] as? [String: Any])?["type"] as? String
        let condLabel = (entry["conductor"] as? [String: Any])?["label"] as? String
        // Friendly title for humans; isolation still uses attach-session / pong.session.seat match
        let hubTitle = friendlySeatTitle(pair: pair, seat: "c1", seatLabel: condLabel)
        apply(windowId: hid, displayTitle: hubTitle, viewToken: hToken,
              colors: hColors, profile: profileName(pair: pair, role: "hermes"),
              force: force, pair: pair)
        tmuxTitle(baseSession: pair, tmuxIndex: 0, displayTitle: hubTitle)
        // Also rename the link view session window name if present
        tmuxTitle(baseSession: hToken, tmuxIndex: 0, displayTitle: hubTitle)
        _ = condType // reserved for future per-conductor chrome
        _ = hermesLabel

        var ws = Workers.list(from: entry)
        var changed = false
        for i in 0..<ws.count {
            let id = (ws[i]["id"] as? String) ?? "w\(i + 1)"
            let lab = (ws[i]["label"] as? String) ?? "Worker"
            let storedW = "\(ws[i]["window_id"] ?? "")"
            let storedOpt = Int(storedW) != nil ? storedW : nil
            let token = viewToken(pair: pair, role: id)
            let wid = resolvePairWindow(stored: storedOpt, viewToken: token, pair: pair, seat: id)
            let cols = Colors.from(ws[i]["colors"]) ?? .workerDefault
            let seatTitle = friendlySeatTitle(pair: pair, seat: id, seatLabel: lab)
            apply(windowId: wid, displayTitle: seatTitle, viewToken: token,
                  colors: cols, profile: profileName(pair: pair, role: id),
                  force: force, pair: pair)
            let tmuxIdx = (ws[i]["tmux_index"] as? Int) ?? (i + 1)
            tmuxTitle(baseSession: pair, tmuxIndex: tmuxIdx, displayTitle: seatTitle)
            // Link view sessions are single-window (`pair-w0`, …)
            tmuxTitle(baseSession: token, tmuxIndex: 0, displayTitle: seatTitle)
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

    /// Fast path after seat rename: force-update that seat’s Terminal title + tmux window name.
    static func applySeatRename(pair: String, seat: String, label: String) {
        let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
        let seatTitle = friendlySeatTitle(pair: pair, seat: seat, seatLabel: label)
        let isCond = seat == "c1" || seat == "hermes"
        let role = isCond ? "hermes" : seat
        let token = viewToken(pair: pair, role: role)
        let stored: String? = {
            if isCond {
                let s = "\(entry["hermes_window_id"] ?? (entry["conductor"] as? [String: Any])?["window_id"] ?? "")"
                return Int(s) != nil ? s : nil
            }
            if let w = Workers.list(from: entry).first(where: { ($0["id"] as? String) == seat }) {
                let s = "\(w["window_id"] ?? "")"
                return Int(s) != nil ? s : nil
            }
            return nil
        }()
        let wid = resolvePairWindow(stored: stored, viewToken: token, pair: pair, seat: isCond ? "c1" : seat)
        let colors: Colors? = {
            if isCond { return Colors.from(entry["colors"]) ?? .hermesDefault }
            if let w = Workers.list(from: entry).first(where: { ($0["id"] as? String) == seat }) {
                return Colors.from(w["colors"]) ?? .workerDefault
            }
            return .workerDefault
        }()
        apply(windowId: wid, displayTitle: seatTitle, viewToken: token,
              colors: colors, profile: profileName(pair: pair, role: role),
              force: true, pair: pair)
        if isCond {
            tmuxTitle(baseSession: pair, tmuxIndex: 0, displayTitle: seatTitle)
            tmuxTitle(baseSession: token, tmuxIndex: 0, displayTitle: seatTitle)
        } else if let w = Workers.list(from: entry).first(where: { ($0["id"] as? String) == seat }) {
            let tmuxIdx = (w["tmux_index"] as? Int) ?? 1
            tmuxTitle(baseSession: pair, tmuxIndex: tmuxIdx, displayTitle: seatTitle)
            tmuxTitle(baseSession: token, tmuxIndex: 0, displayTitle: seatTitle)
        }
        Pong.log("theme applySeatRename pair=\(pair) seat=\(seat) title=\(seatTitle) wid=\(wid ?? "-")")
    }
}

// MARK: - Tmux scrollback (Terminal scrollbar is blank without this)

/// Pair windows are `tmux attach`. Tmux owns pane history; Terminal’s scrollbar
/// only shows its own buffer (often empty under the alternate screen). Enable
/// Deep history + mouse for wheel scroll; copy-mode friendly for Terminal selection.
enum TmuxScroll {
    static func apply(session: String? = nil) {
        // Global defaults (new panes inherit)
        _ = Pong.sh("tmux set-option -g history-limit 100000 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -g mouse on 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -g focus-events on 2>/dev/null || true")
        _ = Pong.sh("tmux set-option -g mode-keys vi 2>/dev/null || true")
        // Terminal.app: drag-select often works with mouse on + copy-mode; Option-drag always works
        _ = Pong.sh("tmux set-option -g @terminal-select-hint 1 2>/dev/null || true")
        // Prefer OSC 52 clipboard when Terminal supports it
        _ = Pong.sh("tmux set-option -g set-clipboard on 2>/dev/null || true")
        if let session, !session.isEmpty {
            let s = session.replacingOccurrences(of: "'", with: "")
            _ = Pong.sh("tmux set-option -t '\(s)' history-limit 100000 2>/dev/null || true")
            _ = Pong.sh("tmux set-option -t '\(s)' mouse on 2>/dev/null || true")
            _ = Pong.sh("tmux set-option -t '\(s)' mode-keys vi 2>/dev/null || true")
        }
    }

    static func applyAllLive() {
        apply()
        let out = Pong.sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        for name in out.split(whereSeparator: \.isNewline).map(String.init) where !name.isEmpty {
            apply(session: name)
        }
    }

    /// Capture last N lines of a seat pane to the macOS pasteboard (mitigation when drag-select fights mouse scroll).
    @discardableResult
    static func copyScrollback(session: String, paneTarget: String? = nil, lines: Int = 200) -> Bool {
        let target = (paneTarget?.isEmpty == false) ? paneTarget! : "\(session):0"
        let t = target.replacingOccurrences(of: "'", with: "")
        let raw = Pong.sh("tmux capture-pane -p -J -t '\(t)' -S -\(max(20, lines)) 2>/dev/null")
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        Pong.log("tmux copyScrollback session=\(session) target=\(t) chars=\(raw.count)")
        return true
    }
}


// MARK: - Saved teams (~/.hermes-pong/teams.json)

/// Snapshot of Hermes display name/colors + worker types/labels/cmds/perms/colors.
/// Spawnable from Show Teams…
enum SavedTeams {
    static var path: String { Pong.stateDir + "/teams.json" }

    /// What to include when snapshotting a live pair into a reusable team.
    struct SaveOptions {
        var workers = true
        var colors = true
        var projectRoot = true
        var teamBrief = true
        var cronJobs = true
        var perms = true
    }

    struct Team {
        let id: String
        let name: String
        let displayName: String
        let hermesColors: [String: Any]?
        let workers: [[String: Any]]
        let projectRoot: String
        let teamBrief: String
        /// Cron jobs template (dicts) restored on spawn.
        let cronJobs: [[String: Any]]
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
                teamBrief: (row["team_brief"] as? String) ?? "",
                cronJobs: (row["cron_jobs"] as? [[String: Any]]) ?? []
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func saveFromLivePair(_ pair: String, teamName: String, options: SaveOptions = SaveOptions()) -> Team? {
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
            if options.perms, let perms = w["permissions"] as? [String: Any] { c["permissions"] = perms }
            if options.colors, let colors = w["colors"] as? [String: Any] { c["colors"] = colors }
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
        let cronJobs: [[String: Any]] = options.cronJobs
            ? CronSchedule.load(session: pair).map { $0.asDict() }
            : []
        let team = Team(
            id: id,
            name: trimmed,
            displayName: display.isEmpty ? trimmed : display,
            hermesColors: options.colors ? (entry["colors"] as? [String: Any]) : nil,
            workers: cleanWorkers,
            projectRoot: options.projectRoot ? ((entry["project_root"] as? String) ?? "") : "",
            teamBrief: options.teamBrief ? ((entry["team_brief"] as? String) ?? "") : "",
            cronJobs: cronJobs
        )
        list.append(team)
        writeAll(list)
        Pong.log("saved team id=\(id) name=\(trimmed) workers=\(cleanWorkers.count) cron=\(cronJobs.count)")
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
            teamBrief: src.teamBrief,
            cronJobs: src.cronJobs
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
            if !t.cronJobs.isEmpty { row["cron_jobs"] = t.cronJobs }
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
        // Restore cron jobs (if saved with the team)
        if !team.cronJobs.isEmpty {
            let jobs = team.cronJobs.compactMap { CronSchedule.Job.from($0) }
            if !jobs.isEmpty {
                CronSchedule.save(session: pair, jobs: jobs)
            }
        }
        // Re-write the bind card now that project_root/team_brief are on the
        // live entry — the first card (written at pair start) predates them.
        Pong.sh("python3 $HOME/bin/hermes_pong.py write-bind --session \(pair) >/dev/null 2>&1 || true")
        // Kickoff with final display name / brief / roster (supersedes startFresh schedule).
        ConductorKickoff.scheduleInject(
            session: pair,
            context: ConductorKickoff.contextFromPairState(session: pair)
        )
        Pong.log("spawned team \(team.name) → \(pair) cron=\(team.cronJobs.count)")
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
        // Dead ids (user closed the Terminal) are skipped — Open on a cube
        // re-attaches that seat with full tmux history.
        let ids = livePairWindowIds(name)
        if !ids.isEmpty {
            flashWindows(ids)
        } else {
            // Nothing open: re-open conductor only (not every worker — no dock pile)
            frontConductor(name)
        }
    }

    /// Open / raise the orchestrator Terminal for this team.
    /// Safe after the user closed the window — re-attaches to tmux (history intact).
    static func frontConductor(_ pair: String) {
        Pong.log("frontConductor begin \(pair)")
        DispatchQueue.global(qos: .userInitiated).async {
            Workers.scrubInvalidWindowIds(pair: pair)
            let entry = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
            let view = (entry["view_hermes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? TerminalTheme.viewToken(pair: pair, role: "hermes")
            let stored = "\(entry["hermes_window_id"] ?? (entry["conductor"] as? [String: Any])?["window_id"] ?? "")"
            let storedOpt: String? = {
                guard Int(stored) != nil else { return nil }
                let title = TerminalTheme.listWindows().first(where: { $0.id == stored })?.title ?? ""
                if TerminalTheme.isPairAttachTitle(title, viewToken: view) { return stored }
                return nil
            }()
            Pong.log("frontConductor resolve pair=\(pair) view=\(view) stored=\(storedOpt ?? "-")")
            guard let live = frontOrReopenAttach(
                pair: pair, view: view, tmuxIndex: 0, storedWindowId: storedOpt
            ) else {
                Pong.log("frontConductor reopen failed \(pair) view=\(view)")
                return
            }
            guard raiseOnlyIfPairAttach(live, viewToken: view) else {
                Pong.log("frontConductor refused raise id=\(live)")
                if let again = openAttachSession(view) {
                    _ = raiseOnlyIfPairAttach(again, viewToken: view)
                    Workers.setConductorWindowId(pair: pair, windowId: again)
                }
                return
            }
            Workers.setConductorWindowId(pair: pair, windowId: live)
            let condLabel = (entry["conductor"] as? [String: Any])?["label"] as? String
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pair
            TerminalTheme.apply(windowId: live,
                displayTitle: "\(condLabel ?? "Conductor") · \(display)",
                viewToken: view,
                colors: TerminalTheme.Colors.from(entry["colors"]),
                profile: TerminalTheme.profileName(pair: pair, role: "hermes"))
            Pong.log("frontConductor ok \(pair) → window \(live)")
        }
    }

    // MARK: - Re-open after Terminal close (tmux history stays)

    /// PATH prefix used when spawning attach clients.
    private static let pathExport =
        "export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$PATH"

    /// Absolute tmux binary (do-script shells often lack brew PATH).
    private static var tmuxBin: String {
        let found = Pong.sh("command -v tmux 2>/dev/null || true")
        if found.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        for c in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "tmux"
    }

    /// Raise an existing Terminal window (unhide / unminiaturize / front).
    /// Prefer `visible` over miniaturize so we never stack Dock minimized tiles.
    static func raiseTerminalWindow(_ windowId: String) {
        guard Int(windowId) != nil else { return }
        let out = Pong.osascript("""
        tell application "Terminal"
          try
            set w to window id \(windowId)
            set visible of w to true
            try
              set miniaturized of w to false
            end try
            set index of w to 1
            set frontmost of w to true
            activate
            return "OK"
          on error errMsg
            return "ERR:" & errMsg
          end try
        end tell
        """)
        Pong.log("raiseTerminalWindow id=\(windowId) → \(out)")
    }

    /// Raise only if the window title is a real `tmux attach-session -t <viewToken>`.
    /// Refuses free `grok ▸` / `hermes ▸` windows that were mis-bound as seat ids.
    @discardableResult
    static func raiseOnlyIfPairAttach(_ windowId: String, viewToken: String) -> Bool {
        guard Int(windowId) != nil else { return false }
        let title = TerminalTheme.listWindows().first(where: { $0.id == windowId })?.title ?? ""
        guard TerminalTheme.isPairAttachTitle(title, viewToken: viewToken) else {
            Pong.log("raiseOnlyIfPairAttach BLOCKED id=\(windowId) token=\(viewToken) title=\(title)")
            return false
        }
        raiseTerminalWindow(windowId)
        // Re-assert front after a beat (Terminal sometimes re-fronts another tab group)
        usleep(80_000)
        raiseTerminalWindow(windowId)
        return true
    }

    /// Build a **single-window** view session that only shows one seat from the base team.
    ///
    /// Critical: `new-session -t base` joins the full session *group* — every Terminal client
    /// can see every seat. Clicking status / next-window then makes the “Grok” window show
    /// Claude while the OS title still says Grok. Instead we `link-window` only one pane.
    static func ensureSeatViewSession(view: String, base: String, windowIndex: Int) {
        let v = view.replacingOccurrences(of: "'", with: "")
        let b = base.replacingOccurrences(of: "'", with: "")
        let idx = max(0, windowIndex)
        // Base must exist
        let baseOK = Pong.sh("tmux has-session -t \(b) 2>/dev/null && echo yes || echo no")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseOK == "yes" else {
            Pong.log("ensureSeatViewSession: base missing \(b)")
            return
        }
        // Detect bad “full group” views (multiple windows) and recreate as single-link
        let exists = Pong.sh("tmux has-session -t \(v) 2>/dev/null && echo yes || echo no")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
        if exists {
            let winCount = Int(Pong.sh("tmux list-windows -t \(v) 2>/dev/null | wc -l")
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            // Also detect group membership (linked to base group = can see all seats)
            let group = Pong.sh("tmux display-message -p -t \(v) '#{session_group}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if winCount > 1 || (!group.isEmpty && group == b) {
                Pong.log("ensureSeatViewSession: recreating multi/group view \(v) wins=\(winCount) group=\(group)")
                Pong.sh("tmux kill-session -t \(v) 2>/dev/null || true")
            } else {
                // Already a single-window private session — re-link source in case index moved
                Pong.sh("tmux link-window -dk -s \(b):\(idx) -t \(v):0 2>/dev/null || true")
                Pong.sh("tmux select-window -t \(v):0 2>/dev/null || true")
                // Block window switching inside this client
                lockViewToSingleWindow(v)
                return
            }
        }
        // Fresh private session with only the linked seat window
        Pong.sh("tmux new-session -d -s \(v) -n seat 2>/dev/null || true")
        // Replace default window with a hard link to base:index (only that seat)
        Pong.sh("tmux link-window -dk -s \(b):\(idx) -t \(v):0 2>/dev/null || true")
        // If link failed (index missing), fall back to group attach at that index
        let linked = Int(Pong.sh("tmux list-windows -t \(v) 2>/dev/null | wc -l")
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if linked == 0 {
            Pong.log("ensureSeatViewSession: link failed, group fallback \(v) → \(b):\(idx)")
            Pong.sh("tmux kill-session -t \(v) 2>/dev/null || true")
            Pong.sh("tmux new-session -d -s \(v) -t \(b) 2>/dev/null || true")
            Pong.sh("tmux select-window -t \(v):\(idx) 2>/dev/null || true")
        } else {
            Pong.sh("tmux select-window -t \(v):0 2>/dev/null || true")
            lockViewToSingleWindow(v)
        }
        TmuxScroll.apply(session: v)
        Pong.log("ensureSeatViewSession view=\(v) base=\(b):\(idx)")
    }

    /// Soft lock: single linked window already prevents seat-hopping; keep a simple status.
    private static func lockViewToSingleWindow(_ view: String) {
        let v = view.replacingOccurrences(of: "'", with: "")
        Pong.sh("tmux set-option -t \(v) base-index 0 2>/dev/null || true")
        // Hide the multi-window strip if anything extra sneaks in
        Pong.sh("tmux set-option -t \(v) status-left '' 2>/dev/null || true")
        Pong.sh("tmux set-option -t \(v) status-right '' 2>/dev/null || true")
    }

    /// Open a **dedicated** Terminal window that attaches to `viewSession`.
    ///
    /// Critical: plain `do script` often opens as a *tab on the front Terminal*
    /// (e.g. a free-floating Grok window). That made Open raise the wrong app.
    /// Launching a `.command` file via `open` always gets its own window.
    ///
    /// Closing this window only detaches the client — tmux (and Claude/Grok) keep running.
    /// - Parameter displayTitle: preferred custom title (e.g. `pong.session.w1`) so the
    ///   window does not sit on the frosted “tmux attach-session” chrome.
    static func openAttachSession(_ viewSession: String, displayTitle: String? = nil) -> String? {
        let safe = viewSession
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let tmux = tmuxBin
        let before = Set(TerminalTheme.listWindows().map(\.id))
        Pong.log("openAttachSession begin view=\(safe) tmux=\(tmux) beforeWindows=\(before.count)")

        // Unique marker for recovery; display title is what the user should see.
        let marker = "PONGATTACH:\(safe)"
        let shown = (displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? safe
        let safeShown = shown
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        let dir = NSTemporaryDirectory() + "pong-attach/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "\(safe)-\(Int(Date().timeIntervalSince1970)).command"
        // No EXIT trap that force-closes Terminal (that triggered “terminate processes?”).
        // exec tmux → one process; detach/close only drops this client; agents stay in base session.
        let barShown = safeShown
            .replacingOccurrences(of: " · ", with: " - ")
            .replacingOccurrences(of: "·", with: "-")
        // IMPORTANT: plain `exec tmux` (no `exec -a`). Renaming the process made Terminal
        // treat the seat as a non-clean command and show “Terminate processes?” on close.
        // Titles hide process via HP profile ShowActiveProcessInTitle=false + custom title.
        let body = """
        #!/bin/bash
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$PATH"
        printf '\\033]0;%s\\007' '\(barShown)'
        export PONG_ATTACH_MARK='\(marker)'
        if ! "\(tmux)" has-session -t "\(safe)" 2>/dev/null; then
          echo "CyberPong: tmux session '\(safe)' not found — seat may be dead." >&2
          printf '\\033]0;%s\\007' '\(barShown) offline'
          sleep 0.8
          exit 0
        fi
        "\(tmux)" set-option -t "\(safe)" destroy-unattached off 2>/dev/null || true
        "\(tmux)" set-option -t "\(safe)" set-titles on 2>/dev/null || true
        "\(tmux)" set-option -t "\(safe)" set-titles-string '\(barShown)' 2>/dev/null || true
        # Client-only attach. Close window = detach; agents keep running. No terminate prompt.
        exec "\(tmux)" attach-session -t "\(safe)"
        """
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("openAttachSession write fail \(error)")
            return nil
        }
        let qPath = path.replacingOccurrences(of: "'", with: "'\\''")
        _ = Pong.sh("chmod +x '\(qPath)'")
        // Launch WITHOUT focusing Terminal first — reduces tab-on-Grok behavior
        let openOut = Pong.sh("open '\(qPath)' 2>&1")
        if !openOut.isEmpty { Pong.log("openAttachSession open → \(openOut)") }

        func matchesOurAttach(_ title: String) -> Bool {
            let t = title.lowercased()
            if t.contains("grok ▸") || t.contains("hermes ▸") {
                if !t.contains("attach-session") && !t.contains("pong.") { return false }
            }
            if t.contains(marker.lowercased()) { return true }
            if t.contains(safeShown.lowercased()) { return true }
            if TerminalTheme.isPairAttachTitle(title, viewToken: safe) { return true }
            // Brand-new .command window still bootstrapping
            if t.contains(".command") || t.contains("tmux") || t.contains(safe.lowercased()) { return true }
            return false
        }

        var found: String?
        for attempt in 1...24 {
            usleep(120_000)
            let after = TerminalTheme.listWindows()
            if let fresh = after.first(where: { !before.contains($0.id) && matchesOurAttach($0.title) }) {
                found = fresh.id
                Pong.log("openAttachSession \(safe) → \(fresh.id) (new attempt=\(attempt)) title=\(fresh.title)")
                break
            }
            if attempt >= 3, let fresh = after.last(where: { !before.contains($0.id) }) {
                Pong.log("openAttachSession pending id=\(fresh.id) title=\(fresh.title) attempt=\(attempt)")
                if matchesOurAttach(fresh.title) || attempt >= 8 {
                    found = fresh.id
                    break
                }
            }
        }
        if let found {
            // Theme immediately so the frosted “tmux attach” chrome never sticks
            TerminalTheme.apply(
                windowId: found,
                displayTitle: safeShown,
                viewToken: safe,
                colors: nil,
                profile: TerminalTheme.profileName(pair: safe, role: "attach")
            )
            raiseTerminalWindow(found)
            return found
        }
        let titles = TerminalTheme.listWindows().map { "\($0.id):\($0.title)" }.joined(separator: " || ")
        Pong.log("openAttachSession \(safe) → FAILED (no new attach window) windows=\(titles)")
        // Do NOT fall back to do-script (that tabs onto free Grok windows)
        return nil
    }

    /// If a live Terminal is still attached to this view, raise it.
    /// If the user closed it, open a fresh attach client to the same tmux session
    /// (agents + history still running). No minimized Dock stubs.
    @discardableResult
    static func frontOrReopenAttach(
        pair: String, view: String, tmuxIndex: Int, storedWindowId: String?
    ) -> String? {
        // 1) Live attach for THIS view only (never free Grok by stored id)
        if let live = TerminalTheme.resolvePairWindow(stored: storedWindowId, viewToken: view) {
            Pong.log("frontOrReopenAttach existing view=\(view) id=\(live)")
            if raiseOnlyIfPairAttach(live, viewToken: view) {
                return live
            }
            Pong.log("frontOrReopenAttach existing refused — will reopen view=\(view)")
        } else {
            Pong.log("frontOrReopenAttach no live window view=\(view) stored=\(storedWindowId ?? "-")")
        }

        // 2) Base team session must still exist (agents live here)
        let baseOK = Pong.sh("tmux has-session -t \(pair) 2>/dev/null && echo yes || echo no")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseOK == "yes" else {
            Pong.log("frontOrReopenAttach: base tmux session missing pair=\(pair)")
            return nil
        }

        // 3) Single-window view locked to this seat (never full group — that swapped Grok→Claude)
        ensureSeatViewSession(view: view, base: pair, windowIndex: tmuxIndex)
        TmuxScroll.apply(session: pair)
        TmuxScroll.apply(session: view)

        // 4) New Terminal client — history is in tmux, not the closed window
        let title = TerminalTheme.friendlySeatTitle(pair: pair, seat: tmuxIndex == 0 ? "c1" : "w\(tmuxIndex)", seatLabel: nil)
        return openAttachSession(view, displayTitle: title)
    }

    /// Stored window ids that still exist **and** are real attach clients for this pair.
    private static func livePairWindowIds(_ name: String) -> [String] {
        var entry = PairState.loadPairsDb()[name] as? [String: Any] ?? [:]
        if entry.isEmpty {
            let cur = Pong.loadJSON(PairState.activePath)
            if cur["session"] as? String == name { entry = cur }
        }
        var ids: [String] = []
        for w in Workers.list(from: entry) {
            let wid = "\(w["window_id"] ?? "")"
            let role = (w["id"] as? String) ?? "w1"
            let token = TerminalTheme.viewToken(pair: name, role: role)
            if let live = TerminalTheme.resolvePairWindow(
                stored: Int(wid) != nil ? wid : nil, viewToken: token
            ), !ids.contains(live) {
                ids.append(live)
            }
        }
        let hTok = TerminalTheme.viewToken(pair: name, role: "hermes")
        let hStored = "\(entry["hermes_window_id"] ?? "")"
        if let live = TerminalTheme.resolvePairWindow(
            stored: Int(hStored) != nil ? hStored : nil, viewToken: hTok
        ), !ids.contains(live) {
            ids.append(live)
        }
        return ids
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
        let pathExport = TerminalTheme.panePathExport()
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
        TmuxScroll.apply(session: name)
        // Team identity: PONG_SESSION + PONG_TOKEN (isolation; Addendum 2)
        Pong.sh("tmux set-environment -t \(name) PONG_SESSION \(name)")
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_SESSION \(name)")
        Pong.sh("tmux set-environment -t \(name) PONG_ROLE conductor")
        Pong.sh("tmux set-environment -t \(name) HERMES_PONG_ROLE orchestra")
        let sessionToken = Isolation.ensureToken(session: name)
        if !sessionToken.isEmpty {
            Pong.sh("tmux set-environment -t \(name) PONG_TOKEN \(sessionToken)")
        }
        // Build launch with joinShell — never `;;` (that left conductor stuck in zsh)
        let writeBind = "python3 \"$HOME/bin/hermes_pong.py\" write-bind --session \(name) >/dev/null 2>&1 || PYTHONPATH=\"$HOME/.pong/lib${PYTHONPATH:+:$PYTHONPATH}\" python3 -m pong.cli status -s \(name) >/dev/null 2>&1 || true"
        let banner = "CONDUCTOR · \(condLabel) · \(name):0"
        var condParts: [String] = [
            pathExport,
            "export PONG_SESSION=\(name)",
            "export HERMES_PONG_SESSION=\(name)",
            "export PONG_SEAT=c1",
            "export PONG_ROLE=conductor",
            "export HERMES_PONG_ROLE=orchestra",
        ]
        if !sessionToken.isEmpty {
            condParts.append("export PONG_TOKEN=\(sessionToken)")
        }
        condParts.append(writeBind)
        condParts.append("printf \"\\n  \(banner)\\n  skill: \(skillHint) · pong gate · pong job create\\n\\n\"")
        condParts.append("exec \(safeCondCmd)")
        let condLaunch = TerminalTheme.joinShell(condParts)
        let condExact = TerminalTheme.exactSeatTitle(pair: name, seat: "c1")
        let condFriendly = "\(condLabel)"
        TerminalTheme.tmuxTitle(baseSession: name, tmuxIndex: 0, displayTitle: condFriendly)
        // -l = literal keys; single Enter to run
        let condQ = condLaunch.replacingOccurrences(of: "'", with: "'\\''")
        Pong.sh("tmux send-keys -t \(name):0 -l '\(condQ)'")
        usleep(80_000)
        Pong.sh("tmux send-keys -t \(name):0 Enter")
        Isolation.registerPane(session: name, workerId: "c1", tmuxTarget: "\(name):0", startCommand: condCmd)
        _ = condExact

        var workerRecords: [[String: Any]] = []
        for (idx, worker) in list.enumerated() {
            let wCmd = worker.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            let launchCmd = wCmd.isEmpty ? "claude" : wCmd
            let seatId = "w\(idx + 1)"
            let seatExact = TerminalTheme.exactSeatTitle(pair: name, seat: seatId)
            let winName = worker.label.replacingOccurrences(of: "'", with: "")
            Pong.sh("tmux new-window -t \(name) -n '\(winName.isEmpty ? seatExact : winName)'")
            let safeCmd = launchCmd.replacingOccurrences(of: "'", with: "'\\''")
            let wbanner = "WORKER · \(worker.label) · \(name):\(idx + 1)"
            var wParts: [String] = [
                pathExport,
                "export PONG_SESSION=\(name)",
                "export HERMES_PONG_SESSION=\(name)",
                "export PONG_SEAT=\(seatId)",
            ]
            if !sessionToken.isEmpty {
                wParts.append("export PONG_TOKEN=\(sessionToken)")
            }
            wParts.append("printf \"\\n  \(wbanner)\\n\\n\"")
            wParts.append("exec \(safeCmd)")
            let wLaunch = TerminalTheme.joinShell(wParts)
            let wQ = wLaunch.replacingOccurrences(of: "'", with: "'\\''")
            Pong.sh("tmux send-keys -t \(name):\(idx + 1) -l '\(wQ)'")
            usleep(80_000)
            Pong.sh("tmux send-keys -t \(name):\(idx + 1) Enter")
            TerminalTheme.tmuxTitle(baseSession: name, tmuxIndex: idx + 1, displayTitle: worker.label)
            let paneId = Isolation.registerPane(session: name, workerId: seatId, tmuxTarget: "\(name):\(idx + 1)", startCommand: launchCmd)
            var rec: [String: Any] = [
                "id": seatId,
                "type": worker.id,
                "label": worker.label,
                "cmd": launchCmd,
                "mode": "tmux",
                "tmux_index": idx + 1,
                "done_marker": worker.id == "claude" ? "##CLAUDE_DONE##" : "##WORKER_DONE##",
                // Durable mission role — every job + bind card reinjects this
                "mission_role": MissionRole.defaultForWorker(index: idx).rawValue,
            ]
            if !paneId.isEmpty { rec["pane_id"] = paneId }
            workerRecords.append(rec)
        }

        // One view session per seat, each with ONLY that window linked (not full group).
        // Full-group views let a click on the Grok Terminal status bar switch into Claude.
        ensureSeatViewSession(view: viewH, base: name, windowIndex: 0)
        var viewNames: [String] = []
        for idx in 0..<list.count {
            let vn = "\(name)-w\(idx)"
            viewNames.append(vn)
            ensureSeatViewSession(view: vn, base: name, windowIndex: idx + 1)
        }
        if !viewNames.isEmpty {
            // Legacy -c alias for first worker only
            ensureSeatViewSession(view: "\(name)-c", base: name, windowIndex: 1)
        }

        // Open Terminals one-by-one via .command launchers (never tab onto a free Grok window).
        let baselineWindows = Set(TerminalTheme.listWindows().map(\.id))
        var usedWindowIds = Set<String>()
        func openAttach(_ session: String, title: String) -> String? {
            guard let id = openAttachSession(session, displayTitle: title), !usedWindowIds.contains(id) else {
                if let id = openAttachSession(session, displayTitle: title) {
                    usedWindowIds.insert(id)
                    return id
                }
                return nil
            }
            usedWindowIds.insert(id)
            return id
        }
        let condWinTitle = TerminalTheme.friendlySeatTitle(pair: name, seat: "c1", seatLabel: condLabel)
        let hid = openAttach(viewH, title: condWinTitle)
        var windowIds: [String] = []
        for (idx, vn) in viewNames.enumerated() {
            let seatId = "w\(idx + 1)"
            let lab = idx < list.count ? list[idx].label : seatId
            let seatTitle = TerminalTheme.friendlySeatTitle(pair: name, seat: seatId, seatLabel: lab)
            windowIds.append(openAttach(vn, title: seatTitle) ?? "")
        }
        // Close accidental blank / duplicate launch chrome windows (not our themed seats)
        let afterAll = TerminalTheme.listWindows()
        for w in afterAll where !baselineWindows.contains(w.id) && !usedWindowIds.contains(w.id) {
            let t = w.title.lowercased()
            // Keep anything already named as a pong seat or PONGATTACH client
            if t.contains("pong.") || t.contains("pongattach:") { continue }
            // Drop leftover frosted bash/.command/login shells from open
            if t.contains(".command") || t.contains("login") || t.isEmpty
                || t.contains("bash") || (t.contains("tmux") && !t.contains("attach-session -t \(name.lowercased())")) {
                _ = Pong.osascript("""
                tell application "Terminal"
                  try
                    close window id \(w.id) saving no
                  end try
                end tell
                """)
                Pong.log("closed stray Terminal window \(w.id) title=\(w.title)")
            }
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

        // Persist default architecture immediately so handoff recaps + flow
        // enforcement match seats (do not wait for panel poll seed).
        TeamSanitizer.ensureDefaultFlowGraph(pair: name)
        TeamSanitizer.reconcile(pair: name)

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
        // First-prompt into conductor TUI (package on + gate + activate roster).
        // Wizard/saved-team paths reschedule after names land (supersedes this gen).
        let kickCtx = ConductorKickoff.contextFromStartFresh(
            session: name,
            conductor: cond,
            workers: list
        )
        ConductorKickoff.scheduleInject(session: name, context: kickCtx)
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
        TmuxScroll.apply(session: name)

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
            else if low.contains("hermes") { type = "hermes" }
            else { type = "linked" }
            let cmd = type == "linked" ? "" : (WorkerType.named(type).cmd)
            let seatId = "w\(idx + 1)"
            let tmuxIdx = idx + 1
            workers.append(Workers.makeWorker(
                id: seatId,
                type: type,
                label: label,
                windowId: wid,
                mode: mode,
                cmd: cmd,
                tmuxIndex: tmuxIdx
            ))
            if !tui {
                // Bare shell: create a real worker pane in the team session and attach.
                // Never leave the window on `printf …; true` (dead seat).
                let winName = label.replacingOccurrences(of: "'", with: "").prefix(24)
                Pong.sh("tmux new-window -t \(name) -n '\(winName)' 2>/dev/null || true")
                let idxOut = Pong.sh("tmux display-message -p -t \(name) '#{window_index}' 2>/dev/null || echo \(tmuxIdx)")
                let actualIdx = Int(idxOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? tmuxIdx
                // Prefer starting the inferred CLI so the seat is actually usable
                let launch = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                let pathExport = TerminalTheme.panePathExport()
                if !launch.isEmpty {
                    let safe = launch.replacingOccurrences(of: "'", with: "'\\''")
                    let boot = "\(pathExport); export PONG_SESSION=\(name); export PONG_SEAT=\(seatId); exec \(safe)"
                    let bq = boot.replacingOccurrences(of: "'", with: "'\\''")
                    Pong.sh("tmux send-keys -t \(name):\(actualIdx) -l '\(bq)'")
                    usleep(80_000)
                    Pong.sh("tmux send-keys -t \(name):\(actualIdx) Enter")
                }
                let attach =
                    "printf '\\n  WORKER · \(name) \(seatId) · \(name):\(actualIdx)\\n\\n'; "
                    + "exec tmux attach-session -t \(name):\(actualIdx)"
                runInTerminalWindow(wid, attach)
                usleep(150_000)
                _ = Isolation.registerPane(
                    session: name, workerId: seatId,
                    tmuxTarget: "\(name):\(actualIdx)",
                    startCommand: launch.isEmpty ? "tmux" : launch
                )
                // Keep record in sync with actual tmux index
                if var last = workers.last {
                    last["tmux_index"] = actualIdx
                    workers[workers.count - 1] = last
                }
            } else {
                Pong.log("wireArmy worker window \(wid) live TUI — register only type=\(type)")
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
        PairState.invalidatePairsCache()
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
    /// Seconds the milestone tip sheet cannot be dismissed.
    static let lockSeconds = 30
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

        // Mark shown before display so a crash mid-dialog does not re-spam forever.
        shown.insert(count)
        u["tip_milestones_shown"] = Array(shown).sorted()
        saveUsage(u)

        NSApp.activate(ignoringOtherApps: true)
        TipMilestoneSheet.shared.present(pairCount: count) { choice in
            switch choice {
            case .tip20:
                openTip20()
                Pong.log("tip milestone \(count) → stripe $20")
            case .alreadyTipped:
                var uu = loadUsage()
                uu["supporter"] = true
                uu["paid_cents"] = max((uu["paid_cents"] as? Int) ?? 0, 200)
                uu["tip_never_ask"] = true
                saveUsage(uu)
                Pong.log("tip milestone \(count) → already tipped")
            case .neverAsk:
                var uu = loadUsage()
                uu["tip_never_ask"] = true
                saveUsage(uu)
                Pong.log("tip milestone \(count) → never ask")
            case .later:
                Pong.log("tip milestone \(count) → later")
            }
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

// MARK: - Tip milestone sheet (30s lock + gratitude copy)

/// Modal panel: no close/Escape/buttons for `Tips.lockSeconds`, then normal dismiss.
private final class TipLockPanel: NSPanel {
    var dismissLocked = true
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if dismissLocked { return }
        super.cancelOperation(sender)
    }
    override func performClose(_ sender: Any?) {
        if dismissLocked { return }
        super.performClose(sender)
    }
    override func close() {
        if dismissLocked { return }
        super.close()
    }
}

private final class TipMilestoneSheet: NSObject {
    static let shared = TipMilestoneSheet()

    enum Choice {
        case tip20, alreadyTipped, later, neverAsk
    }

    private var panel: TipLockPanel?
    private var actionButtons: [NSButton] = []
    private var countdownLabel: NSTextField?
    private var timer: Timer?
    private var remaining = Tips.lockSeconds
    private var completion: ((Choice) -> Void)?

    func present(pairCount: Int, completion: @escaping (Choice) -> Void) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        self.completion = completion
        remaining = Tips.lockSeconds

        let W: CGFloat = 460
        let H: CGFloat = 340
        let win = TipLockPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled], // no .closable while locked
            backing: .buffered,
            defer: false
        )
        win.dismissLocked = true
        win.title = "Thank you for using \(PongTheme.productName)!"
        win.isFloatingPanel = true
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.backgroundColor = PongTheme.bg
        win.center()

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        win.contentView = root

        let title = NSTextField(labelWithString: "Thank you for using \(PongTheme.productName)!")
        title.font = PongTheme.font(16, weight: .semibold)
        title.textColor = PongTheme.textPrimary
        title.frame = NSRect(x: 24, y: H - 48, width: W - 48, height: 24)
        root.addSubview(title)

        let bodyText =
            "Thank you for using this app! You are saving a lot of API money here!\n\n" +
            "As a developer and one-man builder, it's always great to build something that others enjoy and use. Tips from users are how I can continue to sustain my life and building great apps.\n\n" +
            "So if you like this, and it even saves you from those API credit costs, a tip would be greatly appreciated!\n\n" +
            "(Milestone: \(countLabel(pairCount)) pairs linked.)"
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = PongTheme.font(12)
        body.textColor = PongTheme.textSecondary
        body.frame = NSRect(x: 24, y: 108, width: W - 48, height: 170)
        body.maximumNumberOfLines = 0
        root.addSubview(body)

        let countDown = NSTextField(labelWithString: "You can continue in \(remaining)…")
        countDown.font = PongTheme.mono(11, weight: .medium)
        countDown.textColor = PongTheme.amber
        countDown.alignment = .center
        countDown.frame = NSRect(x: 24, y: 78, width: W - 48, height: 18)
        root.addSubview(countDown)
        countdownLabel = countDown

        // Buttons: Tip $20 · I already tipped · Maybe later · Don't ask again
        let labels = ["Tip $20", "I already tipped", "Maybe later", "Don't ask again"]
        let widths: [CGFloat] = [88, 118, 100, 118]
        actionButtons = []
        let gap: CGFloat = 8
        let totalW = widths.reduce(0, +) + gap * CGFloat(labels.count - 1)
        var x = max(16, (W - totalW) / 2)
        for (i, lab) in labels.enumerated() {
            let b = NSButton(title: lab, target: self, action: #selector(choicePressed(_:)))
            b.bezelStyle = .rounded
            b.tag = i
            b.isEnabled = false
            b.frame = NSRect(x: x, y: 28, width: widths[i], height: 28)
            root.addSubview(b)
            actionButtons.append(b)
            x += widths[i] + gap
        }

        panel = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Block until choice (after unlock)
        NSApp.runModal(for: win)
    }

    private func countLabel(_ n: Int) -> String { "\(n)" }

    private func tick() {
        remaining -= 1
        if remaining > 0 {
            countdownLabel?.stringValue = "You can continue in \(remaining)…"
            countdownLabel?.textColor = PongTheme.amber
            return
        }
        unlock()
    }

    private func unlock() {
        timer?.invalidate()
        timer = nil
        remaining = 0
        countdownLabel?.stringValue = "Thanks for reading — choose an option below."
        countdownLabel?.textColor = PongTheme.textSecondary
        for b in actionButtons {
            b.isEnabled = true
        }
        actionButtons.first?.keyEquivalent = "\r"
        panel?.dismissLocked = false
        Pong.log("tip milestone unlocked after \(Tips.lockSeconds)s")
    }

    @objc private func choicePressed(_ sender: NSButton) {
        // Buttons stay disabled until unlock; double-check lock state.
        guard remaining <= 0, panel?.dismissLocked == false, sender.isEnabled else { return }
        let choice: Choice
        switch sender.tag {
        case 0: choice = .tip20
        case 1: choice = .alreadyTipped
        case 3: choice = .neverAsk
        default: choice = .later
        }
        finish(choice)
    }

    private func finish(_ choice: Choice) {
        timer?.invalidate()
        timer = nil
        panel?.dismissLocked = false
        let cb = completion
        completion = nil
        if let p = panel {
            p.orderOut(nil)
            NSApp.stopModal()
        }
        panel = nil
        actionButtons = []
        countdownLabel = nil
        cb?(choice)
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
        PongTheme.registerBundledFonts()
        installMainMenu()
        // Existing pair terminals: enable mouse scroll + deep history immediately
        TmuxScroll.applyAllLive()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = PongTheme.menuIcon(signal: .idle, phase: 0)
            button.image?.isTemplate = false
            button.title = ""
            button.toolTip = "\(PongTheme.productName) — agent mission control"
            button.appearsDisabled = false
        }
        statusItem.isVisible = true
        rebuildMenu()

        // 0.5s menu icon pulse is enough — 0.1s was main-thread noise
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        // Always open the control panel on 3D first — show the product promise.
        // App AI onboarding (provider + first team) layers on top when needed.
        Isolation.seedControlPlaneIfNeeded()
        try? FileManager.default.createDirectory(
            atPath: Pong.stateDir, withIntermediateDirectories: true)
        // Tighten state dir perms (review: world-readable prompts)
        _ = Pong.sh("chmod 700 \"\(Pong.stateDir)\" 2>/dev/null || true")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.openPanel()
            PanelController.shared.ensure3DVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let needsAI = !AppAISettings.onboardingComplete || AppAISettings.providerId == nil
                if needsAI {
                    AppAIOnboarding.presentIfNeeded(force: AppAISettings.providerId == nil)
                } else if !self.isOnboarded {
                    // Legacy permissions-only path
                    self.showOnboarding()
                } else {
                    AppAIChatBubble.shared.attachIfNeeded()
                    if AppAISettings.headlessReady {
                        AppAIChatBubble.shared.nudge("Guide online")
                    }
                    MapCoachMarks.presentIfNeeded()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "CyberPong")
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About CyberPong", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())

        let open = NSMenuItem(title: "Open Control Panel", action: #selector(openPanel), keyEquivalent: "o")
        open.keyEquivalentModifierMask = [.command]
        open.target = self
        appMenu.addItem(open)

        let guide = NSMenuItem(title: "CyberPong Guide…", action: #selector(openGuide), keyEquivalent: "g")
        guide.keyEquivalentModifierMask = [.command]
        guide.target = self
        appMenu.addItem(guide)

        let switchAcct = NSMenuItem(title: "Switch AI account…", action: #selector(switchProviderAccount), keyEquivalent: "")
        switchAcct.target = self
        appMenu.addItem(switchAcct)

        let tip = NSMenuItem(title: "Tip developer…", action: #selector(tipDeveloper), keyEquivalent: "")
        tip.target = self
        appMenu.addItem(tip)
        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit CyberPong", action: #selector(quitAll), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        appMenu.addItem(quit)

        // Edit menu — FirstResponder chain so ⌘C/⌘V work in text fields
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        func editCmd(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = [.command]
            // No target — system FirstResponder (field editor) receives cut/copy/paste
            return i
        }
        editMenu.addItem(editCmd("Undo", Selector(("undo:")), "z"))
        editMenu.addItem(editCmd("Redo", Selector(("redo:")), "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(editCmd("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(editCmd("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(editCmd("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(editCmd("Select All", #selector(NSText.selectAll(_:)), "a"))

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
        alert.messageText = "CyberPong"
        alert.informativeText = "\(PongTheme.productTagline).\nOrchestrator + multi-CLI workers on a mission map."
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
            "CyberPong links orchestrator and worker Terminal windows. macOS asks once for each permission below.",
            muted: true))

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("Automation", bold: true))
        stack.addArrangedSubview(label(
            "CyberPong can send tasks into Terminal windows. macOS prompts the first time — re-enable in Settings if you decline.",
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
            "Everything — teams, jobs, and the verdict ledger — stays on this Mac. Nothing is sent anywhere.",
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
        window.title = "Welcome to CyberPong"
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
        try? FileManager.default.createDirectory(atPath: Pong.stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: onboardedFlagPath, contents: Data())
        onboardingWindow?.close()
        onboardingWindow = nil
        openPanel()
        PanelController.shared.ensure3DVisible()
        // If App AI provider not chosen yet, continue into guide
        if AppAISettings.providerId == nil {
            AppAIOnboarding.present()
        }
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
            button.toolTip = "\(PongTheme.productName) — idle"
        case .orchestratorWorking:
            button.toolTip = "\(PongTheme.productName) — orchestrator working"
        case .humanNeeded:
            button.toolTip = "\(PongTheme.productName) — human input needed"
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

    /// Status-item menu: icon only needs panel / tip / quit (control plane lives in the panel).
    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Open control panel", #selector(openPanel)))
        menu.addItem(item("CyberPong Guide…", #selector(openGuide)))
        menu.addItem(item("Tip developer…", #selector(tipDeveloper)))
        menu.addItem(.separator())
        menu.addItem(item("Quit CyberPong", #selector(quitAll)))
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
        PanelController.shared.ensure3DVisible()
    }

    @objc func openGuide() {
        openPanel()
        AppAIOnboarding.present()
    }

    /// Sequential multi-account: clear ready flag, login Terminal, one active account per provider.
    @objc func switchProviderAccount() {
        NSApp.activate(ignoringOtherApps: true)
        let providers: [(String, String)] = [
            ("grok", "Grok"),
            ("claude", "Claude"),
            ("hermes", "Hermes"),
            ("codex", "Codex / OpenAI"),
        ]
        let a = NSAlert()
        a.messageText = "Switch AI account"
        a.informativeText = "One active login per provider for now. Pick which CLI to re-authenticate — all seats of that type share it until you switch again."
        for (_, label) in providers {
            a.addButton(withTitle: label)
        }
        a.addButton(withTitle: "Cancel")
        let resp = a.runModal()
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard idx >= 0, idx < providers.count else { return }
        let typeId = providers[idx].0
        ProviderAuth.switchAccount(typeId: typeId) { result in
            switch result {
            case .ok:
                AppAIChatBubble.shared.nudge("\(providers[idx].1) account ready")
            case .missingCLI(let msg):
                let e = NSAlert()
                e.messageText = "CLI missing"
                e.informativeText = msg
                e.runModal()
            case .cancelled:
                break
            case .failed(let msg):
                let e = NSAlert()
                e.messageText = "Switch failed"
                e.informativeText = msg
                e.runModal()
            }
        }
    }

    @objc func newPair() {
        Self.launchTeamWithOptionalWizard { [weak self] in
            self?.lastSessionPoll = .distantPast
            self?.rebuildMenu()
            PanelController.shared.refreshUI()
        }
    }

    /// Default: chooser → Create new (Quick Team recipes) or Open saved. Advanced wizard still inside Quick Team.
    static func launchTeamWithOptionalWizard(completion: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let hasSaved = !SavedTeams.loadAll().isEmpty

        let chooser = NSAlert()
        chooser.messageText = "New team"
        chooser.informativeText = hasSaved
            ? "Create a new team, or open one you already saved."
            : "Create a new team. Save one later from an active pair’s Options to reopen it here."
        chooser.addButton(withTitle: "Create new")
        if hasSaved {
            chooser.addButton(withTitle: "Open saved…")
        }
        chooser.addButton(withTitle: "Cancel")

        let response = chooser.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        if response == first {
            QuickTeamBuilder.present(completion: completion)
            return
        }
        if hasSaved && response == NSApplication.ModalResponse(rawValue: first.rawValue + 1) {
            if pickAndSpawnSavedTeam() {
                completion?()
            }
            return
        }
        // Cancel — no-op
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
            ? "Pick one worker under the conductor"
            : "Build a team (vertical list)")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 20, y: y - 20, width: W - 40, height: 22)
        content.addSubview(title)
        y -= 36

        let sub = NSTextField(wrappingLabelWithString: mode == .oneModel
            ? "One worker seat + conductor. Same active team row."
            : "Add seats top → bottom. One conductor plans for the team.")
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
        PongSheetChrome.styleWindow(win, title: "Seat policy")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating

        let content = PongSheetChrome.rootView(width: W, height: H)
        contentRoot = content
        let PAD: CGFloat = 22
        var y = H - PAD - 8

        let title = PongSheetChrome.titleLabel("Session access policy", frame: NSRect(x: PAD, y: y - 20, width: W - 2 * PAD, height: 22))
        content.addSubview(title)
        y -= 28

        let sub = PongSheetChrome.bodyLabel(
            "Checked boxes ban that access on every handoff. “Ask each time” requires elevated access approval in chat first. Live layer only — not standing grants.",
            frame: NSRect(x: PAD, y: y - 48, width: W - 2 * PAD, height: 48))
        content.addSubview(sub)
        y -= 56

        content.addSubview(PongSheetChrome.hairline(x: PAD, y: y, width: W - 2 * PAD))
        y -= 14

        let presetLbl = PongSheetChrome.sectionLabel("Presets", frame: NSRect(x: PAD, y: y - 14, width: 120, height: 14))
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
            window?.title = "Seat policy · \(pairName) / \(workerId)"
            let perms = Workers.permissions(pair: pairName, workerId: workerId)
            applyPermissionsToUI(perms, status: matchStatus(for: perms))
        } else {
            window?.title = "Seat policy · \(pairName) (team / all seats)"
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
        PongLoadingOverlay.hide()
        window?.orderOut(nil)
    }

    @objc private func savePressed() {
        let perms = currentPermissionsFromUI()
        let pair = pairName
        let wid = workerId
        let done = onSaved
        PongLoadingOverlay.show(on: window, message: "Saving policy…")
        DispatchQueue.global(qos: .userInitiated).async {
            if let wid {
                Workers.setPermissions(pair: pair, workerId: wid, permissions: perms)
                Pong.log("permissions \(pair)/\(wid) -> \(perms)")
            } else {
                let prev = PairState.loadPairsDb()[pair] as? [String: Any] ?? [:]
                PairState.savePairState(
                    pair,
                    hermesWindowId: prev["hermes_window_id"] as? String,
                    claudeWindowId: prev["claude_window_id"] as? String,
                    claudeMode: prev["claude_mode"] as? String,
                    permissions: perms
                )
                Pong.log("permissions \(pair) -> \(perms)")
            }
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                self.window?.orderOut(nil)
                done?()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        PongLoadingOverlay.hide()
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

    /// Snapshot field values on the main thread (fields must be read on main).
    private func captureFields() -> (name: String, root: String, brief: String) {
        (
            nameField.stringValue,
            rootField.stringValue,
            briefView.string
        )
    }

    /// Write the sheet fields onto the live pair (pairs.json + active-pair.json
    /// when this session is active) and mirror the brief file.
    private func persistFields(name: String? = nil, root: String? = nil, brief: String? = nil, applyTheme: Bool = true) {
        let snap = captureFields()
        Workers.setTeamOptions(
            pairName,
            displayName: name ?? snap.name,
            projectRoot: root ?? snap.root,
            teamBrief: brief ?? snap.brief,
            applyTheme: applyTheme
        )
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
        let snap = captureFields()
        let suggestion = snap.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = suggestion.isEmpty ? pairName : suggestion
        let cronCount = CronSchedule.load(session: pairName).count

        let alert = NSAlert()
        alert.messageText = "Save team as…"
        alert.informativeText = "Choose a name and what to include. Saved teams spawn under Show Teams."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))
        let field = NSTextField(frame: NSRect(x: 0, y: 140, width: 320, height: 24))
        field.stringValue = seed
        field.placeholderString = "Team name"
        box.addSubview(field)

        func check(_ title: String, y: CGFloat, on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = on ? .on : .off
            b.frame = NSRect(x: 0, y: y, width: 320, height: 20)
            b.font = PongTheme.font(12)
            box.addSubview(b)
            return b
        }
        let cWorkers = check("Workers · labels · commands", y: 112, on: true)
        cWorkers.isEnabled = false // always required
        let cColors = check("Colors (conductor + workers)", y: 90, on: true)
        let cPerms = check("Per-worker permissions", y: 68, on: true)
        let cRoot = check("Project root", y: 46, on: true)
        let cBrief = check("Team brief", y: 24, on: true)
        let cCron = check("Cron jobs (\(cronCount))", y: 2, on: true)

        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var opts = SavedTeams.SaveOptions()
        opts.workers = true
        opts.colors = cColors.state == .on
        opts.perms = cPerms.state == .on
        opts.projectRoot = cRoot.state == .on
        opts.teamBrief = cBrief.state == .on
        opts.cronJobs = cCron.state == .on

        let pair = pairName
        let done = onSaved
        PongLoadingOverlay.show(on: window, message: "Saving team…")
        DispatchQueue.global(qos: .userInitiated).async {
            Workers.setTeamOptions(
                pair,
                displayName: snap.name,
                projectRoot: snap.root,
                teamBrief: snap.brief,
                applyTheme: true
            )
            let team = SavedTeams.saveFromLivePair(pair, teamName: name, options: opts)
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                let a = NSAlert()
                if let team {
                    a.messageText = "Team saved"
                    var bits: [String] = ["workers"]
                    if opts.colors { bits.append("colors") }
                    if opts.perms { bits.append("perms") }
                    if opts.projectRoot { bits.append("project root") }
                    if opts.teamBrief { bits.append("brief") }
                    if opts.cronJobs {
                        bits.append("\(team.cronJobs.count) cron job\(team.cronJobs.count == 1 ? "" : "s")")
                    }
                    a.informativeText = "“\(name)” is under Show Teams…\nIncludes: \(bits.joined(separator: " · "))."
                } else {
                    a.messageText = "Nothing to save"
                    a.informativeText = "This pair has no workers yet."
                }
                a.addButton(withTitle: "OK")
                a.runModal()
                done?()
            }
        }
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
        let snap = captureFields()
        let pair = pairName
        let done = onSaved
        PongLoadingOverlay.show(on: window, message: "Saving options…")
        DispatchQueue.global(qos: .userInitiated).async {
            Workers.setTeamOptions(
                pair,
                displayName: snap.name,
                projectRoot: snap.root,
                teamBrief: snap.brief,
                applyTheme: true
            )
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                self.window?.orderOut(nil)
                done?()
            }
        }
    }

    @objc private func cancelPressed() {
        PongLoadingOverlay.hide()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PongLoadingOverlay.hide()
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
        win.title = "\(PongTheme.productName) — Link team"
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

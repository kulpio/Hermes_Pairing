import AppKit
import Foundation

/// App AI provider runtime: interactive login Terminal → headless chat only.
/// After the user signs in / picks a model, we close the visible TUI so they
/// cannot freestyle-chat outside CyberPong’s map bubble.
enum AppAIRuntime {
    private static let historyPath = { Pong.stateDir + "/app-ai/history.jsonl" }()
    private static let statePath = { Pong.stateDir + "/app-ai/runtime.json" }()
    private static var loginWindowId: String?
    private static var loginCommandPath: String?

    // MARK: - Settings bridge

    static var isHeadlessReady: Bool {
        if let b = AppAISettings.appAIDict()["headless_ready"] as? Bool { return b }
        return false
    }

    static func markHeadlessReady(_ ready: Bool = true) {
        AppAISettings.save { root in
            var ai = root["app_ai"] as? [String: Any] ?? [:]
            ai["headless_ready"] = ready
            if ready {
                ai["ready_at"] = Date().timeIntervalSince1970
                ai.removeValue(forKey: "disconnect_reason")
            } else {
                ai["disconnected_at"] = Date().timeIntervalSince1970
            }
            root["app_ai"] = ai
        }
        writeRuntime(["headless_ready": ready, "updated": Date().timeIntervalSince1970])
    }

    static func markDisconnected(reason: String) {
        AppAISettings.save { root in
            var ai = root["app_ai"] as? [String: Any] ?? [:]
            ai["headless_ready"] = false
            ai["disconnect_reason"] = reason
            ai["disconnected_at"] = Date().timeIntervalSince1970
            root["app_ai"] = ai
        }
        writeRuntime([
            "headless_ready": false,
            "disconnect_reason": reason,
            "updated": Date().timeIntervalSince1970,
        ])
        Pong.log("AppAIRuntime disconnected: \(reason)")
    }

    private static func writeRuntime(_ d: [String: Any]) {
        try? FileManager.default.createDirectory(
            atPath: Pong.stateDir + "/app-ai", withIntermediateDirectories: true)
        var cur = Pong.loadJSON(statePath)
        for (k, v) in d { cur[k] = v }
        Pong.writeJSON(statePath, cur)
    }

    // MARK: - Process env / binary resolve

    /// PATH for headless Guide (must include ~/.grok/bin so Dock-launched app finds `grok`).
    static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pong.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["HOME"] = NSHomeDirectory()
        return env
    }

    /// Absolute path for a bare command name, or nil if missing.
    static func resolveBinary(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.grok/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/bin/\(name)",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let found = Pong.sh("command -v \(name.replacingOccurrences(of: "'", with: "")) 2>/dev/null")
        if !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    private static func runHeadless(argv: [String], timeoutSec: TimeInterval? = nil) -> (status: Int32, stdout: String, stderr: String) {
        guard !argv.isEmpty else {
            return (127, "", "empty argv")
        }
        let p = Process()
        var args = argv
        if let abs = resolveBinary(argv[0]) {
            p.executableURL = URL(fileURLWithPath: abs)
            args = Array(argv.dropFirst())
            p.arguments = args
        } else {
            // Fall back to env so error text stays familiar; still inject full PATH
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
        }
        p.environment = processEnvironment()
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return (127, "", error.localizedDescription)
        }
        if let timeoutSec {
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                p.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: .now() + timeoutSec) == .timedOut {
                p.terminate()
                return (124, "", "timeout")
            }
        } else {
            p.waitUntilExit()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stdout, stderr)
    }

    // MARK: - Login Terminal

    /// Open provider CLI in a dedicated Terminal window for login / model pick.
    @discardableResult
    static func openLoginTerminal(provider: AppAISettings.Provider? = nil) -> String? {
        let p = provider ?? AppAISettings.provider ?? .named("grok")
        closeLoginTerminal()

        let dir = NSTemporaryDirectory() + "pong-app-ai/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "login-\(p.id)-\(Int(Date().timeIntervalSince1970)).command"
        let title = "CyberPong · \(p.label) · sign in"
        let safeTitle = title.replacingOccurrences(of: "'", with: "")
        let cmd = p.interactiveCmd
        // Resolve absolute binary when possible so Terminal works even with thin PATH
        let resolved = resolveBinary(cmd.split(separator: " ").first.map(String.init) ?? cmd)
        let execLine: String = {
            if let resolved, !cmd.contains(" ") {
                return resolved
            }
            if let resolved, cmd.contains(" ") {
                let rest = cmd.split(separator: " ").dropFirst().joined(separator: " ")
                return "\"\(resolved)\" \(rest)"
            }
            return cmd
        }()
        let body = """
        #!/bin/bash
        export PATH="\(Pong.extraPath):$PATH"
        printf '\\033]0;\(safeTitle)\\007'
        clear
        echo ""
        echo "  CyberPong Guide — \(p.label)"
        echo "  Sign in / pick your model here."
        echo "  After you sign in, it is SAFE to close this window."
        echo "  Prefer: return to CyberPong → tap I'm signed in (we close it for you)."
        echo "  Closing does not log you out — the CLI keeps your session."
        echo ""
        exec \(execLine)
        """
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("AppAIRuntime login write fail \(error)")
            return nil
        }
        _ = Pong.sh("chmod +x '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
        let before = Set(TerminalTheme.listWindows().map(\.id))
        _ = Pong.sh("open '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
        loginCommandPath = path

        // Resolve window id (async poll briefly)
        var found: String?
        for _ in 0..<20 {
            usleep(150_000)
            let after = TerminalTheme.listWindows()
            for w in after where !before.contains(w.id) {
                let t = w.title.lowercased()
                if t.contains("cyberpong") || t.contains(p.id) || t.contains(p.label.lowercased())
                    || t.contains("login") || t.contains(cmd.split(separator: " ").first.map(String.init)?.lowercased() ?? "§") {
                    found = w.id
                    break
                }
            }
            if found == nil, let newest = after.map(\.id).filter({ !before.contains($0) }).last {
                found = newest
            }
            if found != nil { break }
        }
        loginWindowId = found
        writeRuntime([
            "login_window_id": found as Any,
            "provider": p.id,
            "login_cmd": cmd,
        ])
        Pong.log("AppAIRuntime openLogin provider=\(p.id) window=\(found ?? "-")")
        return found
    }

    /// Close the login Terminal so the user cannot freestyle that chat.
    static func closeLoginTerminal() {
        if let id = loginWindowId, Int(id) != nil {
            _ = Pong.osascript("""
            tell application "Terminal"
              try
                close window id \(id) saving no
              end try
            end tell
            """)
            Pong.log("AppAIRuntime closed login window \(id)")
        }
        loginWindowId = nil
        if let path = loginCommandPath {
            try? FileManager.default.removeItem(atPath: path)
            loginCommandPath = nil
        }
    }

    /// User confirmed signed in → close TUI, probe headless, mark ready only if CLI works.
    static func completeLogin(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            closeLoginTerminal()
            let probe = probeHeadless()
            DispatchQueue.main.async {
                let pid = AppAISettings.providerId ?? "grok"
                if probe.ok {
                    markHeadlessReady(true)
                    ProviderAuth.markReady(typeId: pid, ready: true)
                    completion(true, "Connected · \(AppAISettings.provider?.label ?? "AI") ready")
                } else if isMissingBinary(probe.detail) {
                    markDisconnected(reason: probe.detail)
                    ProviderAuth.markReady(typeId: pid, ready: false)
                    completion(false, "CLI not found — install \(AppAISettings.provider?.label ?? "provider") or fix PATH")
                } else {
                    // Interactive login often works even when -p probe is flaky
                    markHeadlessReady(true)
                    ProviderAuth.markReady(typeId: pid, ready: true)
                    completion(true, "Signed in · Guide uses \(AppAISettings.provider?.label ?? "AI") headless")
                }
            }
        }
    }

    private static func probeHeadless() -> (ok: Bool, detail: String) {
        guard let argv = AppAISettings.headlessArgv(prompt: "Reply with exactly: PONG_OK") else {
            return (false, "no provider")
        }
        if resolveBinary(argv[0]) == nil {
            return (false, "env: \(argv[0]): No such file or directory")
        }
        let r = runHeadless(argv: argv, timeoutSec: 12)
        let text = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if isMissingBinary(text) || r.status == 127 {
            return (false, text.isEmpty ? "command not found: \(argv[0])" : text)
        }
        let ok = r.status == 0 || text.uppercased().contains("PONG")
        return (ok, "exit=\(r.status) chars=\(text.count)")
    }

    // MARK: - Disconnect detection

    static func isMissingBinary(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("no such file or directory") { return true }
        if t.contains("command not found") { return true }
        if t.contains("not found") && (t.contains("env:") || t.contains("executable")) { return true }
        return false
    }

    static func isAuthDisconnect(_ text: String) -> Bool {
        let t = text.lowercased()
        let keys = [
            "not logged in", "please log in", "login required", "unauthenticated",
            "unauthorized", "auth required", "sign in", "not authenticated",
            "invalid api key", "api key", "session expired", "token expired",
        ]
        return keys.contains(where: { t.contains($0) })
    }

    static func isDisconnectSignal(status: Int32, text: String, argv0: String) -> Bool {
        if status == 127 { return true }
        if isMissingBinary(text) { return true }
        if isAuthDisconnect(text) { return true }
        // Bare "env: grok: …" style
        if text.lowercased().contains("env:") && text.lowercased().contains(argv0.lowercased()) {
            return true
        }
        return false
    }

    // MARK: - Headless chat

    static let systemPreamble = """
    You are CyberPong Guide — the in-app co-pilot for CyberPong (local multi-agent mission control on Mac).
    Help the user with: team architecture, mission roles (coder/reviewer/operator/…), flow edges (delegate/claim/peer), and using the 3D map.
    Keep replies SHORT (2–6 lines unless asked for detail). Prefer concrete next steps.
    You receive a LIVE TEAM STATE block — trust pane_id presence. Seats marked NO_PANE are ghosts (map only).
    Never invent live work on ghost seats. To spawn for real, tell the user to use map + or write an apply line:
      ** apply add_subagent type=hermes parent=c1 **
      ** apply remove w3 **
    If recommending architecture, use lines like: ** set w2 role=reviewer ** or ** claim path w1→c1 **.
    """

    /// Outcome of a Guide chat turn.
    enum ChatResult {
        case reply(String)
        /// Headless CLI missing, auth expired, etc. — UI should offer reconnect.
        case disconnected(reason: String, userFacing: String)
    }

    /// Send a user message to the headless provider.
    static func chat(userMessage: String, completion: @escaping (ChatResult) -> Void) {
        let msg = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            completion(.reply("(empty message)"))
            return
        }
        guard AppAISettings.providerId != nil else {
            completion(.disconnected(
                reason: "no provider",
                userFacing: "No AI provider selected. Reconnect to pick Grok / Claude / OpenAI."
            ))
            return
        }

        // Not ready → don't fake a long answer; prompt reconnect
        if !isHeadlessReady {
            completion(.disconnected(
                reason: "not ready",
                userFacing: "Guide is offline. Open the sign-in Terminal, sign in, then tap I’m signed in (safe to close that window after)."
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            appendHistory(role: "user", text: msg)
            let prompt = buildPrompt(user: msg)
            guard let argv = AppAISettings.headlessArgv(prompt: prompt) else {
                DispatchQueue.main.async {
                    completion(.disconnected(
                        reason: "no argv",
                        userFacing: "Guide can’t build a headless command. Reconnect your provider."
                    ))
                }
                return
            }
            let argv0 = argv[0]
            if resolveBinary(argv0) == nil {
                let reason = "env: \(argv0): No such file or directory"
                markDisconnected(reason: reason)
                DispatchQueue.main.async {
                    completion(.disconnected(
                        reason: reason,
                        userFacing: "Can’t find **\(argv0)** on PATH. Reconnect opens a login Terminal (we fix PATH), then Guide goes headless again."
                    ))
                }
                return
            }

            let r = runHeadless(argv: argv)
            var text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let errText = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = errText }
            let combined = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)

            if isDisconnectSignal(status: r.status, text: combined, argv0: argv0) {
                markDisconnected(reason: combined.isEmpty ? "exit \(r.status)" : String(combined.prefix(200)))
                let friendly: String = {
                    if isMissingBinary(combined) {
                        return "Guide lost the CLI (**\(argv0)** not found). Reconnect via sign-in Terminal."
                    }
                    if isAuthDisconnect(combined) {
                        return "Guide session expired or not signed in. Reconnect via sign-in Terminal."
                    }
                    return "Guide disconnected (\(r.status)). Reconnect via sign-in Terminal."
                }()
                DispatchQueue.main.async {
                    completion(.disconnected(reason: combined, userFacing: friendly))
                }
                return
            }

            if text.isEmpty || (r.status != 0 && text.count < 8) {
                // Soft failure — rules fallback, stay connected
                text = rulesReply(for: msg)
            }
            if text.count > 2500 {
                text = String(text.prefix(2500)) + "…"
            }
            appendHistory(role: "assistant", text: text)
            DispatchQueue.main.async {
                completion(.reply(text))
            }
        }
    }

    private static func buildPrompt(user: String) -> String {
        var recent = loadRecentHistory(limit: 6)
        recent.append(["role": "user", "text": user])
        let hist = recent.map { r in
            let role = (r["role"] as? String) == "assistant" ? "Guide" : "User"
            return "\(role): \((r["text"] as? String) ?? "")"
        }.joined(separator: "\n")
        let provider = AppAISettings.provider?.label ?? "AI"
        let teamCtx = GuideCoach.teamContextBlock()
        return """
        \(systemPreamble)

        Provider: \(provider) (headless — user cannot see this TUI).

        \(teamCtx)

        Conversation:
        \(hist)

        Guide:
        """
    }

    private static func rulesReply(for msg: String) -> String {
        let m = msg.lowercased()
        if m.contains("review") {
            return "Add a **Reviewer** seat and a review edge from coder → reviewer.\nClaims still follow the claim path (usually → orch or parent).\nOpen Architecture or ask me to walk the edges."
        }
        if m.contains("claim") {
            return "Claim path is a hard road: worker → target on the **claim** edge.\nPreview: `pong architecture recap --seat w1`.\nHop-skips are refused by the control plane."
        }
        if m.contains("role") || m.contains("who") {
            return "Roles stay locked per seat for the life of the team.\nEvery job injects **SEAT IDENTITY**. Change roles only via Architecture / Guide — not by freestyle chat in agent TUIs."
        }
        if m.contains("team") || m.contains("start") {
            return "New team: New team in the toolbar, or re-run **Guide**.\nDefault road: orch ↔ coder (+ reviewer optional), claims back to orch."
        }
        if m.contains("sub") || m.contains("hermes") || m.contains("dead") {
            return "Map cubes only mean the seat is in the roster. Live work needs a **tmux pane + Terminal**.\nAdd seats with **+** on the map (not Guide JSON edits). Ghost Hermes seats: remove them, re-add via +."
        }
        return "I’m CyberPong Guide. Ask about roles, claims, architecture edges, or first-team setup.\nShort tips: stay on the architecture road · jobs are truth · `pong gate` when unsure."
    }

    // MARK: - History

    private static func appendHistory(role: String, text: String) {
        try? FileManager.default.createDirectory(
            atPath: Pong.stateDir + "/app-ai", withIntermediateDirectories: true)
        let line = (try? JSONSerialization.data(withJSONObject: [
            "ts": Date().timeIntervalSince1970,
            "role": role,
            "text": text,
        ])) .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !line.isEmpty else { return }
        let url = URL(fileURLWithPath: historyPath)
        if !FileManager.default.fileExists(atPath: historyPath) {
            try? Data().write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }

    private static func loadRecentHistory(limit: Int) -> [[String: Any]] {
        guard let raw = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return [] }
        let lines = raw.split(separator: "\n").suffix(limit)
        var out: [[String: Any]] = []
        for line in lines {
            if let data = String(line).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }

    struct RuntimeError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

extension AppAISettings {
    static func appAIDict() -> [String: Any] {
        (load()["app_ai"] as? [String: Any]) ?? [:]
    }
}

extension AppAISettings.Provider {
    /// Command launched in the visible login Terminal.
    var interactiveCmd: String {
        switch id {
        case "grok": return "grok"
        case "claude": return "claude"
        case "openai":
            let hasCodex = !(Pong.sh("command -v codex 2>/dev/null").isEmpty)
            return hasCodex ? "codex" : "openai"
        default: return cmd
        }
    }
}

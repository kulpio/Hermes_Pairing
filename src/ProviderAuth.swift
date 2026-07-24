import AppKit
import Foundation

/// Shared CLI install + login gate for team/agent create and sequential account switch.
/// Each provider (claude/grok/hermes/codex) owns its own credentials; we only open
/// a login Terminal and mark “ready” after the user confirms.
enum ProviderAuth {
    private static var loginWindowId: String?
    private static var loginCommandPath: String?

    // MARK: - Public API

    enum GateResult {
        case ok
        case missingCLI(message: String)
        case cancelled
        case failed(message: String)
    }

    /// Map seat/type id → primary binary name.
    static func binaryName(for typeId: String) -> String {
        switch typeId.lowercased() {
        case "grok": return "grok"
        case "claude": return "claude"
        case "hermes": return "hermes"
        case "codex", "openai":
            return AppAIRuntime.resolveBinary("codex") != nil ? "codex" : "openai"
        default:
            // custom: first token of cmd if present
            return typeId
        }
    }

    static func displayLabel(for typeId: String) -> String {
        switch typeId.lowercased() {
        case "grok": return "Grok"
        case "claude": return "Claude"
        case "hermes": return "Hermes"
        case "codex", "openai": return "OpenAI / Codex"
        default: return typeId
        }
    }

    static func interactiveCmd(for typeId: String) -> String {
        switch typeId.lowercased() {
        case "grok": return "grok"
        case "claude": return "claude"
        case "hermes": return "hermes chat"
        case "codex": return "codex"
        case "openai": return binaryName(for: "openai")
        default: return typeId
        }
    }

    /// Absolute path or nil if not installed.
    static func resolveInstall(typeId: String) -> String? {
        let bin = binaryName(for: typeId)
        if let abs = AppAIRuntime.resolveBinary(bin) { return abs }
        // hermes often lives under ~/.local/bin
        return AppAIRuntime.resolveBinary(bin)
    }

    static func isInstalled(typeId: String) -> Bool {
        resolveInstall(typeId: typeId) != nil
    }

    static func installHint(typeId: String) -> String {
        let label = displayLabel(for: typeId)
        switch typeId.lowercased() {
        case "grok":
            return "Install Grok Build CLI so `grok` is on PATH (e.g. ~/.grok/bin), then retry."
        case "claude":
            return "Install Claude Code (`claude`) from Anthropic, then retry."
        case "hermes":
            return "Install Hermes Agent so `hermes` is on PATH (~/.local/bin), then retry."
        case "codex", "openai":
            return "Install Codex or OpenAI CLI (`codex` / `openai`), then retry."
        default:
            return "Install \(label) CLI and ensure it is on PATH."
        }
    }

    static func isMarkedReady(typeId: String) -> Bool {
        let key = normalize(typeId)
        let auth = (AppAISettings.load()["provider_auth"] as? [String: Any]) ?? [:]
        let row = auth[key] as? [String: Any]
        return (row?["ready"] as? Bool) == true
    }

    static func markReady(typeId: String, ready: Bool) {
        let key = normalize(typeId)
        AppAISettings.save { root in
            var auth = root["provider_auth"] as? [String: Any] ?? [:]
            var row = auth[key] as? [String: Any] ?? [:]
            row["ready"] = ready
            if ready {
                row["ready_at"] = Date().timeIntervalSince1970
                row.removeValue(forKey: "cleared_at")
            } else {
                row["cleared_at"] = Date().timeIntervalSince1970
            }
            auth[key] = row
            root["provider_auth"] = auth
        }
    }

    /// Clear ready flag and open login Terminal (sequential multi-account switch).
    static func switchAccount(typeId: String, completion: @escaping (GateResult) -> Void) {
        markReady(typeId: typeId, ready: false)
        ensureLoggedIn(typeId: typeId, reason: "switch account", forcePrompt: true, completion: completion)
    }

    /// Gate before launching a seat CLI. Modal when login is required (safe from bg queues via main).
    static func ensureLoggedIn(
        typeId: String,
        reason: String = "launch",
        forcePrompt: Bool = false,
        completion: @escaping (GateResult) -> Void
    ) {
        let id = normalize(typeId)
        guard isInstalled(typeId: id) else {
            completion(.missingCLI(message: installHint(typeId: id)))
            return
        }
        if !forcePrompt, isMarkedReady(typeId: id) {
            completion(.ok)
            return
        }
        // Must show UI on main
        let work = {
            presentLoginGate(typeId: id, reason: reason, completion: completion)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Synchronous variant for call sites that already block (addWorker on bg thread).
    /// Safe from main: uses runModal directly (no semaphore deadlock).
    @discardableResult
    static func ensureLoggedInBlocking(typeId: String, reason: String = "launch") -> GateResult {
        let id = normalize(typeId)
        guard isInstalled(typeId: id) else {
            return .missingCLI(message: installHint(typeId: id))
        }
        if isMarkedReady(typeId: id) { return .ok }

        if Thread.isMainThread {
            var result: GateResult = .cancelled
            presentLoginGate(typeId: id, reason: reason) { result = $0 }
            return result
        }
        var result: GateResult = .cancelled
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            presentLoginGate(typeId: id, reason: reason) { r in
                result = r
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 600)
        return result
    }

    /// Ensure every distinct CLI type in a launch plan is ready (install + login).
    static func ensureAllReady(typeIds: [String], completion: @escaping (GateResult) -> Void) {
        let unique = Array(Set(typeIds.map { normalize($0) })).sorted()
        func next(_ i: Int) {
            if i >= unique.count {
                completion(.ok)
                return
            }
            ensureLoggedIn(typeId: unique[i], reason: "team create") { r in
                switch r {
                case .ok: next(i + 1)
                default: completion(r)
                }
            }
        }
        next(0)
    }

    // MARK: - Login UI + Terminal

    private static func presentLoginGate(
        typeId: String,
        reason: String,
        completion: @escaping (GateResult) -> Void
    ) {
        let label = displayLabel(for: typeId)
        _ = openLoginTerminal(typeId: typeId)

        let a = NSAlert()
        a.messageText = "Sign in — \(label)"
        a.informativeText = """
        A Terminal window opened for \(label). Sign in / pick the account you want for this \(reason).

        When you’re done, return here and tap I’m signed in — CyberPong closes that window for you.

        It’s safe to close or terminate the login Terminal yourself after you’re signed in. That does not log you out or cancel setup; your login stays with the CLI. The window is only for this one-time sign-in.

        (One active account per provider for now. Use Switch account later to change it.)
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "I’m signed in")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        if resp != .alertFirstButtonReturn {
            closeLoginTerminal()
            completion(.cancelled)
            return
        }
        closeLoginTerminal()
        // Light probe — missing binary is a hard fail; auth probe flaky → still mark ready
        if !isInstalled(typeId: typeId) {
            completion(.missingCLI(message: installHint(typeId: typeId)))
            return
        }
        markReady(typeId: typeId, ready: true)
        // If this is the Guide’s provider, keep headless flag in sync
        if AppAISettings.providerId == typeId || (typeId == "grok" && AppAISettings.providerId == nil) {
            AppAIRuntime.markHeadlessReady(true)
        }
        Pong.log("ProviderAuth ready type=\(typeId) reason=\(reason)")
        completion(.ok)
    }

    @discardableResult
    static func openLoginTerminal(typeId: String) -> String? {
        closeLoginTerminal()
        let label = displayLabel(for: typeId)
        let cmd = interactiveCmd(for: typeId)
        let bin0 = cmd.split(separator: " ").first.map(String.init) ?? cmd
        let resolved = AppAIRuntime.resolveBinary(bin0)
        let execLine: String = {
            if let resolved, !cmd.contains(" ") { return "\"\(resolved)\"" }
            if let resolved, cmd.contains(" ") {
                let rest = cmd.split(separator: " ").dropFirst().joined(separator: " ")
                return "\"\(resolved)\" \(rest)"
            }
            return cmd
        }()

        let dir = NSTemporaryDirectory() + "pong-provider-auth/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "login-\(typeId)-\(Int(Date().timeIntervalSince1970)).command"
        let title = "CyberPong · \(label) · sign in"
        let safeTitle = title.replacingOccurrences(of: "'", with: "")
        let body = """
        #!/bin/bash
        export PATH="\(Pong.extraPath):$PATH"
        printf '\\033]0;\(safeTitle)\\007'
        clear
        echo ""
        echo "  CyberPong — \(label) login"
        echo "  Sign in / pick account here."
        echo "  After you sign in, it is SAFE to close this window."
        echo "  Prefer: return to CyberPong → tap I'm signed in (we close it for you)."
        echo "  Closing does not log you out — the CLI keeps your session."
        echo ""
        exec \(execLine)
        """
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("ProviderAuth login write fail \(error)")
            return nil
        }
        _ = Pong.sh("chmod +x '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
        let before = Set(TerminalTheme.listWindows().map(\.id))
        _ = Pong.sh("open '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
        loginCommandPath = path

        var found: String?
        for _ in 0..<20 {
            usleep(150_000)
            let after = TerminalTheme.listWindows()
            for w in after where !before.contains(w.id) {
                let t = w.title.lowercased()
                if t.contains("cyberpong") || t.contains(typeId) || t.contains(label.lowercased()) {
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
        Pong.log("ProviderAuth openLogin type=\(typeId) window=\(found ?? "-")")
        return found
    }

    static func closeLoginTerminal() {
        if let id = loginWindowId, Int(id) != nil {
            _ = Pong.osascript("""
            tell application "Terminal"
              try
                close window id \(id) saving no
              end try
            end tell
            """)
        }
        loginWindowId = nil
        if let path = loginCommandPath {
            try? FileManager.default.removeItem(atPath: path)
            loginCommandPath = nil
        }
    }

    private static func normalize(_ typeId: String) -> String {
        let t = typeId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "openai" { return "codex" }
        return t
    }
}

import Foundation

/// Persistent App AI + onboarding prefs under `~/.pong/settings.json`.
enum AppAISettings {
    private static var path: String { PairState.settingsPath }

    struct Provider: Equatable {
        let id: String
        let label: String
        let cmd: String
        /// Shown on onboarding cards
        let blurb: String

        static let all: [Provider] = [
            Provider(
                id: "grok",
                label: "Grok",
                cmd: "grok",
                blurb: "xAI · recommended"
            ),
            Provider(
                id: "claude",
                label: "Claude",
                cmd: "claude",
                blurb: "Anthropic Code"
            ),
            Provider(
                id: "openai",
                label: "OpenAI",
                cmd: "openai",
                blurb: "OpenAI / Codex"
            ),
        ]

        static func named(_ id: String) -> Provider {
            all.first { $0.id == id } ?? all[0]
        }
    }

    static func load() -> [String: Any] {
        Pong.loadJSON(path)
    }

    static func save(_ mut: (inout [String: Any]) -> Void) {
        PairWriteLock.withLock {
            var root = Pong.loadJSON(path)
            mut(&root)
            root["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(path, root)
        }
    }

    private static func appAI() -> [String: Any] {
        (load()["app_ai"] as? [String: Any]) ?? [:]
    }

    static var providerId: String? {
        let p = appAI()["provider"] as? String
        return (p?.isEmpty == false) ? p : nil
    }

    static var provider: Provider? {
        guard let id = providerId else { return nil }
        return Provider.named(id)
    }

    static var onboardingComplete: Bool {
        if let b = appAI()["onboarding_complete"] as? Bool { return b }
        // Legacy: old onboarded flag without provider → force new AI onboarding once
        return false
    }

    static var prefer3DMap: Bool {
        if let b = load()["prefer_3d_map"] as? Bool { return b }
        return true // product default: show the constellation
    }

    static func setPrefer3DMap(_ on: Bool) {
        save { $0["prefer_3d_map"] = on }
    }

    static func setProvider(_ p: Provider) {
        save { root in
            var ai = root["app_ai"] as? [String: Any] ?? [:]
            ai["provider"] = p.id
            ai["cmd"] = p.cmd
            ai["label"] = p.label
            root["app_ai"] = ai
        }
    }

    static func markOnboardingComplete() {
        save { root in
            var ai = root["app_ai"] as? [String: Any] ?? [:]
            ai["onboarding_complete"] = true
            // Preserve headless_ready if already set during login step
            root["app_ai"] = ai
        }
        // Keep legacy flag so old paths stay quiet
        let flag = Pong.stateDir + "/onboarded"
        FileManager.default.createFile(atPath: flag, contents: Data())
    }

    /// Headless argv for one-shot Guide turns (no interactive TUI).
    static func headlessArgv(prompt: String) -> [String]? {
        guard let p = provider else { return nil }
        switch p.id {
        case "grok":
            // No --yolo: never auto-approve host commands from the Guide
            return ["grok", "-p", prompt]
        case "claude":
            return ["claude", "-p", prompt]
        case "openai":
            let hasCodex = !(Pong.sh("command -v codex 2>/dev/null").isEmpty)
            if hasCodex {
                return ["codex", "exec", prompt]
            }
            // openai CLI varies; best-effort one-shot
            return ["openai", "api", "chat.completions.create", "-m", "gpt-4o-mini", "-g", "user", prompt]
        default:
            return [p.cmd, "-p", prompt]
        }
    }

    static var headlessReady: Bool {
        (appAI()["headless_ready"] as? Bool) == true
    }
}

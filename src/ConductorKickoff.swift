import Foundation

// MARK: - New-team conductor kickoff

/// Single source of truth for the first prompt pasted into the conductor TUI
/// when a team is created. Orchestrator is told to package-on, gate, and
/// activate every worker via jobs — workers are not pasted here.
enum ConductorKickoff {

    struct RosterSeat {
        var id: String
        var label: String
        var type: String
        var missionRole: String
    }

    struct Context {
        var displayName: String
        var session: String
        var conductorLabel: String
        var conductorType: String
        var bridgeSkill: String
        var roster: [RosterSeat]
        var projectRoot: String
        var teamBrief: String
    }

    /// Later schedules for the same session supersede earlier ones (wizard after startFresh).
    private static var generations: [String: Int] = [:]
    private static let lock = NSLock()

    // MARK: - Bridge skill name

    static func bridgeSkill(forConductorId id: String) -> String {
        switch id {
        case "grok": return "grok-pong-bridge"
        case "hermes": return "hermes-pong-bridge"
        default: return "pong-bridge"
        }
    }

    // MARK: - Context builders

    static func contextFromStartFresh(
        session: String,
        conductor: ConductorType,
        workers: [WorkerType],
        displayName: String = "",
        projectRoot: String = "",
        teamBrief: String = ""
    ) -> Context {
        let condLabel = conductor.label.replacingOccurrences(of: " (recommended)", with: "")
        var seats: [RosterSeat] = []
        for (i, w) in workers.enumerated() {
            let id = "w\(i + 1)"
            let role = MissionRole.defaultForWorker(index: i)
            seats.append(RosterSeat(
                id: id,
                label: w.label,
                type: w.id,
                missionRole: role.rawValue
            ))
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Context(
            displayName: name.isEmpty ? session : name,
            session: session,
            conductorLabel: condLabel,
            conductorType: conductor.id,
            bridgeSkill: bridgeSkill(forConductorId: conductor.id),
            roster: seats,
            projectRoot: projectRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            teamBrief: teamBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func contextFromPlan(_ plan: TeamWizardPlan, session: String) -> Context {
        var seats: [RosterSeat] = []
        for (i, w) in plan.workers.enumerated() {
            seats.append(RosterSeat(
                id: "w\(i + 1)",
                label: w.label,
                type: w.type.id,
                missionRole: w.role.rawValue
            ))
        }
        let name = plan.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Context(
            displayName: name.isEmpty ? session : name,
            session: session,
            conductorLabel: plan.conductorLabel.isEmpty
                ? plan.conductor.label.replacingOccurrences(of: " (recommended)", with: "")
                : plan.conductorLabel,
            conductorType: plan.conductor.id,
            bridgeSkill: bridgeSkill(forConductorId: plan.conductor.id),
            roster: seats,
            projectRoot: plan.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            teamBrief: plan.teamBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Rebuild from live pair state (after wizard apply / saved-team spawn).
    static func contextFromPairState(session: String) -> Context {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = (entry["project_root"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let brief = (entry["team_brief"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cond = entry["conductor"] as? [String: Any] ?? [:]
        let condType = (cond["id"] as? String) ?? (cond["type"] as? String) ?? "grok"
        let rawCondLabel = (cond["label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let condLabel = rawCondLabel.isEmpty ? condType : rawCondLabel
        var seats: [RosterSeat] = []
        let workers = Workers.list(from: entry)
        for (i, w) in workers.enumerated() {
            let id = (w["id"] as? String) ?? "w\(i + 1)"
            let label = (w["label"] as? String) ?? id
            let type = (w["type"] as? String) ?? "claude"
            let roleRaw = (w["mission_role"] as? String)
                ?? MissionRole.defaultForWorker(index: i).rawValue
            seats.append(RosterSeat(id: id, label: label, type: type, missionRole: roleRaw))
        }
        return Context(
            displayName: display.isEmpty ? session : display,
            session: session,
            conductorLabel: condLabel,
            conductorType: condType,
            bridgeSkill: bridgeSkill(forConductorId: condType),
            roster: seats,
            projectRoot: root,
            teamBrief: brief
        )
    }

    // MARK: - Prompt (single source of truth)

    static func buildPrompt(_ ctx: Context) -> String {
        let root = ctx.projectRoot.isEmpty ? "(unset)" : ctx.projectRoot
        let brief = ctx.teamBrief.isEmpty
            ? "(none yet — wait for human goals after activate)"
            : ctx.teamBrief
        let rosterLines: String = {
            if ctx.roster.isEmpty {
                return "- (no workers registered yet)"
            }
            return ctx.roster.map { s in
                let roleTitle = MissionRole.parse(s.missionRole)?.title ?? s.missionRole
                return "- \(s.id)  \(s.label)  (\(s.type))  role=\(roleTitle)"
            }.joined(separator: "\n")
        }()
        let activateCmds = ctx.roster.map { s -> String in
            let role = MissionRole.parse(s.missionRole) ?? .coder
            let playbook = role.playbook
            let neverLines: String = {
                switch role {
                case .reviewer:
                    return "- Do not implement product features — review only\n- Do not rubber-stamp claims without evidence"
                case .coder:
                    return "- Do not act as orchestrator or freestyle job routing\n- Do not expand scope beyond the job"
                case .operator:
                    return "- Do not freestyle large product refactors\n- Do not bypass session access policy"
                case .researcher:
                    return "- Do not invent APIs\n- Do not claim certainty without citations"
                case .taskRunner:
                    return "- Do not become long-lived product owner\n- Discrete jobs only — claim and clear"
                case .orchestrator:
                    return "- Do not implement product while BRIDGE_ON"
                }
            }()
            return """
            pong job create --worker \(s.id) --task "$(cat <<'EOF'
            ACTIVATE — \(ctx.displayName) seat prime (mission role LOCKED)

            You are **\(s.id)** · \(s.label) on team **\(ctx.displayName)** (session `\(ctx.session)`).
            **Mission role (locked for this team): \(role.title)** — \(role.blurb)
            project_root: \(root)

            ### Stay in role
            \(playbook)
            Never leave this role mid-team:
            \(neverLines)

            ### Architecture road
            Every job wrapper includes **SEAT IDENTITY** + **ARCHITECTURE ROAD**.
            Claims and assigns follow the live flow graph only — hop-skips are refused by the control plane.
            Preview now: `pong architecture recap --seat \(s.id)` and `pong seat brief --seat \(s.id)`.

            Do this now:
            1. Confirm session `\(ctx.session)` / display name \(ctx.displayName).
            2. Run: `pong gate` and `pong status` (or read ~/.pong/binds/\(ctx.session).md for who-is-who + edges).
            3. State your locked mission role (\(role.title)) and claim path from the architecture recap.
            4. Reply READY: seat id, role, gate line, project_root, claim target(s).

            No product work yet. Stand by for the next job. Keep this identity until CyberPong changes architecture/roles.

            When done end with ##WORKER_DONE##

            Acceptance:
            - Explicit READY for \(s.id) as \(role.title)
            - Mentions \(ctx.displayName) + \(ctx.session) + project_root
            - Mentions claim target or architecture recap
            - ##WORKER_DONE##
            EOF
            )"
            """
        }.joined(separator: "\n\n")

        return """
        ## BOOT — New team orchestrator prime

        Team: **\(ctx.displayName)** · session `\(ctx.session)` (`PONG_SESSION`)
        You are **c1** (\(ctx.conductorLabel) / \(ctx.conductorType)).
        **Mission role (locked): Orchestrator** — plans jobs, routes only along architecture edges, verifies claims. project_root: \(root)

        Team brief: \(brief)

        ### Who is who (mission roles stay for the life of this team)
        - c1  \(ctx.conductorLabel)  (\(ctx.conductorType))  role=Orchestrator
        \(rosterLines)

        ### Architecture is a hard road
        - `pong job create` **refuses** hop-skips and off-graph assigns.
        - Bind card lists roles + edges: `~/.pong/binds/\(ctx.session).md`
        - After any Architecture edit, refresh: `pong status` (rewrites bind) and re-check edges.

        ### Do this now (boot sequence)

        1. **Identity** — Bound to **\(ctx.displayName)** / `\(ctx.session)` only. Never another team session.
        2. **Load bridge skill** — `\(ctx.bridgeSkill)` (also `pong-bridge` if present). This is required once per conductor runtime, not something the human must re-nudge each team if already installed.
        3. **Package on** — if skills missing: `bash …/scripts/install-skills.sh all` from the CyberPong checkout. Prefer existing global install if already present.
        4. **Gate + bind** — run:
           ```
           pong gate
           pong status
           ```
           Expect `BRIDGE_ON session=\(ctx.session)`. Confirm roster roles match the table above.
        5. **Activate all agents** — one READY job per worker (jobs are source of truth; include identity + architecture in every job automatically):

        \(activateCmds.isEmpty ? "(no workers — skip activate)" : activateCmds)

        6. **Stand by** — after READY claims, wait for human goals. **Orchestrate only** while BRIDGE_ON — do not implement product code. Route only along architecture edges.

        Keep replies short and operational. Confirm team name + session + that you remain Orchestrator in your first status line.
        """
    }

    // MARK: - Delayed paste into conductor

    /// Schedule kickoff paste after the conductor TUI is likely ready.
    /// Optional explicit context; otherwise rebuilds from pair state at fire time.
    static func scheduleInject(
        session: String,
        context: Context? = nil,
        initialDelay: TimeInterval = 3.5
    ) {
        lock.lock()
        let gen = (generations[session] ?? 0) + 1
        generations[session] = gen
        lock.unlock()

        let snap = context
        Pong.log("kickoff schedule session=\(session) gen=\(gen) delay=\(initialDelay)")
        DispatchQueue.global(qos: .userInitiated).async {
            // Backoff: wait for TUI, paste, one retry
            let delays: [TimeInterval] = [initialDelay, 2.0]
            for (attempt, wait) in delays.enumerated() {
                Thread.sleep(forTimeInterval: wait)
                lock.lock()
                let current = generations[session] ?? 0
                lock.unlock()
                if current != gen {
                    Pong.log("kickoff superseded session=\(session) gen=\(gen) now=\(current)")
                    return
                }
                let ctx = snap ?? contextFromPairState(session: session)
                let text = buildPrompt(ctx)
                if !conductorLooksReady(session: session), attempt == 0 {
                    Pong.log("kickoff TUI not ready yet session=\(session) — retry")
                    continue
                }
                let ok = pasteIntoConductor(session: session, text: text)
                Pong.log("kickoff paste session=\(session) gen=\(gen) attempt=\(attempt) ok=\(ok) team=\(ctx.displayName)")
                if ok { return }
            }
        }
    }

    /// Heuristic: Terminal window title looks like a live TUI, or pane has non-shell content.
    static func conductorLooksReady(session: String) -> Bool {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        if let cond = entry["conductor"] as? [String: Any] {
            if let wid = cond["window_id"] as? String, !wid.isEmpty, Pairing.looksLikeTui(wid) {
                return true
            }
            // hermes_window_id is sometimes the conductor Terminal
        }
        if let hid = entry["hermes_window_id"] as? String, !hid.isEmpty, Pairing.looksLikeTui(hid) {
            return true
        }
        return seatLooksReady(session: session, seatId: "c1")
    }

    /// Pane content suggests a coding CLI is up (used after model switch respawn).
    static func seatLooksReady(session: String, seatId: String) -> Bool {
        let target = seatTarget(session: session, seatId: seatId)
        let pane = Pong.sh("tmux capture-pane -p -t '\(target)' -S -40 2>/dev/null")
            .lowercased()
        if pane.isEmpty { return false }
        let markers = ["grok", "claude", "hermes", "kimi", "codex", "opencode", "deepseek",
                       "ask me", "how can i", "ready", "thinking", "✦", "✳", "⚕", "worker ·"]
        if markers.contains(where: { pane.contains($0) }) { return true }
        if pane.count > 80 { return true }
        return false
    }

    /// Seat-prime text matching team-startup ACTIVATE (for direct paste after model switch).
    static func buildWorkerPrimePrompt(session: String, seatId: String) -> String {
        let ctx = contextFromPairState(session: session)
        let root = ctx.projectRoot.isEmpty ? "(unset)" : ctx.projectRoot
        guard let seat = ctx.roster.first(where: { $0.id == seatId }) else {
            return """
            ACTIVATE — \(ctx.displayName) seat prime

            You are **\(seatId)** on team **\(ctx.displayName)** (session `\(ctx.session)`).
            project_root: \(root)

            Run: `pong gate` and `pong status`. Reply READY with seat id + role.
            When done end with ##WORKER_DONE##
            """
        }
        let role = MissionRole.parse(seat.missionRole) ?? .coder
        let playbook = role.playbook
        let neverLines: String = {
            switch role {
            case .reviewer:
                return "- Do not implement product features — review only\n- Do not rubber-stamp claims without evidence"
            case .coder:
                return "- Do not act as orchestrator or freestyle job routing\n- Do not expand scope beyond the job"
            case .operator:
                return "- Do not freestyle large product refactors\n- Do not bypass session access policy"
            case .researcher:
                return "- Do not invent APIs\n- Do not claim certainty without citations"
            case .taskRunner:
                return "- Do not become long-lived product owner\n- Discrete jobs only — claim and clear"
            case .orchestrator:
                return "- Do not implement product while BRIDGE_ON"
            }
        }()
        return """
        ACTIVATE — \(ctx.displayName) seat prime (mission role LOCKED)

        You are **\(seat.id)** · \(seat.label) on team **\(ctx.displayName)** (session `\(ctx.session)`).
        **Mission role (locked for this team): \(role.title)** — \(role.blurb)
        project_root: \(root)
        model/CLI: \(seat.type)

        ### Stay in role
        \(playbook)
        Never leave this role mid-team:
        \(neverLines)

        ### Architecture road
        Every job wrapper includes **SEAT IDENTITY** + **ARCHITECTURE ROAD**.
        Claims and assigns follow the live flow graph only — hop-skips are refused by the control plane.
        Preview now: `pong architecture recap --seat \(seat.id)` and `pong seat brief --seat \(seat.id)`.

        Do this now:
        1. Confirm session `\(ctx.session)` / display name \(ctx.displayName).
        2. Run: `pong gate` and `pong status` (or read ~/.pong/binds/\(ctx.session).md for who-is-who + edges).
        3. State your locked mission role (\(role.title)) and claim path from the architecture recap.
        4. Reply READY: seat id, role, gate line, project_root, claim target(s).

        No product work yet. Stand by for the next job. Keep this identity until CyberPong changes architecture/roles.

        When done end with ##WORKER_DONE##

        Acceptance:
        - Explicit READY for \(seat.id) as \(role.title)
        - Mentions \(ctx.displayName) + \(ctx.session) + project_root
        - Mentions claim target or architecture recap
        - ##WORKER_DONE##
        """
    }

    /// Same path the job system trusts: load-buffer → paste-buffer → Enter.
    @discardableResult
    static func pasteIntoConductor(session: String, text: String) -> Bool {
        pasteIntoSeat(session: session, seatId: "c1", text: text)
    }

    /// Paste text into any seat pane (conductor or worker).
    @discardableResult
    static func pasteIntoSeat(session: String, seatId: String, text: String) -> Bool {
        TmuxScroll.apply(session: session)
        let body = text.hasSuffix("\n") ? text : text + "\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pong-seat-paste-\(UUID().uuidString).txt")
        do {
            try body.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("seat paste write tmp fail: \(error)")
            return false
        }
        let target = seatTarget(session: session, seatId: seatId)
        let buf = "pong_seat_\(seatId.replacingOccurrences(of: "-", with: "_"))"
        let q = tmp.path.replacingOccurrences(of: "'", with: "'\\''")
        let out = Pong.sh("""
            tmux has-session -t '\(session)' 2>/dev/null || exit 1
            tmux load-buffer -b \(buf) '\(q)' || exit 2
            tmux paste-buffer -b \(buf) -d -t '\(target)' || exit 3
            sleep 0.12
            tmux send-keys -t '\(target)' Enter
            sleep 0.08
            tmux send-keys -t '\(target)' C-m
            sleep 0.05
            tmux send-keys -t '\(target)' Enter
            echo OK
            """)
        try? FileManager.default.removeItem(at: tmp)
        return out.contains("OK")
    }

    private static func conductorTarget(session: String) -> String {
        seatTarget(session: session, seatId: "c1")
    }

    /// Resolve tmux target for a seat (pane_id preferred).
    static func seatTarget(session: String, seatId: String) -> String {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        if seatId == "c1" || seatId == "hermes" {
            if let cond = entry["conductor"] as? [String: Any],
               let pid = cond["pane_id"] as? String, !pid.isEmpty {
                return pid
            }
            let path = Pong.stateDir + "/sessions/\(session)/panes.json"
            if let data = FileManager.default.contents(atPath: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["c1", "hermes"] {
                    if let row = obj[key] as? [String: Any],
                       let pid = row["pane_id"] as? String, !pid.isEmpty {
                        return pid
                    }
                }
            }
            let live = Pong.sh("tmux display-message -p -t '\(session):0' '#{pane_id}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return live.hasPrefix("%") ? live : "\(session):0"
        }
        let workers = Workers.list(from: entry)
        if let w = workers.first(where: { ($0["id"] as? String) == seatId }) {
            if let pid = w["pane_id"] as? String, !pid.isEmpty { return pid }
            let ti = (w["tmux_index"] as? Int) ?? 1
            let live = Pong.sh("tmux display-message -p -t '\(session):\(ti)' '#{pane_id}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return live.hasPrefix("%") ? live : "\(session):\(ti)"
        }
        let path = Pong.stateDir + "/sessions/\(session)/panes.json"
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let row = obj[seatId] as? [String: Any],
           let pid = row["pane_id"] as? String, !pid.isEmpty {
            return pid
        }
        return "\(session):1"
    }
}

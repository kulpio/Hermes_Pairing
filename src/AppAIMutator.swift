import Foundation

/// Allowlisted architecture / team mutations for App AI (rules shell + chat Apply).
/// Sequential commit; no multi-intent auto-rollback (see design ApplyResult).
enum AppAIMutator {
    /// Last session created by `createFirstTeam` (for callers that need the id).
    private(set) static var lastCreatedSession: String?
    /// Last seat id created by addWorker / addSubagent
    private(set) static var lastCreatedSeatId: String?

    struct ApplyResult {
        var applied: [String] = []
        var failed: [(String, String)] = []
        var skipped: [String] = []
        var session: String? = nil
        var seatId: String? = nil
    }

    enum Intent {
        case setDisplayName(session: String, name: String)
        case setMissionRole(session: String, seatId: String, role: String)
        case ensureDefaultFlow(session: String)
        case sanitize(session: String)
        case createFirstTeam(plan: FirstTeamPlan)
        /// Live spawn under parent (or orch). Goes through Workers.addWorker + auth gate.
        case addSubagent(session: String, parentId: String, typeId: String, label: String?, missionRole: String?)
        case addWorker(session: String, typeId: String, label: String?, missionRole: String?)
        case addFlowEdge(session: String, from: String, to: String, kind: String)
        case removeSeat(session: String, seatId: String)
        /// Save or update a cron job in `~/.pong/cron-schedules.json`.
        case upsertCron(session: String, name: String, ownerId: String, cadence: String, task: String, enabled: Bool)
    }

    struct FirstTeamPlan {
        var teamName: String
        var projectRoot: String
        var teamBrief: String
        var conductorId: String
        var workerTypes: [String]
        var missionRoles: [String]
        var workerLabels: [String] = []
    }

    @discardableResult
    static func apply(_ intents: [Intent]) -> ApplyResult {
        var result = ApplyResult()
        for intent in intents {
            do {
                try applyOne(intent)
                result.applied.append(label(intent))
                if case .createFirstTeam = intent {
                    result.session = lastCreatedSession
                }
                if case .addSubagent = intent { result.seatId = lastCreatedSeatId }
                if case .addWorker = intent { result.seatId = lastCreatedSeatId }
            } catch {
                result.failed.append((label(intent), error.localizedDescription))
            }
        }
        return result
    }

    private static func label(_ i: Intent) -> String {
        switch i {
        case .setDisplayName: return "set_display_name"
        case .setMissionRole: return "set_mission_role"
        case .ensureDefaultFlow: return "ensure_default_flow"
        case .sanitize: return "sanitize"
        case .createFirstTeam: return "create_first_team"
        case .addSubagent: return "add_subagent"
        case .addWorker: return "add_worker"
        case .addFlowEdge: return "add_flow_edge"
        case .removeSeat: return "remove_seat"
        case .upsertCron: return "upsert_cron"
        }
    }

    private static func applyOne(_ intent: Intent) throws {
        switch intent {
        case .setDisplayName(let session, let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MutError("empty display name") }
            PairState.mutate(session) { $0["display_name"] = trimmed }

        case .setMissionRole(let session, let seatId, let role):
            guard let mr = MissionRole.parse(role) else { throw MutError("unknown role \(role)") }
            if seatId == "c1" || seatId.hasPrefix("c") {
                return
            }
            PairState.mutate(session) { entry in
                var ws = Workers.list(from: entry)
                guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == seatId }) else { return }
                ws[idx]["mission_role"] = mr.rawValue
                entry["workers"] = ws
            }

        case .ensureDefaultFlow(let session):
            TeamSanitizer.ensureDefaultFlowGraph(pair: session)
            TeamSanitizer.reconcile(pair: session)

        case .sanitize(let session):
            TeamSanitizer.reconcile(pair: session)

        case .createFirstTeam(let plan):
            try createFirstTeam(plan)

        case .addSubagent(let session, let parentId, let typeId, let label, let missionRole):
            try spawnSeat(session: session, typeId: typeId, parentId: parentId, label: label, missionRole: missionRole)

        case .addWorker(let session, let typeId, let label, let missionRole):
            try spawnSeat(session: session, typeId: typeId, parentId: nil, label: label, missionRole: missionRole)

        case .addFlowEdge(let session, let from, let to, let kind):
            let k = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !from.isEmpty, !to.isEmpty else { throw MutError("edge needs from/to") }
            FlowGraph.addEdge(pair: session, from: from, to: to, kind: k.isEmpty ? "delegate" : k)

        case .removeSeat(let session, let seatId):
            let sid = seatId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sid != "c1", sid != "you" else { throw MutError("cannot remove conductor/human") }
            let ok = Workers.removeWorker(pair: session, workerId: sid)
            if !ok { throw MutError("remove seat failed for \(sid)") }

        case .upsertCron(let session, let name, let ownerId, let cadence, let task, let enabled):
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw MutError("cron name required") }
            let owner = ownerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty else { throw MutError("cron owner seat required") }
            let parsed = CronSchedule.parseCadence(cadence)
            let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
            let job = CronSchedule.Job(
                id: "",
                name: n,
                task: t.isEmpty ? "Run scheduled work for \(n)." : t,
                cadence: parsed.label,
                intervalSec: parsed.intervalSec,
                phaseSec: parsed.phaseSec,
                ownerId: owner,
                enabled: enabled
            )
            _ = CronSchedule.upsert(session: session, job: job)
        }
    }

    private static func spawnSeat(
        session: String,
        typeId: String,
        parentId: String?,
        label: String?,
        missionRole: String?
    ) throws {
        let tid = typeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tid.isEmpty else { throw MutError("empty type") }
        // Auth / install gate (modal if needed)
        let gate = ProviderAuth.ensureLoggedInBlocking(typeId: tid, reason: parentId == nil ? "add agent" : "add sub-agent")
        switch gate {
        case .ok: break
        case .missingCLI(let msg): throw MutError(msg)
        case .cancelled: throw MutError("login cancelled")
        case .failed(let msg): throw MutError(msg)
        }
        let wt = WorkerType.resolved(tid)
        guard let newId = Workers.addWorker(pair: session, type: wt, parentId: parentId, skipAuth: true) else {
            throw MutError("addWorker returned nil")
        }
        lastCreatedSeatId = newId
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Workers.setWorkerLabel(pair: session, workerId: newId, label: label)
        }
        // Map informal roles (scraper → researcher)
        let roleRaw = (missionRole ?? "")
            .replacingOccurrences(of: "scraper", with: "researcher")
            .replacingOccurrences(of: "research", with: "researcher")
        if let mr = MissionRole.parse(roleRaw) {
            PairState.mutate(session) { entry in
                var ws = Workers.list(from: entry)
                if let idx = ws.firstIndex(where: { ($0["id"] as? String) == newId }) {
                    ws[idx]["mission_role"] = mr.rawValue
                    entry["workers"] = ws
                }
            }
        }
        TeamSanitizer.reconcile(pair: session)
        Pong.log("AppAIMutator.spawnSeat session=\(session) id=\(newId) type=\(tid) parent=\(parentId ?? "-")")
    }

    private static func createFirstTeam(_ plan: FirstTeamPlan) throws {
        let condId = plan.conductorId.isEmpty ? "grok" : plan.conductorId
        var needAuth = [condId]
        for tid in plan.workerTypes where !tid.isEmpty {
            needAuth.append(tid)
        }
        // Sequential login for each distinct CLI (modal per missing ready flag)
        for tid in Array(Set(needAuth.map { $0.lowercased() })) {
            let gate = ProviderAuth.ensureLoggedInBlocking(typeId: tid, reason: "new team")
            switch gate {
            case .ok: break
            case .missingCLI(let msg): throw MutError(msg)
            case .cancelled: throw MutError("login cancelled for \(tid)")
            case .failed(let msg): throw MutError(msg)
            }
        }

        let cond = ConductorType.resolved(condId)
        var workers: [WorkerType] = []
        for tid in plan.workerTypes {
            workers.append(WorkerType.resolved(tid.isEmpty ? "claude" : tid))
        }
        if workers.isEmpty {
            workers = [WorkerType.resolved("claude")]
        }

        let name = Pairing.startFresh(workers: workers, conductor: cond)
        lastCreatedSession = name
        usleep(350_000)

        let display = plan.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = plan.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = plan.teamBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        // Non-empty display name is required for live team label (fallback if plan blank).
        let durableDisplay = display.isEmpty ? "My team" : display

        PairState.mutate(name) { entry in
            entry["display_name"] = durableDisplay
            if !root.isEmpty { entry["project_root"] = root }
            if !brief.isEmpty { entry["team_brief"] = brief }
            var ws = Workers.list(from: entry)
            for i in ws.indices {
                let roleRaw: String = {
                    if i < plan.missionRoles.count { return plan.missionRoles[i] }
                    return MissionRole.defaultForWorker(index: i).rawValue
                }()
                if let mr = MissionRole.parse(roleRaw) {
                    ws[i]["mission_role"] = mr.rawValue
                } else {
                    ws[i]["mission_role"] = MissionRole.defaultForWorker(index: i).rawValue
                }
                if i < plan.workerLabels.count {
                    let lab = plan.workerLabels[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !lab.isEmpty { ws[i]["label"] = lab }
                }
            }
            entry["workers"] = ws
            if let first = plan.workerLabels.first, !first.isEmpty {
                entry["worker_label"] = first
            }
        }

        // Durable re-apply after startFresh settle so nothing overwrites with session id.
        Workers.setTeamOptions(name, displayName: durableDisplay, projectRoot: root, teamBrief: brief)
        usleep(100_000)
        PairState.mutate(name) { entry in
            entry["display_name"] = durableDisplay
        }

        TeamSanitizer.ensureDefaultFlowGraph(pair: name)
        TeamSanitizer.reconcile(pair: name)

        // Final display_name check + re-apply if stripped
        let after = (PairState.loadPairsDb()[name] as? [String: Any])?["display_name"] as? String ?? ""
        if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || after == name {
            Workers.setTeamOptions(name, displayName: durableDisplay, projectRoot: root, teamBrief: brief)
            Pong.log("AppAIMutator.createFirstTeam re-applied display_name=\(durableDisplay) session=\(name)")
        }

        ConductorKickoff.scheduleInject(
            session: name,
            context: ConductorKickoff.contextFromPairState(session: name)
        )
        TerminalTheme.applyPair(name)
        Pong.sh("python3 -c \"import os,sys; home=os.path.expanduser('~'); sys.path.insert(0, home+'/.pong/lib'); from pong.state import write_bind_card; write_bind_card('\(name)')\" >/dev/null 2>&1 || true")
        Pong.log("AppAIMutator.createFirstTeam session=\(name) display=\(durableDisplay) conductor=\(condId) workers=\(plan.workerTypes.joined(separator: ","))")
    }

    // MARK: - Chat intent parse (lightweight)

    /// Parse simple user/Guide apply lines into intents. Session defaults to first live pair.
    static func parseChatIntents(_ text: String, defaultSession: String?) -> [Intent] {
        let session = defaultSession ?? PairState.listPairs().first
        guard let session else { return [] }
        var out: [Intent] = []
        let lower = text.lowercased()

        // ** apply add_subagent type=hermes parent=c1 label=Scraper role=scraper **
        if lower.contains("add_subagent") || (lower.contains("add") && lower.contains("sub") && (lower.contains("hermes") || lower.contains("claude") || lower.contains("agent"))) {
            let typeId = firstMatch(lower, patterns: ["type=(\\w+)", "hermes", "claude", "grok", "codex"]) ?? "hermes"
            let resolvedType: String = {
                if ["hermes", "claude", "grok", "codex"].contains(typeId) { return typeId }
                if lower.contains("hermes") { return "hermes" }
                if lower.contains("claude") { return "claude" }
                if lower.contains("grok") { return "grok" }
                return "hermes"
            }()
            let parent = firstMatch(text, patterns: ["parent[=:]\\s*([\\w-]+)", "under\\s+([\\w-]+)"]) ?? "c1"
            let label: String? = {
                if lower.contains("scrape") { return "Hermes Scraper" }
                if lower.contains("research") { return "Hermes Research" }
                return firstMatch(text, patterns: ["label[=:]\\s*([^\\n*]+)"])
            }()
            let role: String? = {
                if lower.contains("scrape") { return "scraper" }
                if lower.contains("research") { return "researcher" }
                return firstMatch(text, patterns: ["role[=:]\\s*([\\w-]+)"])
            }()
            out.append(.addSubagent(session: session, parentId: parent, typeId: resolvedType, label: label, missionRole: role))
        }

        if lower.contains("remove") && (lower.contains("ghost") || lower.contains("seat") || lower.contains("w3") || lower.contains("w4")) {
            let ids = matches(text, pattern: "\\b(w\\d+)\\b")
            for id in ids {
                out.append(.removeSeat(session: session, seatId: id))
            }
        }

        // ** claim path w1→c1 ** or edge w1->c1 kind=claim
        if let from = firstMatch(text, patterns: ["([\\w-]+)\\s*→\\s*([\\w-]+)", "([\\w-]+)\\s*->\\s*([\\w-]+)"]) {
            _ = from
        }
        if let m = text.range(of: #"([A-Za-z0-9_-]+)\s*(?:→|->)\s*([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            let pair = String(text[m])
            let toks = pair.replacingOccurrences(of: "→", with: "->").components(separatedBy: "->")
            if toks.count == 2 {
                let f = toks[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let t = toks[1].trimmingCharacters(in: .whitespacesAndNewlines)
                var kind = "delegate"
                if lower.contains("claim") { kind = "claim" }
                else if lower.contains("peer") { kind = "peer" }
                else if lower.contains("sub") { kind = "sub" }
                else if lower.contains("review") { kind = "review" }
                if !f.isEmpty && !t.isEmpty {
                    out.append(.addFlowEdge(session: session, from: f, to: t, kind: kind))
                }
            }
        }

        // CREATE_CRON / upsert_cron name=… owner=w1 cadence=every 15m task=…
        if lower.contains("create_cron") || lower.contains("upsert_cron") || lower.contains("schedule_cron") {
            let name = firstMatch(text, patterns: [
                #"name\s*[=:]\s*"([^"]+)""#,
                #"name\s*[=:]\s*'([^']+)'"#,
                #"name\s*[=:]\s*([^\n,;]+)"#,
            ]) ?? "Scheduled job"
            let owner = firstMatch(text, patterns: [
                #"owner\s*[=:]\s*([A-Za-z0-9_-]+)"#,
                #"seat\s*[=:]\s*([A-Za-z0-9_-]+)"#,
            ]) ?? "c1"
            let cadence = firstMatch(text, patterns: [
                #"cadence\s*[=:]\s*"([^"]+)""#,
                #"cadence\s*[=:]\s*'([^']+)'"#,
                #"cadence\s*[=:]\s*([^\n,;]+)"#,
                #"(every\s+\d+\s*[mh])"#,
                #"(daily\s+\d{1,2}:\d{2})"#,
            ]) ?? "every 1h"
            let task = firstMatch(text, patterns: [
                #"task\s*[=:]\s*"([^"]+)""#,
                #"task\s*[=:]\s*'([^']+)'"#,
                #"task\s*[=:]\s*([^\n]+)"#,
            ]) ?? ""
            let enabled = !lower.contains("enabled=false") && !lower.contains("disabled")
            out.append(.upsertCron(
                session: session,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                ownerId: owner,
                cadence: cadence.trimmingCharacters(in: .whitespacesAndNewlines),
                task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: enabled
            ))
        }

        return out
    }

    private static func firstMatch(_ text: String, patterns: [String]) -> String? {
        for p in patterns {
            if p.hasPrefix("type=") || p.contains("(") {
                if let m = matches(text, pattern: p).first { return m }
            } else if text.lowercased().contains(p) {
                return p
            }
        }
        return nil
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).compactMap { m in
            guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else {
                if let r0 = Range(m.range(at: 0), in: text) { return String(text[r0]) }
                return nil
            }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct MutError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

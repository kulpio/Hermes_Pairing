import Foundation
import AppKit

/// Situation detectors on the ~4s poll — proactive Guide nudges with optional Apply actions.
enum GuideCoach {
    private static var lastKey = ""
    private static var lastAt: TimeInterval = 0
    private static let minInterval: TimeInterval = 45
    /// Stall keys already shown (until job leaves open list).
    private static var silencedStallKeys = Set<String>()
    /// Queued job must be this old to alert (seconds).
    private static let stallMinAge: TimeInterval = 180       // 3m
    /// Older than this = zombie noise — ignore (do not spam ~4463m).
    private static let stallMaxAge: TimeInterval = 45 * 60  // 45m

    struct Finding {
        let key: String
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
        /// Optional second button (e.g. Open seat).
        let secondaryTitle: String?
        let secondaryAction: (() -> Void)?
        /// Short chip when bubble collapsed.
        let chipText: String?

        init(
            key: String,
            message: String,
            actionTitle: String? = nil,
            action: (() -> Void)? = nil,
            secondaryTitle: String? = nil,
            secondaryAction: (() -> Void)? = nil,
            chipText: String? = nil
        ) {
            self.key = key
            self.message = message
            self.actionTitle = actionTitle
            self.action = action
            self.secondaryTitle = secondaryTitle
            self.secondaryAction = secondaryAction
            self.chipText = chipText
        }
    }

    /// Call from PanelController poll (main thread).
    static func tick(snapshot: [String: Any]?, pairs: [String]) {
        guard AppAIRuntime.isHeadlessReady else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAt >= minInterval else { return }
        guard let finding = detect(snapshot: snapshot, pairs: pairs) else { return }
        // Don't re-fire the same finding every few minutes
        if finding.key == lastKey, now - lastAt < minInterval * 4 { return }
        if silencedStallKeys.contains(finding.key) { return }
        lastKey = finding.key
        lastAt = now
        if finding.key.hasPrefix("stall-") {
            silencedStallKeys.insert(finding.key)
        }
        AppAIChatBubble.shared.nudgeAction(
            text: finding.message,
            actionTitle: finding.actionTitle,
            action: finding.action,
            secondaryTitle: finding.secondaryTitle,
            secondaryAction: finding.secondaryAction,
            chipText: finding.chipText
        )
    }

    private static func detect(snapshot: [String: Any]?, pairs: [String]) -> Finding? {
        let live = Set(pairs)
        let teams = (snapshot?["teams"] as? [[String: Any]]) ?? []
        // Drop silenced stall keys for jobs no longer open
        pruneSilencedStalls(teams: teams)

        let focus = pairs.first
        for team in teams {
            let session = (team["session"] as? String) ?? ""
            guard live.contains(session) else { continue }
            if let focus, session != focus, pairs.count == 1 { continue }
            if let f = detectTeam(session: session, team: team, livePairs: live) { return f }
        }
        // Fallback without snapshot — pairs.json only
        if teams.isEmpty {
            for session in pairs {
                if let f = detectFromPairsFile(session: session) { return f }
            }
        }
        return nil
    }

    private static func pruneSilencedStalls(teams: [[String: Any]]) {
        var openKeys = Set<String>()
        for team in teams {
            let session = (team["session"] as? String) ?? ""
            let openJobs = ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            for j in openJobs {
                let id = (j["id"] as? String) ?? ""
                let wid = (j["worker"] as? String) ?? "?"
                openKeys.insert("stall-\(session)-\(id.isEmpty ? wid : id)")
            }
        }
        silencedStallKeys = silencedStallKeys.filter { openKeys.contains($0) }
    }

    private static func detectTeam(session: String, team: [String: Any], livePairs: Set<String>) -> Finding? {
        guard livePairs.contains(session) else { return nil }
        let workers = (team["workers"] as? [[String: Any]]) ?? []
        let openJobs = ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let eph = (team["ephemeral_subs"] as? [[String: Any]]) ?? []

        let permanent = workers.filter { ($0["ephemeral"] as? Bool) != true }
        let withParent = permanent.filter { ($0["parent_id"] as? String)?.isEmpty == false }

        // Ghost subagents: parent_id set but no pane
        let ghosts = withParent.filter {
            let pid = $0["pane_id"] as? String
            return pid == nil || (pid ?? "").isEmpty
        }
        if !ghosts.isEmpty {
            let labels = ghosts.compactMap { $0["label"] as? String }.joined(separator: ", ")
            let ids = ghosts.compactMap { $0["id"] as? String }
            return Finding(
                key: "ghost-subs-\(session)-\(ids.joined())",
                message: "Ghost seats on map (no TUI): \(labels.isEmpty ? ids.joined(separator: ", ") : labels).",
                actionTitle: "Remove ghosts",
                action: {
                    for id in ids {
                        _ = AppAIMutator.apply([.removeSeat(session: session, seatId: id)])
                    }
                    PanelController.shared.refreshUI()
                    AppAIChatBubble.shared.nudge("Removed ghosts · use + to spawn real seats")
                },
                chipText: "ghost seats"
            )
        }

        // Orch busy but no subagents
        let orchBusy: Bool = {
            if let c = team["conductor"] as? [String: Any] {
                let h = ((c["status_hint"] as? String) ?? "").lowercased()
                if h.contains("run") || h.contains("busy") || h.contains("live") { return true }
            }
            return openJobs.contains { (($0["status"] as? String) ?? "").lowercased() == "running" }
        }()
        if orchBusy && withParent.isEmpty && eph.isEmpty && permanent.count <= 2 {
            return Finding(
                key: "no-subs-\(session)",
                message: "Orch is active · no sub-agents. Add a helper if the task needs parallel work.",
                actionTitle: "Add Hermes sub",
                action: {
                    let r = AppAIMutator.apply([
                        .addSubagent(session: session, parentId: "c1", typeId: "hermes", label: "Hermes helper", missionRole: MissionRole.researcher.rawValue),
                    ])
                    PanelController.shared.refreshUI()
                    if r.failed.isEmpty {
                        AppAIChatBubble.shared.nudge("Spawned Hermes sub under orch")
                    } else {
                        AppAIChatBubble.shared.nudge(r.failed.map(\.1).joined(separator: "; "))
                    }
                },
                chipText: "no sub-agents"
            )
        }

        // Stalled queued jobs: 3m … 45m only (skip multi-day zombies)
        let now = Date().timeIntervalSince1970
        for j in openJobs {
            let st = ((j["status"] as? String) ?? "").lowercased()
            guard st == "queued" || st == "pending" else { continue }
            let created = (j["created_at"] as? Double) ?? now
            let age = now - created
            if age < stallMinAge || age > stallMaxAge { continue }
            let jid = (j["id"] as? String) ?? ""
            let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
            let key = "stall-\(session)-\(jid.isEmpty ? wid : jid)"
            if silencedStallKeys.contains(key) { continue }
            let mins = max(1, Int(age / 60))
            let short = "\(wid) job waiting · \(mins)m"
            let seatOffline: Bool = {
                guard let w = permanent.first(where: { ($0["id"] as? String) == wid }) else { return true }
                let pane = (w["pane_id"] as? String) ?? ""
                return pane.isEmpty
            }()
            let msg = seatOffline
                ? "\(short) · seat may be offline"
                : short
            return Finding(
                key: key,
                message: msg,
                actionTitle: "Open Mission",
                action: {
                    if !jid.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(jid, forType: .string)
                    }
                    PanelController.shared.goToMission()
                },
                secondaryTitle: seatOffline ? "Open seat" : "Copy job id",
                secondaryAction: {
                    if seatOffline {
                        Workers.frontWorker(pair: session, workerId: wid)
                    } else if !jid.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(jid, forType: .string)
                        AppAIChatBubble.shared.nudge("Copied job id")
                    }
                },
                chipText: "\(wid) waiting \(mins)m"
            )
        }

        return nil
    }

    private static func detectFromPairsFile(session: String) -> Finding? {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        let ghosts = ws.filter {
            let parent = $0["parent_id"] as? String
            let pane = $0["pane_id"] as? String
            return parent != nil && !(parent ?? "").isEmpty && (pane == nil || (pane ?? "").isEmpty)
        }
        guard !ghosts.isEmpty else { return nil }
        let ids = ghosts.compactMap { $0["id"] as? String }
        return Finding(
            key: "ghost-file-\(session)-\(ids.joined())",
            message: "Ghost seats \(ids.joined(separator: ", ")) (no pane).",
            actionTitle: "Remove ghosts",
            action: {
                for id in ids {
                    _ = AppAIMutator.apply([.removeSeat(session: session, seatId: id)])
                }
                PanelController.shared.refreshUI()
            },
            chipText: "ghost seats"
        )
    }

    /// Compact team state block for Guide headless prompts.
    static func teamContextBlock() -> String {
        var lines: [String] = ["## Live team state (read-only snapshot)"]
        let pairs = PairState.listPairs()
        if pairs.isEmpty {
            lines.append("No live teams.")
            return lines.joined(separator: "\n")
        }
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        let now = Date().timeIntervalSince1970
        for session in pairs.prefix(4) {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let cond = entry["conductor"] as? [String: Any]
            lines.append("### \(display) (`\(session)`)")
            lines.append("- orch: \((cond?["id"] as? String) ?? "c1") · \((cond?["type"] as? String) ?? "?") · \((cond?["label"] as? String) ?? "")")
            let teamSnap = teams.first { ($0["session"] as? String) == session }
            let snapWorkers = (teamSnap?["workers"] as? [[String: Any]]) ?? []
            let workers = Workers.list(from: entry)
            for w in workers {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let typ = (w["type"] as? String) ?? "?"
                let role = (w["mission_role"] as? String) ?? ""
                let parent = (w["parent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let pane = (w["pane_id"] as? String) ?? ""
                let live = pane.isEmpty ? "NO_PANE" : "pane=\(pane)"
                let hint = (snapWorkers.first { ($0["id"] as? String) == id }?["status_hint"] as? String) ?? "idle"
                var line = "- \(id) \(lab) type=\(typ) role=\(role) status_hint=\(hint) \(live)"
                if let parent { line += " parent=\(parent)" }
                lines.append(line)
            }
            let edges = FlowGraph.load(from: entry).prefix(12).map { "\($0.from)→\($0.to):\($0.kind)" }
            if !edges.isEmpty {
                lines.append("- edges: " + edges.joined(separator: ", "))
            }
            let jobsBlob = teamSnap?["jobs"] as? [String: Any]
            let open = (jobsBlob?["open"] as? [[String: Any]]) ?? []
            let activity = (jobsBlob?["activity_open"] as? [[String: Any]]) ?? open
            lines.append("- open_jobs=\(open.count) activity_open=\(activity.count)")
            for j in open.prefix(8) {
                let st = (j["status"] as? String) ?? "?"
                let w = (j["worker"] as? String) ?? "?"
                let jid = (j["id"] as? String) ?? "?"
                let updated = (j["updated_at"] as? Double)
                    ?? (j["created_at"] as? Double)
                    ?? now
                let ageM = Int((now - updated) / 60)
                let staleSoft = (st == "notified" || st == "queued") && ageM >= 20
                let staleHard = (st == "notified" || st == "queued") && ageM >= 120
                let flag = staleHard ? "STALE>2h" : (staleSoft ? "STUCK>20m" : "fresh")
                let prev = (j["task_preview"] as? String) ?? ""
                lines.append("- job \(jid) \(st) → \(w) · \(ageM)m \(flag) · \(String(prev.prefix(48)))")
            }
            let crons = CronSchedule.load(session: session)
            if !crons.isEmpty {
                lines.append("- cron: " + crons.prefix(5).map { "\($0.name)@\($0.ownerId)/\($0.cadence)" }.joined(separator: ", "))
            }
        }
        lines.append("Rules: seats without pane_id are ghosts. Prefer + on map or mutator add_subagent for live TUIs.")
        lines.append("Cron: emit CREATE_CRON name=… owner=w1 cadence=\"every 15m\" task=\"…\" for Apply.")
        return lines.joined(separator: "\n")
    }

    /// Offline / fast answers for Mission chips — grounded in snapshot, not fluff.
    static func answerMissionQuestion(_ question: String) -> String {
        let q = question.lowercased()
        let pairs = PairState.listPairs()
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        let now = Date().timeIntervalSince1970

        if pairs.isEmpty {
            return "No live teams. Create one with **New team**, then ask again."
        }

        var idle: [String] = []
        var active: [String] = []
        var stuck: [String] = []
        var rogue: [String] = []

        for session in pairs {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let team = teams.first { ($0["session"] as? String) == session }
            let workers = (team?["workers"] as? [[String: Any]]) ?? []
            for w in workers {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let hint = ((w["status_hint"] as? String) ?? "idle").lowercased()
                let who = "\(lab) (\(id)) · \(display)"
                if hint.contains("run") || hint.contains("busy") || hint.contains("notif") || hint.contains("human") {
                    active.append("\(who) — \(hint)")
                } else {
                    idle.append(who)
                }
            }
            let open = ((team?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            for j in open {
                let st = ((j["status"] as? String) ?? "").lowercased()
                let w = (j["worker"] as? String) ?? "?"
                let jid = (j["id"] as? String) ?? "?"
                let updated = (j["updated_at"] as? Double) ?? (j["created_at"] as? Double) ?? now
                let ageM = Int((now - updated) / 60)
                if (st == "notified" || st == "queued") && ageM >= 20 {
                    stuck.append("\(jid) \(st) → \(w) · \(ageM)m · \(display)")
                }
                if st == "failed" || st == "rejected" {
                    rogue.append("\(jid) \(st) → \(w) · \(display)")
                }
            }
        }

        if q.contains("idle") {
            if idle.isEmpty { return "No idle permanent seats in the snapshot — everyone has activity_hint busy/running, or no workers yet." }
            return "Idle seats (status_hint idle):\n• " + idle.prefix(12).joined(separator: "\n• ")
        }
        if q.contains("rogue") || q.contains("stale") || q.contains("stuck") {
            var parts: [String] = []
            if !stuck.isEmpty {
                parts.append("Stuck/stale open jobs (≥20m notified/queued):\n• " + stuck.prefix(8).joined(separator: "\n• "))
            }
            if !rogue.isEmpty {
                parts.append("Failed/rejected:\n• " + rogue.prefix(6).joined(separator: "\n• "))
            }
            if parts.isEmpty {
                return "No stuck (≥20m) or failed/rejected open jobs in the live snapshot. Open jobs may still be fresh notified/running."
            }
            return parts.joined(separator: "\n\n") + "\n\nTip: open Mission job rows or paste a job id into Focus."
        }
        if q.contains("orch") || q.contains("active") || q.contains("why") {
            if active.isEmpty {
                return "Snapshot shows no seats with running/busy/human hints. Orch pulse comes from activity_open jobs (not stale notified)."
            }
            return "Currently active (status_hint):\n• " + active.prefix(10).joined(separator: "\n• ") +
                "\n\nOrch goes ACTIVE when activity_open has notified/running jobs under 20m/45m age rules."
        }
        if q.contains("next") || q.contains("should") {
            if !stuck.isEmpty {
                return "Next: clear stuck jobs first:\n• " + stuck.prefix(3).joined(separator: "\n• ") +
                    "\nCancel zombies, re-dispatch, or take human takeover on Mission."
            }
            if !active.isEmpty {
                return "Work is in flight:\n• " + active.prefix(4).joined(separator: "\n• ") +
                    "\nWatch claims on the claim path; avoid new parallel thrash."
            }
            return "All calm. Optional: schedule a perimeter cron (Cron Manager → Describe in Guide), or give orch a new mission."
        }
        // Generic grounded summary
        return "Teams: \(pairs.count). Idle: \(idle.count). Active: \(active.count). Stuck jobs: \(stuck.count).\n" +
            (stuck.first.map { "Top stuck: \($0)" } ?? "No stuck jobs.") +
            "\nAsk “Who is idle?” or “Any rogue/stale jobs?” for detail."
    }
}

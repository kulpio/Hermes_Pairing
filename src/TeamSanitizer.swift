import Foundation
import AppKit

// MARK: - Single-writer lock for pairs.json

/// Serializes pair DB writes so map kill, Architecture canvas, FlowGraph, and
/// future App AI mutators do not interleave half-applied states.
enum PairWriteLock {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

extension PairState {
    /// Load → mutate one session entry → write under `PairWriteLock`.
    static func mutate(_ session: String, _ body: (inout [String: Any]) -> Void) {
        PairWriteLock.withLock {
            var db = loadPairsDb()
            var entry = db[session] as? [String: Any] ?? [:]
            body(&entry)
            entry["updated"] = Date().timeIntervalSince1970
            db[session] = entry
            Pong.writeJSON(pairsPath, db)
        }
    }

    /// Whole-DB mutation under lock (e.g. delete session key).
    static func mutateDb(_ body: (inout [String: Any]) -> Void) {
        PairWriteLock.withLock {
            var db = loadPairsDb()
            body(&db)
            Pong.writeJSON(pairsPath, db)
        }
    }
}

// MARK: - Team residue cleanup

/// Sole remove / prune path for seats and topology orphans.
/// Map Kill, Architecture delete, and App AI should go through here so
/// `flow_graph`, canvas positions, and 3D positions stay consistent.
enum TeamSanitizer {
    /// Remove a worker seat and every topology/position residue for it.
    /// Kills tmux view windows. If last worker, kills the whole pair.
    @discardableResult
    static func removeSeat(pair: String, workerId: String) -> Bool {
        // Phase 1: inspect + tmux kill + decide outcome under lock
        enum Outcome {
            case notFound
            case lastWorker
            case remaining(workers: [[String: Any]], entry: [String: Any])
        }

        let outcome: Outcome = PairWriteLock.withLock {
            var db = PairState.loadPairsDb()
            var entry = db[pair] as? [String: Any] ?? [:]
            var ws = Workers.list(from: entry)
            guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == workerId }) else {
                return .notFound
            }
            let removed = ws.remove(at: idx)
            if let ti = removed["tmux_index"] as? Int {
                let view = "\(pair)-w\(ti - 1)"
                Pong.sh("tmux kill-session -t \(view) 2>/dev/null || true")
                Pong.sh("tmux kill-window -t \(pair):\(ti) 2>/dev/null || true")
            }
            if ws.isEmpty {
                return .lastWorker
            }
            entry["workers"] = ws
            if let first = ws.first {
                entry["claude_window_id"] = first["window_id"] ?? NSNull()
                entry["worker_window_id"] = first["window_id"] ?? NSNull()
                entry["worker_type"] = first["type"] ?? "linked"
                entry["worker_label"] = first["label"] ?? "Worker"
                entry["worker_cmd"] = first["cmd"] ?? ""
                entry["claude_mode"] = first["mode"] ?? "tmux"
            }
            entry = pruneSeatResidues(entry: entry, session: pair, removedIds: [workerId])
            entry["updated"] = Date().timeIntervalSince1970
            db[pair] = entry
            Pong.writeJSON(PairState.pairsPath, db)

            var active = Pong.loadJSON(PairState.activePath)
            if active["session"] as? String == pair {
                active["workers"] = ws
                active["updated"] = Date().timeIntervalSince1970
                Pong.writeJSON(PairState.activePath, active)
            }
            return .remaining(workers: ws, entry: entry)
        }

        switch outcome {
        case .notFound:
            return false
        case .lastWorker:
            CanvasLayout.removeKeys(session: pair, nodeIds: [workerId])
            Pairing.killPair(pair)
            Pong.log("TeamSanitizer.removeSeat \(pair)/\(workerId) last worker → killPair")
            return true
        case .remaining(let ws, _):
            CanvasLayout.removeKeys(session: pair, nodeIds: [workerId])
            Pong.log("TeamSanitizer.removeSeat \(pair)/\(workerId) remaining=\(ws.count)")
            return true
        }
    }

    /// Prune edges and positions for removed seat ids (in-memory entry).
    static func pruneSeatResidues(
        entry: [String: Any],
        session: String,
        removedIds: [String]
    ) -> [String: Any] {
        var e = entry
        let gone = Set(removedIds)
        if var graph = e["flow_graph"] as? [String: Any],
           var edges = graph["edges"] as? [[String: Any]] {
            edges.removeAll { edge in
                let fr = edge["from"] as? String ?? ""
                let to = edge["to"] as? String ?? ""
                return gone.contains(fr) || gone.contains(to)
            }
            graph["edges"] = edges
            graph["updated"] = Date().timeIntervalSince1970
            e["flow_graph"] = graph
        }
        if var pos = e["canvas_positions"] as? [String: Any] {
            for id in gone {
                pos.removeValue(forKey: id)
                pos.removeValue(forKey: "\(session)::\(id)")
            }
            e["canvas_positions"] = pos
        }
        if var m3 = e["map3d_positions"] as? [String: Any] {
            for id in gone {
                m3.removeValue(forKey: id)
                m3.removeValue(forKey: "\(session)::\(id)")
            }
            e["map3d_positions"] = m3
        }
        return e
    }

    /// Drop edges/positions that reference seats no longer on the team.
    /// Write only if dirty. Call after mutations / new team — **not** every poll.
    @discardableResult
    static func reconcile(pair: String) -> Bool {
        PairWriteLock.withLock {
            var db = PairState.loadPairsDb()
            guard var entry = db[pair] as? [String: Any] else { return false }
            let seats = FlowGraph.seatIds(in: entry)
            var dirty = false

            if var graph = entry["flow_graph"] as? [String: Any],
               var edges = graph["edges"] as? [[String: Any]] {
                let before = edges.count
                edges.removeAll { edge in
                    let fr = edge["from"] as? String ?? ""
                    let to = edge["to"] as? String ?? ""
                    return !seats.contains(fr) || !seats.contains(to)
                }
                if edges.count != before {
                    graph["edges"] = edges
                    graph["updated"] = Date().timeIntervalSince1970
                    entry["flow_graph"] = graph
                    dirty = true
                }
            }

            if var pos = entry["canvas_positions"] as? [String: Any] {
                for k in Array(pos.keys) {
                    let idPart = positionIdPart(k)
                    if !seats.contains(idPart) && idPart != "add" {
                        pos.removeValue(forKey: k)
                        dirty = true
                    }
                }
                entry["canvas_positions"] = pos
            }

            if var m3 = entry["map3d_positions"] as? [String: Any] {
                for k in Array(m3.keys) {
                    let idPart = positionIdPart(k)
                    if !seats.contains(idPart) {
                        m3.removeValue(forKey: k)
                        dirty = true
                    }
                }
                entry["map3d_positions"] = m3
            }

            pruneCanvasAll(session: pair, keepSeatIds: seats)

            if dirty {
                entry["updated"] = Date().timeIntervalSince1970
                db[pair] = entry
                Pong.writeJSON(PairState.pairsPath, db)
                Pong.log("TeamSanitizer.reconcile dirty=\(pair)")
            }
            return dirty
        }
    }

    /// Persist default topology when flow_graph is missing or has empty edges.
    static func ensureDefaultFlowGraph(pair: String) {
        PairWriteLock.withLock {
            var db = PairState.loadPairsDb()
            guard var entry = db[pair] as? [String: Any] else { return }
            let raw = entry["flow_graph"] as? [String: Any]
            let edges = raw?["edges"] as? [[String: Any]] ?? []
            if !edges.isEmpty { return }
            let defaults = FlowGraph.defaultEdges(entry: entry)
            entry["flow_graph"] = [
                "edges": defaults.map { $0.asDict() },
                "updated": Date().timeIntervalSince1970,
            ]
            entry["updated"] = Date().timeIntervalSince1970
            db[pair] = entry
            Pong.writeJSON(PairState.pairsPath, db)
            Pong.log("TeamSanitizer.ensureDefaultFlowGraph \(pair) edges=\(defaults.count)")
        }
    }

    private static func positionIdPart(_ key: String) -> String {
        if let r = key.range(of: "::") {
            return String(key[r.upperBound...])
        }
        return key
    }

    private static func pruneCanvasAll(session: String, keepSeatIds: Set<String>) {
        let path = Pong.stateDir + "/canvas-all.json"
        var all = Pong.loadJSON(path)
        guard var pos = all["canvas_positions"] as? [String: Any] else { return }
        var changed = false
        let prefix = "\(session)::"
        for k in Array(pos.keys) where k.hasPrefix(prefix) {
            let idPart = String(k.dropFirst(prefix.count))
            if !keepSeatIds.contains(idPart) && idPart != "add" {
                pos.removeValue(forKey: k)
                changed = true
            }
        }
        if changed {
            all["canvas_positions"] = pos
            all["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(path, all)
        }
    }
}

extension CanvasLayout {
    /// Remove bare + session-scoped position keys from canvas-all.
    static func removeKeys(session: String, nodeIds: [String]) {
        PairWriteLock.withLock {
            let path = Pong.stateDir + "/canvas-all.json"
            var all = Pong.loadJSON(path)
            var pos = all["canvas_positions"] as? [String: Any] ?? [:]
            for id in nodeIds {
                pos.removeValue(forKey: id)
                pos.removeValue(forKey: "\(session)::\(id)")
            }
            all["canvas_positions"] = pos
            all["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(path, all)
        }
    }
}

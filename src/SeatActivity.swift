import Foundation

/// Shared “is this seat mid-handoff?” rules for 2D glow, 3D pulse, and floor packets.
/// Keep one definition so 2D/3D cannot drift.
enum SeatActivity {
    /// True when a seat is mid-handoff (data actually moving), not merely queued/busy.
    /// Queued open jobs and sticky “busy” hints do **not** count.
    static func isActivelyWorking(status: String, role: String = "") -> Bool {
        let st = status.lowercased()
        if st.contains("hidden") || st.contains("idle") { return false }
        // YOU only lights when actually needed
        if role == "human" {
            return st.contains("human") || st.contains("takeover") || st.contains("ask")
        }
        // Real in-flight only — not “busy” (queued / soft hint)
        if st.contains("running") || st.contains("working") || st.contains("notified") {
            return true
        }
        if st.contains("human") || st.contains("takeover") || st.contains("ask") {
            return true
        }
        return false
    }

    /// True when a directed link should show live activity (packets / bright edge).
    static func linkHasLiveData(
        fromStatus: String, fromRole: String,
        toStatus: String, toRole: String
    ) -> Bool {
        if fromRole == "human" || toRole == "human" {
            return fromStatus.lowercased().contains("human")
                || toStatus.lowercased().contains("human")
        }
        return isActivelyWorking(status: toStatus, role: toRole)
            || isActivelyWorking(status: fromStatus, role: fromRole)
    }
}

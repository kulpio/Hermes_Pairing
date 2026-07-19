# Verdict: APPROVE

## Summary

team-stow-focus is implemented in `src/MenuBarApp.swift` (+ README one-liner). Stow resolves **Hermes + every worker** `window_id` via `pairWindowIds` (not primary-only), uses per-window `set visible` with miniaturize fallback, and persists `stowed` through `Workers.setStowed` with `savePairState` preserve. Front unstows first; Focus stows other `listPairs()` sessions then unstow+Front this. Options has a WINDOWS section (Hide / Show / Focus this team). Stow paths do not call `killPair`. Layout fits Hide into the Hermes row; Options sheet height bump leaves footer clear of the new section.

No blocking bugs found on code review. Build/install claimed green; not re-run here.

## Checks table

| Check | Result | Notes |
|-------|--------|-------|
| Hermes row Hide / Show toggle | **PASS** | ~2480; `· hidden` + alpha 0.55 when stowed |
| Options still present | **PASS** | Full **Options** at x=304 w=76; ends ~380 inside boxW ~404 |
| ALL worker window ids stowed | **PASS** | `pairWindowIds`: hermes + `Workers.list` each `window_id` ~1150–1163 |
| Not primary-only (`claude_window_id` alone) | **PASS** | Stow does not use only primary; workers loop covers army |
| visible + miniaturize fallback | **PASS** | `setPairWindowsVisible` try/on error ~1169–1185 |
| Missing ids skipped, flag still set | **PASS** | Empty ids no-op AS; `setStowed(true)` always on stow |
| Front unstows then raises | **PASS** | `bringToFront` ~1135 then flash |
| Focus stows others only | **PASS** | `listPairs()` + `isPairName` filters views; `other != name` ~1203–1208 |
| `savePairState` preserves `stowed` | **PASS** | Preserve list ~233 |
| `setStowed` merge (no worker wipe) | **PASS** | In-place entry update + `syncActive` ~501–508 |
| No killPair / tmux kill in stow | **PASS** | Stow MARK block clean; kill only Kill UI / remove-last-worker |
| Options WINDOWS section | **PASS** | Hide/Show/Focus + help ~3887–3906, handlers ~3997–4018 |
| New pair default unstowed | **PASS** | Absent `stowed` treated as false (`== true` checks) |
| Saved teams do not snapshot stowed | **PASS** | `SavedTeams` unchanged for stowed |
| Diff scope | **PASS** | `MenuBarApp.swift` + `README.md` only |
| `build-app.sh` re-run | **SKIP** | Claude claim; structure compile-safe |

## Blocking issues

None.

## Non-blocking nits

1. **Front raise still primary-only:** After unstow, `bringToFront` still flashes only `hermes_window_id` + `claude_window_id` (~1136–1139). Hide correctly covers the full army; Front may not raise secondary workers. Optional follow-up: flash all `pairWindowIds`.
2. **Worker-row Front does not unstow the team:** Only Hermes-row Front / Show / Options Show call unstow. If the whole team is hidden, worker Front may flash a still-invisible sibling set. Prefer team unstow there later.
3. **Unstow deminiaturize only on `set visible` error:** If stow used miniaturize successfully, unstow always tries `visible true` first; deminiaturize is error-path only. Usually fine; belt-and-suspenders would always deminiaturize on show.
4. **Comment drift:** `pairWindowIds` comment says “same stored ids Front uses” — Stow is actually **strictly better** (all workers); Front is the incomplete one.
5. **Status menu Hide/Show:** Not implemented (task optional; OK).
6. **Bool cast:** UI uses `(entry["stowed"] as? Bool) == true`. If a writer ever stored 0/1 as number, flag would not show; current `setStowed` writes Bool.

## Residual product notes (not blockers)

- Stale Terminal window ids after user closes/reopens windows: hide no-ops those ids until `applyPair` rewrites them (pre-existing id hygiene).
- Stow is desktop-only; bridge/tmux isolation unchanged and correctly out of scope.

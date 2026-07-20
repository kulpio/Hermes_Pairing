# Claude perf verdict — make Pong smooth (HermesPong)

**Reviewer:** Claude (second-eye) · **Date:** 2026-07-20 · **Findings only — no code changed.**
**Read:** `src/Agent3DMapView.swift`, `src/PanelController.swift` (reload/poll), `src/MenuBarApp.swift`, `src/FlowGraph.swift` (WindowRecovery). Verified the live tree.

## Headline

**The beachball is not the GPU.** Grok already neutralized the render cost — MSAA `.none` (620), `wantsHDR=false` + `bloomIntensity=0` (660–662), pulse on `renderer(_:updateAtTime:)` with **`isPlaying=false` when nothing animates** (4013), poll at 4 s on `.default` with drag/interaction guards, menu timer 0.5 s. Those are the right moves — keep them.

The remaining spinner is **synchronous blocking subprocess / AppleScript calls on the main thread**, buried inside `reload()`, the 4 s poll, and `paintMission()`. `Pong.sh` is `Process()` + `waitUntilExit()`; `Pong.osascript` drives Terminal. Every one of these **freezes the main thread for the life of the subprocess** — that's the beachball on click/orbit/drag, because clicks and post-gesture ticks run `reload()`/poll on main. None of the GPU work touches this.

## 1. Ranked top-5 killers (main-thread unless noted)

| # | Killer | Function · line | Why it beachballs | When |
|---|--------|-----------------|-------------------|------|
| **1** | `tmux list-sessions` **spawned synchronously on main** | `PairState.listPairs()` → `Pong.sh(...)` `MenuBarApp.swift:188` | Blocks main for a full tmux subprocess spawn every call. Called by `updateStatus()` **and** `fillTeamPopup()` — both run in **every `reload()`** and every 4 s poll. | Every click/reload/poll, **all tabs incl. canvas** |
| **2** | `pong snapshot --compact` **python subprocess (≤500 KB) on main** | `snapshot()` → `Pong.sh(...)` `PanelController.swift:1034` | Heaviest single blocker: python spawn + 500 KB read + JSON parse, all synchronous on main. Called by `paintMission()` (835, 1049). | Every reload/poll **while on Mission** |
| **3** | `osascript` enumerating **all Terminal windows on main** | `WindowRecovery.recover/recoverAll` → `TerminalTheme.listWindows()` → `Pong.osascript(...)` (`FlowGraph.swift:285/336`) | AppleScript to Terminal iterating every window is 50–500 ms, synchronous. Poll runs `recover` (selected) or `recoverAll` (all teams) **every 4 s**. Guarded against active drag, but fires on the ambient tick and right after gestures. | Every 4 s poll (ambient freeze) |
| **4** | `PairState.loadPairsDb()` **re-read + re-parsed 5–8× per reload** | `PanelController.reload()` and helpers (787, 841, 938, 971, 1582…) | File read + JSON parse repeated within one reload. Cheaper than a subprocess but redundant, and adds up under rapid clicks. | Every reload |
| **5** | Render-thread per-frame seat loop (GPU/CPU) | `advancePulse` (`Agent3DMapView.swift`) | Iterates **all** `seatNodes` every active frame (KVC + transform writes). Bounded, and `isPlaying=false` idle-sleep already caps it — but confirm it does **not** allocate `SCNMaterial` per frame for active seats (handoff item 3). | Only while `isPlaying` (active seats / gesture) |

**Bottom line:** #1–#3 are the beachball. They're all the same bug class — a synchronous `Process`/`osascript` on the main thread inside a hot UI path.

## 2. Surgical fixes (no map rewrite)

**Principle: the synchronous `reload()`/poll path must never call `Pong.sh` or `Pong.osascript`. Paint from cached/file state on main; refresh authoritative data on a background queue and re-render via `DispatchQueue.main.async`.**

1. **#1 `listPairs()` — cache + de-shell the hot path.**
   - `updateStatus()` only needs a **count** — derive it from `loadPairsDb().keys` (file read) instead of shelling `tmux list-sessions` at all.
   - Give `listPairs()` a short TTL cache (≈4 s): return the cached list synchronously; refresh the tmux query on a background queue and update the cache. `fillTeamPopup()` reads the cache. Net: zero synchronous tmux spawns on click.

2. **#2 `snapshot()` — flip primary/fallback order.**
   - The file fallback already exists (`Pong.loadJSON(stateDir + "/snapshot.json")`, line 1041). Make it the **synchronous primary** for `paintMission()` (instant paint from `lastSnapshot`/file), and move the `pong snapshot` subprocess to a **background queue**; when it returns, update `lastSnapshot` and repaint via `DispatchQueue.main.async`. Never block main on the 500 KB python call. Coalesce so a rapid tab-switch doesn't launch overlapping snapshots.

3. **#3 `WindowRecovery` — off the main thread + throttle.**
   - In the poll, run `recover(session:)`/`recoverAll()` on a **background queue** (the code comment even says osascript is "reliable off main thread"); apply the db mutation back on main. It's reliability, not render-critical, so it must not sit in the synchronous poll body.
   - Throttle `recoverAll()` (all-teams osascript enumeration) to every ~3rd poll (~12 s) — it's the most expensive and least time-sensitive.

4. **#4 `reload()` — load the db once.**
   - Fetch `PairState.loadPairsDb()` once at the top of `reload()` and thread it into `refreshCanvas`/`paintMission`/helpers instead of 5–8 re-parses. Free win, less GC churn under rapid clicks.

5. **#5 render loop — confirm no per-frame material alloc.**
   - Verify `advancePulse` writes only node transforms + ring `mat.diffuse` opacity. If it reassigns `unlitEdge`/face materials per frame for active seats, add a dirty-flag (rewrite only on activity/color change). Keep the `isPlaying=false` idle-sleep exactly as is — that's the "idle GPU near zero" win.

**General guard:** wrap `Pong.sh`/`Pong.osascript` with a debug assert / log if called on `Thread.isMainThread` from the poll/reload path, so this class of regression is caught early.

## 3. What Grok should NOT touch (already correct — do not regress)

- MSAA `.none`; `wantsHDR=false`; `bloomIntensity=0`/`bloomThreshold=1` (GPU cost gone).
- `renderer(_:updateAtTime:)` motion with the **`isPlaying=false` idle-sleep** (620/4013) — the single best GPU win; keep it.
- Poll at **4 s on `.default`** + `canvasDragging` / `map3D.isUserInteracting` early-returns (743–748) — keep; it correctly pauses heavy work during drag/orbit.
- Live-resize guard in the render loop (`isLiveResizing`/`inLiveResize`, 4004).
- Menu timer 0.5 s (2435).
- `map3D.reload` skipping during interaction (`isUserInteracting`, 2792).
- Prior fidelity work (edge/plane/link/bloom-off look, human "light-behind" disc, glass body) — visual, not a perf lever; leave it.

## 4. Verification checklist

- [ ] **Orbit 10 s continuously** and click rapidly across tabs → no beachball. (Main thread never blocks on `Process`/`osascript`.)
- [ ] Instruments Time Profiler / main-thread trace during interaction shows **no `waitUntilExit` / `osascript` on the main thread** in the reload/poll path.
- [ ] Switch to Mission and idle 20 s → no periodic freeze every 4 s (snapshot is async).
- [ ] With "All teams" selected, idle → no ~4 s ambient stutter (recoverAll off-main + throttled).
- [ ] **Idle with no active seats:** `scnView.isPlaying == false`, GPU near zero.
- [ ] Regression: seats still bob/yaw during orbit; faces square; attach still self-closes; look unchanged (bloom stays off).

---

*Saved to `docs/CLAUDE_PERF_SMOOTH_VERDICT.md`. Findings only — no code changed. Scope: HermesPong under explicit operator override (not Umbra).*

# Review checklist: team-stow-focus (Hide / Show / Focus)

**Role:** hermes-pair-1 reviewer (prep only; do **not** implement Stow unless Claude is blocked).  
**Task brief:** `~/.hermes-pong/tasks/team-stow-focus.md`  
**Repo:** `/Users/dylandemnard/src/Hermes-Pong`  
**Primary file:** `src/MenuBarApp.swift`

---

## What exists today (baseline Claude must extend)

| Piece | Location | Behavior |
|-------|----------|----------|
| Hermes row | ~2395–2400 | `[Front] [Kill] [Options]` — widths 46 / 42 / 76 at x=172 / 220 / 264 |
| `bringToFront` | ~1115–1128 | Loads `pairs.json[session]` (else active if same session); flashes **only** `hermes_window_id` + `claude_window_id` (primary). Fallback: tmux switch + Terminal activate |
| `flashPairWindows` | ~1097–1112 | AppleScript: set index, activate, **`set visible … false`**, delay, **`true`**, re-raise |
| Worker Front | ~524–527 | Flashes that worker’s `window_id` only |
| Window id storage | pair start / link / `TerminalTheme.applyPair` | Pair-level: `hermes_window_id`, `claude_window_id` / `worker_window_id` (primary). Per worker: `workers[i].window_id`. `applyPair` can **re-resolve** via view token (`hermes-pair-N-h`, `…-w0`) and rewrite stale ids |
| `savePairState` preserve | ~232–235 | Today: `view_*`, `display_name`, `colors`, `project_root`, `team_brief` — **no `stowed` yet** |

**Critical gap for multi-worker teams:** Front today often raises Hermes + **one** primary worker, not every `workers[].window_id`. Stow/Focus must still operate on **all** team Terminal windows, or Hide leaves stray worker panes on screen.

---

## Scope to review when Claude lands

| Area | Must see |
|------|----------|
| Row UX | Hide / Show toggle; Options still present (Opts OK); stowed dim / `· hidden` |
| `Pairing.stow` / `unstow` | Saved window ids only; AppleScript visible (± miniaturize fallback); set `stowed` |
| `bringToFront` | Unstow first if `stowed`, clear flag, then raise |
| Focus this team | Options (or row): stow **others**, unstow+Front **this** |
| State | `pairs.json` `stowed`; preserve on `savePairState`; new/link/spawn → `false` |
| Side effects | No `killPair`, no tmux kill/detach, no TUI inject, workers list intact |
| Build | `bash scripts/build-app.sh` exit 0; diff mainly `MenuBarApp.swift` |

---

## 1. Wrong-window hide risk (highest severity)

Stow that hits the wrong Terminal window is worse than not shipping Hide.

### Must resolve ids the same way Front intends (and better)

- [ ] Stow/unstow builds the id list from **this session’s** entry only:
  - `hermes_window_id`
  - **every** `workers[i].window_id` that parses as `Int`
  - Do **not** rely solely on `claude_window_id` if multi-worker (primary only)
- [ ] **Never** use frontmost / “window 1” / title substring alone as the sole target without id check
- [ ] Skip missing / null / non-numeric ids; continue others; **do not crash**; still allow marking `stowed` (per task)
- [ ] Prefer reusing or sharing a helper with Front so Hide and Front cannot drift (same id list)

### Stale / recycled window ids

Terminal window ids are not permanent across relaunch or “Close Window”.

- [ ] If stored id no longer exists: AppleScript `try` per window (flash already uses try); no exception path that aborts half the team mid-loop
- [ ] Optional (nice): before hide, resolve via `TerminalTheme.resolvePairWindow` / view token like `applyPair` — if Claude skips, document that stale ids no-op until Front/theme refresh rewrites them
- [ ] **Do not** “hide all Terminal windows” or “hide every window whose title contains Hermes”
- [ ] Focus must not stow pair B by accidentally using pair A’s ids (iterate sessions; load each entry independently)

### Cross-pair chaos scenarios to force in review

- [ ] Two live pairs, 4+ Terminals: Hide A → only A’s windows disappear; B stays
- [ ] Hide A, then Hide B, then Show A → A returns, B still hidden
- [ ] Worker removed from team (ids updated): stow does not reference removed worker’s old id as a hard failure
- [ ] Window-mode link pairs (if still supported): ids on workers, not only tmux views

---

## 2. Visible vs miniaturize

Task: prefer `set visible of window id X to false/true`; fallback miniaturize / deminiaturize.

- [ ] Primary path matches existing flash style (`set visible of …`) — already proven in-tree ~1107–1109
- [ ] Fallback only when visible is flaky / errors — not double-apply both always (can leave dock zombies or inconsistent state)
- [ ] Unstow: `visible true` **and** deminiaturize if miniaturized, so Show recovers either strategy
- [ ] Stow does **not** close windows (`close window`) — that kills the session UX and can detach TUI state
- [ ] Stow does **not** quit Terminal
- [ ] Idempotent: Hide twice, Show twice — no error spam, final state correct
- [ ] Flash after Show: flash itself toggles visible false→true; if stowed flag not cleared first, panel can lie (“Show” while windows are up). Order: **unstow state + visible true**, then flash

---

## 3. Front must unstow

Today `bringToFront` does **not** read `stowed`. After Task, it must.

- [ ] `bringToFront(session)` (and Hermes-row Front handler path): if `stowed == true` → unstow (visible true, `stowed = false`, persist) **then** existing raise/flash
- [ ] Front never leaves `stowed: true` while windows are visible
- [ ] Front on a non-stowed pair: behavior unchanged (still flash / tmux fallback)
- [ ] Worker-row Front: at least raises that worker; ideally if whole team was stowed, unstow team first (or document worker Front does not unstow siblings — prefer team unstow so user isn’t confused)
- [ ] After Hide, Front alone is enough to get the team back without pressing Show (acceptance: “Front unstows then raises”)

---

## 4. Focus this team

```
for each other session in live pairs: stow(other)
unstow(this)
bringToFront(this)
```

- [ ] “Other” = other live pair sessions (same source as panel list / `PairState` pair keys that are real pairs), **not** view sessions (`hermes-pair-1-h`, `-w0`)
- [ ] Never stow `this` in the loop then forget unstow
- [ ] Order: stow others first, then unstow+Front this (so this doesn’t get briefly hidden if implementation stows all)
- [ ] Persist `stowed` on each affected pair (others true, this false)
- [ ] Panel refresh: this row Show→Hide label; others show Show / dimmed
- [ ] Bridge/tmux still work for stowed pairs (Focus is window-only)
- [ ] Options help line present: hides Terminal windows only; pair + tmux keep running

---

## 5. `savePairState` must preserve `stowed`

Same class of bug as Task 1 `project_root` wipe.

Current preserve list (~232–235):

```swift
for k in ["view_hermes", "view_claude", "view_worker",
          "display_name", "colors", "project_root", "team_brief"] {
    if let v = prev[k] { entry[k] = v }
}
```

- [ ] **`stowed` added to preserve list** (Bool in JSON — careful: `if let v = prev[k]` works for `true`/`false` boxed in NSNumber/Bool; verify empty false is preserved, not dropped)
- [ ] Stow/unstow writers merge into existing entry (like `setTeamOptions`) — do not rebuild entry without workers
- [ ] `setTeamOptions` / colors / rename / applyPair rewrites do **not** wipe `stowed`
- [ ] New pair / Link / spawn: explicit `stowed = false` (or absent treated as false in UI)
- [ ] `active-pair.json` updated only when `active.session == pair` (same `syncActive` pattern)
- [ ] Saved teams (`teams.json`): **do not** need to persist stowed (live desktop state only) — confirm Claude doesn’t accidentally snapshot stowed into reusable teams

---

## 6. No kill side effects

- [ ] Stow/unstow code paths do **not** call `Pairing.killPair`, `Workers.removeWorker`, `tmux kill-*`, or clear `workers` / window ids from JSON
- [ ] Kill button still kills the pair (unchanged)
- [ ] Hide then Kill: pair dies cleanly; no orphan “stowed true” required but OK if entry removed
- [ ] No paste/inject into Hermes or worker TUIs
- [ ] No detach of tmux sessions; panes keep running under hide
- [ ] Bridge (`pong-delegate`) still targets tmux panes while windows are invisible

---

## 7. Button width / clip

Current Hermes row ends Options at ~x=340. Adding Hide requires re-layout.

Task allows:

```
[Front] [Hide] [Kill] [Opts]
```

or full Options if width allows.

- [ ] Four controls fit `boxW` without clipping into worker tree or scrollbar
- [ ] Labels: **Hide** ↔ **Show** when `stowed` (title swap, not a second button)
- [ ] **Opts** only if needed; toolTip still “Team options” / full word
- [ ] Worker rows unchanged (still Front / Kill / Perms) — Hide is **Hermes-row / team-level**, not per-worker
- [ ] Stowed affordance: dimmed row and/or title `· hidden` without breaking rename click target
- [ ] Legend/help strings updated if they still say `Front / Kill / Options` only (~2283)
- [ ] Status menu Hide/Show: optional; skip if thrashy

---

## Must-verify manual matrix (post-PR)

| Case | Expect |
|------|--------|
| Hide one of two pairs | Only that pair’s Terminals vanish; other pair fully visible |
| Show after Hide | Same windows return; `stowed` false; button Hide again |
| Front while stowed | Unstows + raises; flag false |
| Focus this team | Others stowed; this visible and frontmost |
| Hide with multi-worker army (3 workers) | All worker windows + Hermes hide, not just primary |
| Missing worker window_id | Other windows still hide; no crash |
| Hide then send task via bridge | Task still pastes to tmux worker |
| New pair after Focus | New pair visible, `stowed` false |
| `savePairState` after stow (re-link path / theme) | `stowed` still true until Show/Front |
| `build-app.sh` | exit 0 |

### Quick rg acceptance

```bash
rg -n "stow|stowed|Focus this team" src/MenuBarApp.swift
rg -n "stowed" src/MenuBarApp.swift   # savePairState preserve + writers
rg -n "killPair" src/MenuBarApp.swift # stow functions must not call it
# Confirm stow helpers don’t share killPair body
bash scripts/build-app.sh
```

---

## What not to do as reviewer

- Do **not** implement stow/focus unless Hermes escalates and Claude is stuck.
- Do **not** expand into Spaces/Mission Control, session-keyed last-claude, or GH release.
- Do **not** change bridge isolation in this task unless a stow bug forces a one-line comment.

---

## Reviewer note: Front id list incompleteness

Even without Stow, `bringToFront` only flashes Hermes + primary `claude_window_id`. For Stow acceptance, **Hide must cover the full worker list**. Prefer Claude also fixes Front to raise all team windows when touching this path; if not, call it a **non-blocking nit** only if Hide/Show/Focus are complete for all workers.

# Review checklist: team-activity-grok-build

**Role:** hermes-pair-1 reviewer (prep only; do **not** implement Activity / Grok Build / viewer unless Claude is blocked).  
**Task brief:** `~/.hermes-pong/tasks/team-activity-grok-build.md`  
**Repo:** `/Users/dylandemnard/src/Hermes-Pong`  
**Hard rule (task + product):** **NO stream window** — no `ClaudeStreamController`, no live token mirror, no “Watch worker” side panel. Pairing + bridge remain the only handoff path.

**Canonical reject note:** `~/.hermes/skills/macos-menu-bar-apps/hermes-pong/references/claude-stream.md` — *“Claude stream — REMOVED. Do not re-add ClaudeStreamController, auto-open after Link, or a panel stream button.”* See handoff **inside** the worker TUI (paste + Enter), not a second surface.

---

## Baseline (what exists before Claude)

| Area | Today |
|------|--------|
| `rebuildList` | ~2430+: Hermes hub + worker rows; **no Activity strip** |
| Panel refresh | Manual **Refresh** + event-driven `refreshUI()`; **no** panel activity timer |
| AppDelegate timer | 0.1s `tick()` for bolt glow only; `pairSessions()` cached ≤2s for status menu |
| `WorkerType` | `id: "grok"`, label **"Grok"**, cmd `grok` ~272 |
| Session artifacts | Bridge writes `~/.hermes-pong/sessions/<session>/last-{claude,sent}.txt`; top-level `last-*.txt` = **active-session mirror only** |
| `hermes_pong.py` | Already has `session_dir`, `last_reply_path`, `last_sent_path`, `last_worker_reply`, `last_sent`; status prints paths. Task may add aliases / `last-reply` CLI |
| Swift placeholder | `savePairState` still seeds global `…/last-claude.txt` if missing (~250) — UI must not treat that as per-pair truth |
| Floating windows | Several sheets use `win.level = .floating` (Options, pickers, etc.). **Reply viewer must not** |

Session path truth (bridge already):

```
~/.hermes-pong/sessions/<session>/last-claude.txt   # source of truth per pair
~/.hermes-pong/sessions/<session>/last-sent.txt
~/.hermes-pong/last-claude.txt                      # ACTIVE session mirror only
~/.hermes-pong/last-sent.txt
```

Skill/routing already warn: with several pairs live, always read the session file.

---

## Scope to review when Claude lands

| Area | Files |
|------|--------|
| Activity strip + status | `src/MenuBarApp.swift` `rebuildList` / helpers |
| Reply viewer | New small controller in MenuBarApp (or tiny adjacent) — **not** stream |
| Grok Build label | `WorkerType.all`, team builder, any picker copy |
| Paths / CLI | `scripts/hermes_pong.py` (optional aliases + `last-reply` subcommand) |
| Docs | README / PRODUCT-MULTI-WORKER / skill note OK |

Diff should stay focused; no bridge protocol rewrite.

---

## 1. Accidental stream UI (hard fail)

Product intentionally killed stream windows. Activity is **file status + on-demand viewer**, not a live feed.

### Fail the PR if any of these appear

- [ ] Class/name resembling `ClaudeStreamController`, `StreamPanel`, `TokenMirror`, `WatchWorker`
- [ ] Window that polls/appends worker stdout in real time (WebSocket, continuous capture-pane loop into UI)
- [ ] Auto-open viewer on every handoff / every Done detection
- [ ] “Live” / “Streaming” / “Watch” chrome implying token mirror
- [ ] New always-visible secondary panel that stays open and scrolls as the worker types

### Pass criteria

- [ ] Viewer opens only from **Open reply** / **Open sent** (or explicit status click)
- [ ] Viewer loads a **static snapshot** of a file (Refresh re-reads file; no live stream)
- [ ] `rg -n "Stream|ClaudeStream|token mirror|Watch worker" src/` → no new stream surface
- [ ] Bridge path unchanged (still `pong-delegate` paste + Enter)

---

## 2. Wrong global `last-claude` path (cross-pair bleed)

This is the same class of bug as multi-pair isolation.

### Path rules

| Action | Correct path | Wrong path |
|--------|--------------|------------|
| Activity status for pair S | `sessions/S/last-claude.txt` + `sessions/S/last-sent.txt` | Always `~/.hermes-pong/last-claude.txt` |
| Open reply for pair S | Session file first; **fallback** global only if session file missing | Open global when session file exists |
| Open sent for pair S | Same | Same |
| Two pairs live, both Working | Each row reads **its** session dir | Both show active pair’s reply |

### Must-verify cases

- [ ] Pair A Active, pair B Idle: Activity on B uses B’s mtimes/content, not A’s
- [ ] Open reply on B never shows A’s transcript when B has its own file
- [ ] Fallback: if `sessions/B/last-claude.txt` missing, global only as last resort (and label UI so user knows it may be wrong / empty)
- [ ] Swift path construction matches Python:
  - `~/ .hermes-pong/sessions/<session>/last-claude.txt`
  - Prefer shared constant / same as `hermes_pong.last_reply_path`
- [ ] Status detection compares **session** last-sent vs last-claude mtimes, not global
- [ ] CLAIM one-liner parsed from **session** last-claude text

### Status logic (team-level required)

Task table (keep dumb):

| Status | Rule |
|--------|------|
| **Done** | last-claude mtime recent enough + done marker (`##CLAUDE_DONE##` or `##WORKER_DONE##`) in last ~4k chars + **no newer last-sent** after that mtime |
| **Working** | last-sent mtime **>** last-claude mtime (handoff in flight) |
| **Idle** | else |

- [ ] Shared file → **team-level** Activity required; per-worker rows nice-to-have only
- [ ] CLAIM parse: prefer `notes:` else `files:`; truncate ~80 chars; no crash on empty/garbage
- [ ] Missing files → Idle / empty claim, no exception

### `hermes_pong.py`

- [ ] Paths still session-scoped; if Claude adds `session_last_reply_path` aliases, they must point at same files as `last_reply_path` / `last_sent_path`
- [ ] CLI `last-reply` (if added): default bound session; `-s` override; never prints another pair’s file without `-s`
- [ ] Do not remove existing `session_dir` / status path lines

---

## 3. Refresh cost

Panel currently rebuilds the whole list on each `refreshUI()` (destroy all subviews). Activity makes that heavier if done too often.

### Hunt

- [ ] **Do not** hook Activity into the 0.1s bolt `tick()` (would rebuild list 10×/s)
- [ ] If a timer is added for Activity: **2–5s** max, and only while panel is visible / key; stop on close
- [ ] Prefer: refresh on existing Refresh button + after Hide/Front/Options/handoff-related UI actions already calling `refreshUI`
- [ ] File I/O: mtime + small tail (last 4k) — not full multi-MB read on every poll
- [ ] Full file read only when opening viewer (cap e.g. 1.5MB with head notice)
- [ ] `listPairs()` / tmux already cached 2s on menu — do not add another aggressive tmux poll just for status
- [ ] Rebuild list should not re-layout so hard that scroll position jumps every 2s (if timer exists, preserve scroll or only update status labels)

### Acceptable cheap designs

1. No timer: Activity updates only when user hits Refresh / panel actions  
2. Slow timer (2–5s) updating status labels only  
3. Timer gated: panel `isVisible` only  

Reject: 0.1–0.5s full `rebuildList` with multi-file reads for every pair.

---

## 4. Grok rename breaking saved teams (`type=grok`)

Task: **relabel only** preferred. Keep id `grok`.

### Safe change

```swift
WorkerType(id: "grok", label: "Grok Build", cmd: "grok", …)
```

### Fail modes to catch

- [ ] Changing id to `grok-build` without alias → saved teams / pairs.json with `"type": "grok"` resolve wrong or as custom
- [ ] `WorkerType.named("grok")` / `resolved("grok")` still return Build label + cmd `grok`
- [ ] Team builder list shows **Grok Build** (filter still `id != custom`)
- [ ] Spawn path: saved worker `type: grok` still launches `grok` CLI
- [ ] Bridge / done marker: grok still `##WORKER_DONE##` (not CLAUDE_DONE)
- [ ] If alias `grok-build` added: must resolve to same cmd/marker; SavedTeams round-trip still works with either id
- [ ] Live pair labels already stored as `"Grok"` in workers[]: UI can show stored label; new pairs get “Grok Build”. Do not force-rewrite all pairs.json labels unless intentional
- [ ] README / PRODUCT: SuperGrok one-liner; Pong does not host API keys
- [ ] Do not invent a new hosted model or API key UI

### Quick checks

```bash
rg -n 'id: "grok"|Grok Build|WorkerType' src/MenuBarApp.swift
# teams.json / pairs may still say type grok — spawn must still work
```

---

## 5. Viewer always-on-top

Several app sheets intentionally use `win.level = .floating` (team picker, Options, permissions). **Reply viewer must not copy that pattern.**

### Must-verify

- [ ] Viewer level is **normal** (default `NSWindow` / `.normal`) — not `.floating`, not `.statusBar`, not `.popUpMenu`
- [ ] Does not force `orderFrontRegardless` on a loop
- [ ] Does not steal focus from worker Terminal on every Refresh
- [ ] Title: `Reply · <display or session> · <team or worker>`
- [ ] Read-only `NSTextView` + scroll; monospaced or system ~12pt
- [ ] Buttons: **Refresh**, **Reveal in Finder**, **Close**
- [ ] Cap huge files (~1.5MB) with a clear head/truncated notice
- [ ] User-initiated only (no auto-pop on Done); optional “new” badge on Activity is OK without opening window
- [ ] Closing viewer does not kill pair / does not call killPair

---

## Activity strip UX (acceptance shape)

Under each Hermes hub (after workers, before next pair):

**Required (team-level):**

```
Activity · <session or display>
  Status: Working | Done | Idle
  Last claim: <truncated notes/files>
  [Open reply]  [Open sent]
```

Optional per-worker lines if shared file only is awkward — do not block on per-worker files unless Claude adds them.

- [ ] Fits in scrollable pairs list; height budget updated in `est` / `contentH`
- [ ] Works for multi-pair (each pair own Activity)
- [ ] Copy: no em-dashes; product word **Team**
- [ ] Stowed pairs: still show Activity (files update even if windows hidden)

---

## Must-verify matrix (post-PR)

| Case | Expect |
|------|--------|
| One pair, after handoff | Working then Done when marker appears; claim line filled |
| Two pairs, different projects | Open reply on each shows correct session file |
| Global last-claude is pair A only | Pair B Activity still uses B’s session path |
| Open sent | Shows that session’s last-sent |
| Grok in New pair / Team builder | Label **Grok Build**, cmd still grok |
| Old saved team type=grok | Spawns and runs |
| No stream class | rg clean |
| Viewer not floating | Level normal; user can put Terminal above it |
| Refresh spam | No 0.1s rebuild; timer ≤5s or none |
| build + install | `build-app.sh` / `install.sh` exit 0 |

### Quick rg acceptance

```bash
rg -n "Activity|Open reply|Open sent|last-claude|sessions/" src/MenuBarApp.swift
rg -n "ClaudeStream|StreamController|Watch worker" src/ || true
rg -n "Grok Build|id: \"grok\"" src/MenuBarApp.swift
rg -n "last_reply_path|session_dir|last-reply" scripts/hermes_pong.py
# viewer level
rg -n "Reply|level =|floating" src/MenuBarApp.swift
bash scripts/build-app.sh
```

---

## What not to do as reviewer

- Do **not** implement Activity, viewer, or Grok relabel unless Hermes escalates.
- Do **not** revive stream UI “to make Activity better.”
- Do **not** expand into live Grok API, billing, or GH release.

---

## Reviewer anchors (hunt list)

1. **Stream UI** — any live token/window class = REQUEST_CHANGES  
2. **Global last-claude** — Activity/viewer must be session-first  
3. **Refresh cost** — no bolt-timer rebuild; 2–5s max or manual  
4. **Grok id** — keep `type=grok`; label-only rename preferred  
5. **Viewer level** — normal, not always-on-top floating sheet  

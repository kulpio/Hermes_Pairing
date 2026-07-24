# CyberPong — Application state report (for review)

**Date:** 2026-07-23  
**Version:** 1.4.0 (bundle; working tree ahead of last tagged commit)  
**Repo:** https://github.com/kulpio/hermes-pong  
**Local root:** `/Users/dylandemnard/Personal/Projects/HermesPong`  
**Companion reviews:**  
- [REVIEWER-HANDOFF-NOTARIZE.md](REVIEWER-HANDOFF-NOTARIZE.md)  
- [REVIEW-2026-07-22-NOTARIZE-READINESS.md](REVIEW-2026-07-22-NOTARIZE-READINESS.md)  

---

## 1. What CyberPong is now

**CyberPong** is local **multi-agent mission control** for Mac:

| Layer | Role |
|-------|------|
| **macOS app** | Menu bar + panel; 3D map is home; optional 2D canvas |
| **Control plane** | Python `pong` package — jobs, claims, snapshot, flow enforcement |
| **Seats** | Real Terminal/tmux sessions (Grok, Claude, Hermes, Codex, …) |
| **State** | `~/.pong/` — teams, jobs, ledger, human console, settings |
| **Guide** | In-app co-pilot (provider headless chat + recipe team create) |

**Does not store vendor API keys.** Users log into their own CLIs.

---

## 2. User journeys (current)

### 2.1 First open
1. Panel opens on **3D map** (preview constellation if no team).  
2. **Guide pill** (if no App AI onboarding): Welcome → pick AI → sign-in Terminal → **Build team**.  
3. **Quick Team** (30s): Solo / Pair / Squad → name + builder model → Launch.  
4. Map **coach marks** (YOU / TASKS / CRON / TRACKING).  
5. Map **sparkle Guide** for later questions.

### 2.2 New team (toolbar / Setup)
- **Default:** `QuickTeamBuilder` — two screens, recipe cards.  
- **Advanced:** “Advanced wizard…” → full multi-step `TeamInstallWizard` (architecture canvas, policy, cron, scaffold).

### 2.3 While working
- Jobs via conductor + `pong job create`; architecture **road** enforced.  
- Every job re-injects **seat identity** + **claim/assign hops**.  
- YOU chat: per-team history, clear, expand.  
- Architecture sheet: click seat → name + purpose + link; bend links (persist).

---

## 3. Team create redesign (this pass)

**Problem:** Long “Windows 98” wizard (names → architecture → roles → policy → cron → review) was too slow and confusing.

**Solution — Quick Team (default):**

| Screen | Content |
|--------|---------|
| 1 | **Solo / Pair / Squad** big cards (emoji + one line) |
| 2 | Team name · who builds (Claude/Grok/Codex/Hermes chips) · roster preview · **Launch** |
| Optional | Advanced wizard for power users |

**Recipes → roles locked automatically:**

| Recipe | Seats |
|--------|--------|
| Solo | Boss + **Builder** (coder) |
| Pair | Boss + **Builder** + **Checker** (reviewer) |
| Squad | Boss + **Builder** + **Checker** + **Runner** (operator) |

**Code:** `src/QuickTeamBuilder.swift`  
**Entry:** `AppDelegate.launchTeamWithOptionalWizard` → Quick Team only.  
**Onboarding:** “Build team” opens the same Quick Team.

---

## 4. Review findings — status

From [REVIEW-2026-07-22-NOTARIZE-READINESS.md](REVIEW-2026-07-22-NOTARIZE-READINESS.md):

| ID | Finding | Status |
|----|---------|--------|
| §3.1 | App not self-contained (`python/pong` missing from zip) | **Mitigated** — `build-app.sh` rsyncs `python/pong` → `Resources/python`; launch seeds `~/.pong/lib` if empty; `Isolation.pythonPath` prefers bundle |
| §3.2 | `grok --yolo` headless auto-approve | **Fixed** — removed from `headless.py` + Guide argv |
| §3.3 | Uncommitted tree / no tag | **Open** — process; must commit → tag → build → sign |
| §6 | Theme AppleScript invalid props | **Fixed** — removed `close if shell exited cleanly` / `prompt before closing` |
| P1 path traversal | Session/job name allowlist | **Open** |
| P1 atomic writes | Swift pairs.json atomic | **Open** (PairWriteLock in-process only) |
| P1 Accessibility preflight | AX trust check | **Open** |
| Terminal.plist rewrite | Fragile | **Open** |

**Notarization:** Pipeline OK; blocked on Developer ID credentials + clean tagged build.

---

## 5. Source map (important files)

### 5.1 Swift app (`src/`)

| File | Purpose |
|------|---------|
| `main.swift` | App entry |
| `MenuBarApp.swift` | Pairing, Terminal/tmux, theme, AppDelegate, Isolation, wireArmy, state |
| `PanelController.swift` | Main panel, 2D/3D, Setup access map, New team, add agent |
| `Agent3DMapView.swift` | 3D constellation, YOU/TASKS/CRON/TRACKING HUD |
| `AgentCanvasView.swift` | 2D canvas, positions, working glow, flow edges |
| `TeamArchCanvas.swift` | Architecture editor (wizard + live sheet) |
| `FlowGraph.swift` | Topology load/save, Architecture sheet host, 3D layout helpers |
| `TeamInstallWizard.swift` | **Advanced** multi-step wizard (optional) |
| `TeamSanitizer.swift` | Seat remove + pair write lock + residue prune |
| `SeatActivity.swift` | Shared “working” detection 2D/3D |
| `ConductorKickoff.swift` | First conductor paste + activate jobs |
| `TeamFocusController.swift` | Focus UI + HumanConsoleController |
| `CronSchedule.swift` | Cron model + UI hooks |
| `PongTheme.swift` / `PongSheetChrome.swift` | Design tokens |
| **`QuickTeamBuilder.swift`** | **Default 30s team create** |
| `AppAIOnboarding.swift` | First-run Guide pill |
| `AppAISettings.swift` | Provider / onboarding / flags in settings.json |
| `AppAIRuntime.swift` | Login Terminal → headless chat |
| `AppAIChatBubble.swift` | Map sparkle Guide chat |
| `AppAIMutator.swift` | Allowlisted team/architecture mutations |
| `AgentGuideTutorial.swift` | Post–add-agent walkthrough |
| `MapCoachMarks.swift` | First-run HUD callouts |

### 5.2 Python control plane (`python/pong/`)

| File | Purpose |
|------|---------|
| `cli/main.py` | `pong` CLI (`job`, `architecture recap`, `seat brief`, …) |
| `jobs.py` | Job create + `build_task_prompt` (identity + road) |
| `flow.py` | Edge enforcement (`effective_edges`, hop refuse) |
| `handoff_recap.py` | Per-seat architecture recap text |
| `role_identity.py` | Durable role catalog + seat identity blocks |
| `state.py` | Pairs, bind cards, gate |
| `snapshot.py` | UI snapshot contract |
| `routing.py` | Session isolation / tokens |
| `transports/headless.py` | Non-interactive worker dispatch (**no --yolo**) |
| `transports/tmux_paste.py` | Paste into panes |

### 5.3 Scripts & packaging

| Path | Purpose |
|------|---------|
| `scripts/build-app.sh` | Universal build; **bundles `python/pong`**; ad-hoc sign |
| `scripts/sign-notarize.sh` | Developer ID + notary + staple + zip |
| `scripts/install.sh` | Copy to `/Applications` |
| `scripts/setup.sh` | Dev machine: CLI + lib install |
| `resources/entitlements.plist` | `automation.apple-events` only |
| `share/*-pong-bridge/` | Conductor skill packs |

### 5.4 Docs (review pack)

| Path | Purpose |
|------|---------|
| `docs/REVIEWER-HANDOFF-NOTARIZE.md` | Links, notarize checklist, TODOs |
| `docs/REVIEW-2026-07-22-NOTARIZE-READINESS.md` | Security/code review verdict |
| `docs/DESIGN-APP-AI-2D-OPENCLAW-TELEMETRY.md` | Design for AI/2D/OpenClaw |
| `docs/ARCHITECTURE.md` | Control plane architecture |
| `docs/UI-CONTRACT.md` | Snapshot contract |
| **`docs/REPORT-APP-STATE-2026-07-23.md`** | **This report** |

---

## 6. Runtime layout (user machine)

```text
~/.pong/
  pairs.json          teams / seats / flow_graph / roles
  jobs/<session>/     job JSON
  human/<session>/    YOU chat log (per team)
  settings.json       app_ai, coachmarks, prefer_3d_map
  lib/pong/           control plane (seeded from bundle if empty)
  app-ai/             Guide history + runtime
  binds/, briefs/, ledger/, sessions/
```

**App bundle (release):**

```text
CyberPong.app/Contents/
  MacOS/Pong
  Resources/python/pong/   ← self-contained package
  Resources/*.png, Info.plist, …
```

---

## 7. Remaining risks & next work

### Must before public notarized zip
1. **Commit + tag** clean tree matching the binary.  
2. **Developer ID + notary profile** → `bash scripts/sign-notarize.sh`.  
3. **Clean Mac smoke** (no prior `~/.pong/lib`) — verify jobs/gate work from bundle alone.  
4. **Gatekeeper smoke** after staple.

### Should soon
5. Session/job path allowlist (path traversal).  
6. Atomic Swift writes for `pairs.json`.  
7. Accessibility preflight for window-relay.  
8. Replace Terminal.plist rewrite.  
9. Scrub env for headless; `chmod 0600` prompt files.  

### Product polish
10. Quick Team: optional project folder; conductor picker (not only Grok).  
11. Retire or hide advanced wizard further if unused.  
12. OpenClaw type (`openclaw tui`) when ready.  

---

## 8. How to build & test (reviewer)

```bash
cd /path/to/hermes-pong   # or HermesPong

bash scripts/build-app.sh
# Expect: "Bundled python/pong into Resources"
ls dist/CyberPong.app/Contents/Resources/python/pong/__init__.py

bash scripts/install.sh
open /Applications/CyberPong.app

# 30s team path
# New team → Solo/Pair/Squad → name → Claude/Grok → Launch

# CLI (after seed or with PYTHONPATH)
export PYTHONPATH="$HOME/.pong/lib"
# or: export PYTHONPATH="…/CyberPong.app/Contents/Resources/python"
pong check
```

---

## 9. Summary for a busy reviewer

| Question | Answer |
|----------|--------|
| Is the product direction coherent? | **Yes** — local multi-CLI teams + jobs as truth + map UI. |
| Is the default create-team flow simple enough? | **Much improved** — Quick Team recipes (~30s); advanced wizard optional. |
| Is a fresh notarized zip usable? | **Much closer** — python bundled + first-run seed; still need clean-Mac verification. |
| Ready to notarize? | **Pipeline yes; credentials + tagged build + smoke no.** |
| Highest residual risks? | Untagged local source; path validation; Terminal prefs hacks; headless still powerful once user CLIs allow it (no longer `--yolo` by default). |

---

*End of report. Prefer this file + the 2026-07-22 readiness review when sharing with external reviewers.*

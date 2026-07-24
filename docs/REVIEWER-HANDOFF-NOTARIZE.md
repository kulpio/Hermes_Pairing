# CyberPong — Reviewer handoff (notarization + product state)

**Date:** 2026-07-22  
**Product:** CyberPong (local multi-agent mission control for Mac)  
**Primary goal of this handoff:** Get a **Developer ID–signed, Apple-notarized, stapled** `.app` / zip that users can open without Gatekeeper blocks.  
**Secondary:** Share context so a reviewer can assess quality, risks, and next work.

---

## 1. Important links

| What | Link / path |
|------|-------------|
| **GitHub (origin)** | https://github.com/kulpio/hermes-pong |
| **Related remote (agent)** | https://github.com/kulpio/Agent-Pong |
| **Local project root** | `/Users/dylandemnard/Personal/Projects/HermesPong` |
| **Installed app (dev)** | `/Applications/CyberPong.app` |
| **Built app (dist)** | `dist/CyberPong.app` |
| **Release zip (when shipped)** | `dist/CyberPong-macOS.zip` |
| **State on disk** | `~/.pong/` (jobs, teams, ledger, human console, settings) |
| **App log** | `~/Library/Logs/Pong.log` |
| **README** | [README.md](../README.md) |
| **Architecture** | [docs/ARCHITECTURE.md](ARCHITECTURE.md) |
| **UI contract** (`pong snapshot`) | [docs/UI-CONTRACT.md](UI-CONTRACT.md) |
| **3D map notes** | [docs/UI-3D-MAP.md](UI-3D-MAP.md) |
| **Roadmap** | [docs/ROADMAP.md](ROADMAP.md) |
| **Remaining TODO (older)** | [docs/REMAINING_TODO.md](REMAINING_TODO.md) |
| **App AI / 2D / OpenClaw design** | [docs/DESIGN-APP-AI-2D-OPENCLAW-TELEMETRY.md](DESIGN-APP-AI-2D-OPENCLAW-TELEMETRY.md) |
| **Notarize checklist (ops)** | `~/Desktop/CyberPong-notarize-checklist.md` (also summarized below) |
| **Sign / notarize script** | `scripts/sign-notarize.sh` |
| **Build app** | `scripts/build-app.sh` |
| **Install to /Applications** | `scripts/install.sh` |
| **Entitlements** | `resources/entitlements.plist` |
| **Latest GitHub release pattern** | `https://github.com/kulpio/hermes-pong/releases` |

**Naming note:** UI = **CyberPong**. Bundle = `CyberPong.app`. Executable inside still = `Pong`. CLI = `pong`. State = `~/.pong/`.

---

## 2. What the product is (one paragraph)

CyberPong is a **macOS menu-bar + panel app** that runs **multi-CLI agent teams** on the user’s machine: a conductor (Grok / Hermes / Claude / custom) plans and assigns work; workers (Claude, Grok, Codex, …) run in real Terminal/tmux sessions; jobs and claims live as files under `~/.pong/`. The 3D map is the home surface. The app does **not** store vendor API keys; users sign into their own CLIs.

---

## 3. Current version & build status

| Item | Status |
|------|--------|
| **Version** | **1.4.0** (in `scripts/build-app.sh`) |
| **Platform** | macOS 13+ |
| **Dev build** | Ad-hoc signed locally (`build-app.sh` → `codesign` ad-hoc) |
| **Notarized release** | **Not done yet** — blocked on Developer ID + notary profile |
| **Uncommitted work** | Large local working tree vs `origin/main` (see §6) — reviewer should not assume GitHub main == latest binary |

### Build / ship commands

```bash
cd /Users/dylandemnard/Personal/Projects/HermesPong

# Universal release build
bash scripts/build-app.sh

# Install to /Applications (dev)
bash scripts/install.sh

# Sign + notarize + staple + zip (needs Developer ID + notary profile)
bash scripts/sign-notarize.sh
```

Notary keychain profile name expected by script: **`hermes-pong`**.

---

## 4. Goal: Apple notarization (checklist for reviewer / release owner)

### Success criteria

1. App signed with **Developer ID Application** (not “Apple Development”)  
2. Submitted to Apple notary → **Accepted**  
3. Ticket **stapled** onto the app  
4. Zip `dist/CyberPong-macOS.zip` opens on a clean Mac without “unidentified developer” dead-ends  
5. Hygiene pass: no `.env`, no absolute `/Users/...` paths baked into the bundle  

### Prerequisites

- [ ] Paid **Apple Developer Program** team active  
- [ ] **Developer ID Application** certificate in Keychain on the signing Mac  
- [ ] Notary credentials stored as keychain profile `hermes-pong`  
  (`xcrun notarytool store-credentials hermes-pong …` — app-specific password preferred)  
- [ ] `xcrun notarytool` available (Xcode CLT)  
- [ ] Clean release build: `bash scripts/build-app.sh` (no `--dev`)  

### Verify signing identity

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expect something like:

```text
Developer ID Application: Name (TEAMID)
```

### Run notarize pipeline

```bash
# optional if multiple identities:
# export IDENTITY="Developer ID Application: Name (TEAMID)"

bash scripts/sign-notarize.sh
```

Outputs of interest:

- Stapled `dist/CyberPong.app`  
- `dist/CyberPong-macOS.zip` for distribution  
- Script prints setup checklist if credentials/identity missing (does not store secrets)

### Post-notarize smoke (on a second Mac or VM if possible)

- [ ] Download zip → unzip → open app (no right-click workaround required after trust)  
- [ ] First launch: panel + 3D map; Guide onboarding if no `app_ai` settings  
- [ ] Create team → Terminal windows open with real CLIs (not `printf …; true`)  
- [ ] `pong gate` / `pong status` from a bound seat  
- [ ] Accessibility + Automation prompts accepted once  

### Entitlements today

`resources/entitlements.plist` currently only:

```xml
com.apple.security.automation.apple-events = true
```

**Concern for future features:** optional App AI cloud / HTTPS telemetry may need **outgoing network** client entitlement (or non-sandboxed status clarified). Today the app is **not** App Sandbox–hardened in the same way as Mac App Store; Developer ID + notarize is the distribution path.

Full ops notes: `~/Desktop/CyberPong-notarize-checklist.md`.

---

## 5. What shipped recently (context for review)

These are major threads from the 2026-07 development push (local tree; confirm against git before release):

| Area | Summary |
|------|---------|
| **Team sanitizer + pair write lock** | Removing seats prunes `flow_graph`, canvas/3D positions; sole remove path for residue agents |
| **Architecture-aware handoffs** | Every job injects seat identity + architecture road; hop-skips refused by control plane |
| **2D map** | Working glow + edges from live `flow_graph`; multi-session position invariants |
| **App AI onboarding** | Pill Guide: pick Grok/Claude/OpenAI → login Terminal → headless → first team |
| **Map Guide chat** | Sparkle FAB on 3D map; hover/nudge; headless chat after login |
| **Role permanence** | `mission_role` on seats; bind card lists who-is-who + edges |
| **Architecture UX** | Friendlier labels (Gives work / Sends result / Helper); bendable links that persist |
| **YOU chat** | Per-team history, clear, expand |
| **Setup Access card** | MCP / permissions visibility across seats |
| **Link terminals fix** | Bare shells no longer get `printf …; true`; create tmux pane + attach + start CLI |

Design umbrella: [DESIGN-APP-AI-2D-OPENCLAW-TELEMETRY.md](DESIGN-APP-AI-2D-OPENCLAW-TELEMETRY.md).

---

## 6. Next TODO (priority order)

### P0 — Ship blockers (notarize + trust)

1. **Complete Developer ID + notary profile** and run `scripts/sign-notarize.sh` to Accepted + staple  
2. **Commit / PR / tag** a release branch so the notarized binary matches a known git SHA  
3. **Gatekeeper smoke** on a machine that never ran CyberPong before  
4. **Fix AppleScript theme errors** seen in logs (`theme apply … Expected "given"… but found "if"`) — cosmetic but noisy; may break title/chrome on some macOS versions  

### P1 — Stability for first-hour users

5. **Onboarding polish** — Guide already improved; still verify: button layout, first-team naming, login window detection  
6. **Worker launch reliability** — New team + Link terminals paths; ensure every seat gets a real CLI, pane registration, and recoverable window titles  
7. **Preview constellation** — Empty-state 3D seats are not a real team; Open on preview must not try to front `preview` tmux session (log spam)  
8. **Architecture editor** — Link bend/position persistence needs soak testing after multi-edit sessions  

### P2 — Product / App AI

9. **Headless Guide quality** — Provider-specific prompts; fail closed with clear “CLI not found / not logged in”  
10. **Agent guide tutorial** — Triggered on + agent; walkthrough still light on animation  
11. **OpenClaw as first-class type** — Product decision: seat = `openclaw tui` only; no in-app dashboard  
12. **Telemetry (optional, opt-in)** — Design is local-export first; HTTPS needs endpoint + entitlements  

### P3 — Hygiene & tests

13. Expand Python tests around recaps / isolation; manual QA script for 2D/3D parity  
14. Update `docs/REMAINING_TODO.md` / `ROADMAP.md` to match this handoff  
15. Landing / marketing screenshots for notarized 1.4.x release notes  

---

## 7. Things of concern (reviewer attention)

### Security & privacy

| Risk | Severity | Notes |
|------|----------|--------|
| **Automation / Accessibility** | Medium | Required for Terminal paste; users must grant once; document clearly in first-run |
| **Job/task text on disk** | Medium | Jobs under `~/.pong/jobs/` may contain prompts/code; local-only by design |
| **App AI headless** | Medium | Shells out to user CLIs (`grok -p`, `claude -p`, …); no CyberPong-held API keys, but process can inherit env |
| **Telemetry** | High if enabled wrong | Must stay **opt-in**, no prompts/code by default; not in notarize v1 unless finished |
| **Signing secrets** | Critical | Never commit notary passwords; use keychain profile only |

### Reliability

| Risk | Severity | Notes |
|------|----------|--------|
| **AppleScript Terminal theme** | High (UX) | Log spam / failed theme apply; investigate broken `if` syntax in generated AppleScript |
| **Window ID recovery** | Medium | Multi-team Terminal matching is fragile; titles are the glue |
| **tmux + multi-window** | Medium | Attach/detach behavior is intentional; “Terminate processes?” dialogs must stay avoided |
| **Concurrent writes to pairs.json** | Medium | PairWriteLock added for some paths; not all writers migrated |
| **Empty `flow_graph`** | Mitigated | Defaults now enforce road; teams without graph still get implicit topology |

### Product / UX debt

| Risk | Severity | Notes |
|------|----------|--------|
| **Complexity of Architecture** | Medium | Simplified labels; still advanced for non-technical users |
| **Guide vs agent seats confusion** | Medium | App AI is co-pilot, not a map seat — copy must stay clear |
| **Uncommitted local features** | High for release | Notarized build must be from a clean, tagged tree |

### Legal / distribution

| Item | Notes |
|------|--------|
| **Not “Mac App Store” path** | Developer ID + notarize for outside-MAS distribution |
| **Third-party CLIs** | Claude/Grok/etc. are user-installed; CyberPong does not redistribute their binaries |
| **Team identity** | Bundle ID / cert Team ID must be consistent across releases for updates |

---

## 8. Suggested reviewer focus (90 minutes)

1. **Clone / open project** → skim README + ARCHITECTURE + this handoff  
2. **Build** `bash scripts/build-app.sh` → run app  
3. **Onboarding path:** Guide → provider → team → map  
4. **Kill/add seat** → residue gone? roles on next job?  
5. **Architecture:** move seats, bend links, reopen sheet — still stuck?  
6. **YOU chat:** multi-team if available — history scoped? clear works?  
7. **Setup → Access · MCP** — does summary match Policy toggles?  
8. **Notarize readiness:** run `sign-notarize.sh` hygiene section even without credentials; list missing cert/profile  
9. **File review:** `resources/entitlements.plist`, `scripts/sign-notarize.sh`, recent Swift under `src/AppAI*.swift`, `TeamSanitizer.swift`, `python/pong/handoff_recap.py` / `role_identity.py` / `flow.py`  

---

## 9. Quick reference — state & CLI

```bash
# Health
pong check
pong gate
pong status -s pong-team

# Architecture for a seat
pong architecture recap --seat w1 -s pong-team
pong seat brief --seat w1 -s pong-team

# State
ls ~/.pong/pairs.json ~/.pong/jobs/ ~/.pong/human/ ~/.pong/settings.json
```

---

## 10. Contact / ownership

| Role | Person / note |
|------|----------------|
| Product / builder | Dylan Demnard |
| Repo | kulpio/hermes-pong |
| Notary profile name | `hermes-pong` (keychain) |
| Temporary cert path | See Desktop notarize checklist (Developer account setup) |

---

## 11. One-line ask for the reviewer

> Please validate that CyberPong is **safe and coherent enough to notarize**, list **release blockers** vs **post-1.4 polish**, and confirm the **sign-notarize pipeline** is ready once Developer ID credentials are available.

---

*Generated for sharing with external or internal reviewers. Paths that start with `/Users/dylandemnard` are machine-local; use the GitHub repo as the portable source of truth after commit.*

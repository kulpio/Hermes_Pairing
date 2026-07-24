# CyberPong — Code, security & notarization review (2026-07-22)

Companion to [`REVIEWER-HANDOFF-NOTARIZE.md`](REVIEWER-HANDOFF-NOTARIZE.md). Reviews purpose/goals, code, security, permissions, and notarization readiness. Every finding below was verified against current source (local working tree, not `origin/main`).

---

## 1. Verdict

**The notarization pipeline is sound.** Nothing in the code will fail Apple notarization or the hardened runtime. `scripts/sign-notarize.sh` does the correct sequence (Developer ID sign with `--options runtime --timestamp --entitlements`, notarize, staple, re-zip, `spctl` assess), degrades gracefully without credentials, and never touches secrets. Entitlements are minimal and correct (`com.apple.security.automation.apple-events` only, matching `NSAppleScript` under hardened runtime). Single universal Mach-O, no `--deep`, no dylib loading, no JIT, no DYLD vars, no in-bundle writes, no privilege escalation. The bundle is content-clean: no `/Users/` literals, no `.env`/venv/`.DS_Store`, no secrets. Blocked only on Apple Developer credentials, exactly as documented.

**But "notarizable" ≠ "works from the zip."** There is a real self-containment regression (§3.1) that means a fresh download is functionally broken even after it opens without a Gatekeeper prompt. That, plus one auto-approve RCE default (§3.2), are the true ship blockers — neither is a *notarization* blocker.

---

## 2. Purpose & goals — assessment

**What it is:** a macOS menu-bar + panel app ("CyberPong") that runs multi-CLI agent teams locally. A conductor (Grok/Hermes/Claude/custom) plans and assigns; workers (Claude/Grok/Codex/…) run in real Terminal/tmux sessions; jobs/claims/ledger live as flat files under `~/.pong/`. 3D constellation map is the home surface. No vendor API keys held by the app — users sign into their own CLIs.

**The goals are coherent and the architecture matches them.** "Stay local," "human can enter any terminal," "jobs on disk as source of truth," "verify don't trust (ledger)" are all genuinely reflected in the code, not just the README. The `pong snapshot` UI contract is a clean seam. The design is unusually disciplined on shell safety (no `shell=True` / `os.system` / `os.popen` anywhere in Python; every subprocess uses an argv list).

**Where goals and reality diverge:**
- **"Stay local / nothing is sent anywhere"** — accurate. Verified zero `URLSession`/sockets/telemetry/update-check anywhere in `src/`. The only outbound touchpoints are `NSWorkspace.open` of the Stripe tip URL and `x-apple.systempreferences:` deep links. This claim is true today; it stops being true the moment the "App AI cloud / HTTPS telemetry" ideas in the roadmap land, and that will change the entitlement/permission story.
- **"Self-contained downloadable app"** (a hard requirement per project notes) — **regressed** in the CyberPong rework. See §3.1.
- **Product surface is large for a v1.** 3D map + 2D canvas + architecture editor + cron timeline + App-AI onboarding + team wizard is a lot to keep reliable. The handoff's own P1/P2 list is honest about this. The single-Mach-O binary is ~15k+ LoC of Swift across a few 200KB+ files (`MenuBarApp.swift` 232KB, `Agent3DMapView.swift` 239KB) — maintainable now, but the concentration is a risk.

---

## 3. Blockers (must fix before a public release)

### 3.1 — The app is not self-contained; a fresh install is functionally dead [BLOCKER]

The `.app` bundle **does not contain the `pong` Python package** (`build-app.sh` copies only 5 flat shim scripts into `Resources/`, never `python/`). Every real feature shells out to `python3 -m pong.cli …` or the bundled shims, all of which resolve the package via `PYTHONPATH=$HOME/.pong/lib` (`MenuBarApp.swift:391`, `:2433`; `Isolation.pythonPath` `MenuBarApp.swift:127-145`). **Nothing seeds `~/.pong/lib` from the bundle** — only `scripts/setup.sh` (run from a source checkout) populates it. On this machine it works because setup.sh was run; on a clean Mac that only unzipped the notarized app, `~/.pong/lib` is empty and:
- the bundled shims (`pong-delegate.py`, `pong-ledger.py`, `hermes_pong.py`) do `sys.path.insert(0, Path(__file__).resolve().parents[1] / "python")` → in the bundle that's `Contents/python`, which does not exist → `ImportError`;
- the Swift `python3 -m pong.cli` calls fail and are swallowed by `|| true`, so the app *looks* fine and silently does nothing.

This is the same "must not depend on files from the builder's machine" requirement that v1.3 satisfied and the v1.4 rework broke. **Fix:** either (a) bundle `python/pong` into `Resources/` and point `pythonPath`/the shims at `Bundle.main.resourcePath + "/python"`, or (b) have the app seed `~/.pong/lib` from the bundle on first run. (a) is cleaner and keeps the bundle the source of truth.

### 3.2 — Headless `grok` worker auto-approves everything (`--yolo`) [BLOCKER, design]

`python/pong/transports/headless.py:13` dispatches grok workers as `["grok", "-p", "{prompt}", "--yolo"]`. The prompt embeds `job.task` + `acceptance` verbatim, and jobs are agent-creatable (`pong job create`). Any conductor/agent that can queue a headless job for a grok seat gets **host command execution with zero human approval**. `claude -p` / `codex exec` are non-interactive too but not auto-approving, so lower severity. **Fix:** drop `--yolo`, or gate headless dispatch to an auto-approving worker behind an explicit human confirmation. This is the single highest-risk default in the codebase.

### 3.3 — Commit and tag before signing [BLOCKER, process]

36 uncommitted files (21 modified + 15 untracked, including all `src/AppAI*.swift`, `TeamSanitizer.swift`, `python/pong/flow.py`) on `main`. The Jul-22 dist build includes uncommitted source, so a release tag cut now would not reproduce the shipped binary. Commit → tag → build → sign, in that order, so the notarized binary maps to a known SHA.

---

## 4. Should-fix before public distribution

### Security / privacy
- **Path traversal via unvalidated session / job / brief names** (`paths.py:62-73`, `routing.py:302-333`, `jobs.py:38-39`). `pong job list --session ../../../../etc` globs outside the state dir; `pong brief send --to ../../../../tmp/evil` writes an attacker-named `.md` anywhere the user can write. Single fix closes all three: validate every externally-supplied `session`/`to_session`/`job_id` against a strict allowlist (`[A-Za-z0-9._-]+`, no `/`, no `..`) at the boundary before any path join.
- **World-readable prompt/relay content** — `events.jsonl`, `last-sent.txt`/`last-reply.txt`/`last-claude.txt`, `binds/*.md`, `briefs/*.md` are `0644` under a `0755 ~/.pong`. Full prompts, `project_root`, task text are readable by any local user. `chmod 700 ~/.pong` and write these `0600`. (Job files and the session token are already `0600` — good.)
- **Full parent env inherited by spawned CLIs** (`headless.py:36-42`, no `env=`). grok/claude/codex/custom binaries get every var the app holds, including `PONG_TOKEN` (the session write-auth secret). Scrub to a minimal env for headless dispatch.
- **Fragile escaping into `python3 -c` one-liners** (`MenuBarApp.swift:147-174`, `FlowGraph.swift:139`, `AppAIMutator.swift:133`) — quote-strip-only; `FlowGraph`/`AppAIMutator` embed Python inside bash double-quotes so `$`/backticks would shell-expand. Local-attacker-only today (pair names are machine-generated), but pass values as `Process` argv instead of interpolating.

### Reliability
- **Terminal.plist direct rewrite** (`MenuBarApp.swift:1117-1158`) — the app removes and replaces `~/Library/Preferences/com.apple.Terminal.plist` to hide process chrome. The log confirms this is failing live (`NSCocoaErrorDomain Code=4 "com.apple.Terminal.plist" couldn't be removed`, plus failed `.tmp-pong` moves). Fighting cfprefsd's cache is fragile and a failed move between `removeItem` and `moveItem` would delete the user's Terminal prefs. Use `CFPreferences`/`defaults write` (settings-set) instead, or drop it.
- **No cross-process state locking.** Python `write_json` is atomic per-write, but `set_status`/`record_claim`/`save_pairs_db` do unlocked read-modify-write, and Swift writes `pairs.json`/`settings.json` **non-atomically** (`data.write(to:)`, no `.atomic`) guarded only by an in-process lock the `pong` CLI doesn't share. Concurrent app+CLI writes lose updates; a reader can catch a half-written `pairs.json` and transiently see an empty DB. Make Swift writes atomic first (cheapest, highest value), then add a lockfile for read-modify-write paths.
- **Relay points at the legacy state root** — `claude-window-relay.py:23` uses `~/.hermes-pong` while everything else uses `~/.pong`. On a fresh install the window-link relay watches a stale/empty `active-pair.json` and silently never relays; its PID file also diverges from where Swift stops it. Repoint to `~/.pong`.
- **Gate emits an undocumented third token** — `state.py:412` returns `BRIDGE_UNHEALTHY session=…` (exit 2), but the frozen contract is `BRIDGE_OFF`/`BRIDGE_ON`. Skills that `startswith("BRIDGE_ON")` read UNHEALTHY as "not on." Exit code is fail-closed, but document the token or fold it into `BRIDGE_OFF`.
- **No log rotation** — `~/Library/Logs/Pong.log` is already 16 MB. Cap/rotate it.

### Hygiene
- **Dev directory-layout strings baked into the release Mach-O** — `home + "/Personal/Projects/HermesPong/..."` fallbacks (`MenuBarApp.swift:133`, `TeamInstallWizard.swift:154/281/293`) embed the developer's tree in the binary and **evade both hygiene greps** (`build-app.sh` greps `dylandemnard`; `sign-notarize.sh` greps `/Users/`) because the string is `$HOME`-relative. Gate behind `#if DEBUG` and extend the greps to `strings … | grep -E "/Users/|Personal/Projects"`.
- Delete stale `dist/CyberPong-macOS.zip` (Jul-20, older than the Jul-22 app next to it) so no one uploads the wrong artifact; the pipeline regenerates it post-staple.

---

## 5. Permissions story (what the user is asked to allow, and gaps)

The app requests **two** macOS TCC grants; only one is declared and preflighted correctly.

| Grant | Why | Declared? | Preflight? |
|---|---|---|---|
| **Automation → Terminal** | AppleScript drives Terminal (open windows, set titles/colors, `do script`). Both `NSAppleScript` in-process and child `osascript` are attributed to the app, so one grant covers both. | ✅ `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` entitlement — correct for hardened runtime. | ✗ No `AEDeterminePermissionToAutomateTarget`; first AppleScript call pops the prompt mid-pairing. Onboarding explains it socially. |
| **Accessibility** (+ Automation → System Events) | The bundled `claude-window-relay.py` posts `CGEvent` keystrokes (Cmd+V, Return) and falls back to `System Events` keystroke — window-link paste mode. | ✗ No usage string maps to it (there's no Info.plist key for Accessibility, but nothing preflights it either). | ✗ **No `AXIsProcessTrusted`/`…WithOptions` anywhere.** Without the grant `CGEventPost` silently no-ops and the System Events path errors — window-relay just doesn't deliver, no user signal. |

**Recommendations:**
1. Preflight Accessibility with `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` before enabling window-relay mode, and gate the feature on the result so it fails loud, not silent. The onboarding panel (`MenuBarApp.swift:3094`) already links to Settings — wire the programmatic check to it.
2. Add an Automation preflight at onboarding so the Terminal prompt fires at a predictable moment, not mid-pairing.
3. The `NSAppleEventsUsageDescription` string ("controls Terminal windows…") is also shown for the System Events prompt — reword slightly so it's accurate for both targets.
4. First `python3` spawn on a clean Mac can trigger the Xcode Command Line Tools install dialog — document this as a prerequisite or detect-and-explain it.
5. `python3 -c`/tmux `Pong.sh` runs prepend user-writable dirs (`/opt/homebrew/bin:/usr/local/bin:$HOME/bin`) ahead of system PATH — standard for dev tooling, a binary-planting vector on shared machines. Note-level.

**No microphone, camera, screen capture, location, contacts, or calendar** APIs anywhere — verified. The permission ask is genuinely just "control Terminal + paste keystrokes," which is honest to what the app does.

---

## 6. The AppleScript theme error (root cause + fix)

The `theme apply … Expected "given"… but found "if"` spam in the log (confirmed still live on every title/theme apply) is `closeFriendlyAS` at `MenuBarApp.swift:1165` and `:1168`:

```
set close if shell exited cleanly of theme to true   ← line 1165: no such sdef property
set prompt before closing of theme to never          ← line 1168: no such sdef property
```

Terminal's scripting dictionary has no `close if shell exited cleanly` or `prompt before closing` properties — those are GUI preference *names*, not AppleScript terms. AppleScript parses `close` as the standard command and chokes on `if`. Because these are **compile-time** errors, the wrapping `try … end try` is useless — `NSAppleScript` fails to compile the whole script, so **every** `TerminalTheme.apply()` returns `ERR:` and titles/colors never apply through this path. The same two lines repeat inline at `:1442-1443`.

**Fix:** delete lines 1165-1169 and 1442-1443 (keep the valid `clean commands` line). The close-without-prompt behavior is already handled out-of-band by `ensureProfileHidesProcessChrome` writing `shellExitAction = 2` into the profile. Trivial, feature-restoring, not a notarization blocker. (This is the one I'd apply first — it's low-risk and stops the log spam masking real errors.)

---

## 7. Prioritized next steps

**P0 — before any public/notarized release**
1. Fix self-containment (§3.1) — bundle `python/pong` or seed `~/.pong/lib` on first run. *Without this the notarized zip is dead on arrival.*
2. Drop `grok --yolo` auto-approve or gate it (§3.2).
3. Delete the theme AppleScript bug (§6) — restores titles/colors, clears log spam.
4. Commit + tag, then build + sign from the tag (§3.3).
5. Complete Developer ID + notary profile → run `sign-notarize.sh` → Accepted + staple → Gatekeeper smoke on a Mac that never ran CyberPong.

**P1 — before wide distribution**
6. Validate session/job/brief names against an allowlist (closes 3 traversals at once).
7. `chmod 700 ~/.pong` + `0600` on prompt/relay files; scrub env for headless dispatch.
8. Make Swift `pairs.json`/`settings.json` writes atomic; repoint relay to `~/.pong`.
9. Replace the Terminal.plist rewrite with `CFPreferences`/`defaults` (it's failing live).
10. Add the Accessibility preflight (§5).

**P2 — hygiene / polish**
11. Gate dev-path fallbacks behind `#if DEBUG`; extend hygiene greps to catch `Personal/Projects`.
12. Log rotation; document the token / `BRIDGE_UNHEALTHY` contract; delete stale dist zip.

**Note on signing under a family member's Developer account** (per the Desktop checklist): mechanically fine, but Gatekeeper will show *their* legal name as the developer, the developer-agreement obligations are theirs, and the Team ID must stay stable across releases — moving to your own account later means a new identity (users see a "different developer" on update). Decide consciously; fine as a bootstrap.

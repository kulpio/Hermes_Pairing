# Review checklist: Task 1 (Team Options + brief + project_root + bridge inject)

**Role:** hermes-pair-1 reviewer (prep only; do not implement unless Claude is stuck).  
**Task brief:** `~/.hermes-pong/tasks/team-options-brief.md`  
**Repo:** `/Users/dylandemnard/src/Hermes-Pong`

## Scope to review (when Claude lands the PR)

| Area | Files |
|------|--------|
| Hermes row Options + Team Options sheet | `src/MenuBarApp.swift` (~2350 Hermes buttons, ~2523 save team, new sheet near Permissions) |
| Live pair persistence | `PairState.savePairState` / pairs.json writes (~187–255) |
| Saved teams | `SavedTeams` (~771–942), `teams.json` |
| Bridge inject | `scripts/pong-delegate.py`, `scripts/claude-delegate.py` (`build_prompt` / session bind) |
| Bind card | `scripts/hermes_pong.py` `write-bind` |
| Optional gate line | `scripts/pong-gate.py` |
| Docs | `docs/PRODUCT-MULTI-WORKER.md`, skill only if share/ touched |

---

## Cross-pair bleed risks still possible after Task 1

Task 1 hardens **paste context** and **UI state**. These paths can still cross-contaminate even when inject is correct:

1. **Shared global files (not session-keyed)**  
   - `~/.hermes-pong/last-claude.txt`, `last-sent.txt` — one pair’s reply overwrites another. Orchestra reading “last reply” without session filter can attribute the wrong project’s output.  
   - `active-pair.json` is a single “active” slot. Any tool that falls through to active when `HERMES_PONG_SESSION` / tmux bind is wrong still picks the wrong team.

2. **Bind order / wrong environment**  
   - Bridge order: `-s` > `HERMES_PONG_SESSION` > tmux pair base > `active-pair.json`.  
   - Hermes pane missing `HERMES_PONG_SESSION` (old pairs, manual attach, broken startFresh) + wrong active → injects **other** pair’s `team_brief` / `project_root` if those keys exist on the wrong session entry.  
   - Explicit `-s hermes-pair` while sitting in `hermes-pair-1` tmux is intentional override; still a human footgun when labels match across teams.

3. **Soft isolation only in the prompt**  
   - TEAM CONTEXT is advisory text. Workers can ignore it (no sandbox).  
   - `project_root` inject without `repo_only` (task says do not force-flip perms) means nothing hard-blocks edits outside the root.  
   - Same worker labels (`Claude`, `w1`) across Natandi vs Hermes-Pong pairs remain confusing in chat; only bound session + brief reduce bleed.

4. **Brief mirror lag / wrong path**  
   - JSON is source of truth; `~/.hermes-pong/briefs/<session>.md` is a mirror. Skills/humans reading a stale brief file after Options Save without rewrite, or reading pair A’s brief while orchestrating pair B, reintroduces bleed.  
   - Spawn must write brief under the **new** live session name, not the saved team id or previous session.

5. **Out-of-band handoffs**  
   - Pasting tasks by hand into a worker (not via `pong-delegate.py`) skips inject entirely.  
   - Ledger / verdict paths that are pair-scoped only via active session can still record under the wrong pair if active is flipped mid-run.

6. **UI row identity**  
   - Options sheet must key off **session** (`identifier` = pair name), never display name alone. Two pairs with similar display names must open different Options state.

---

## Must-verify cases

### Two live pairs (same worker labels)

- [ ] Pairs A and B both have a worker labeled e.g. `Claude` / `w1`.  
- [ ] From Hermes A: `pong-delegate.py --dry-run` (or real send) shows `bound_session=A`, roster only A, TEAM CONTEXT with A’s `project_root` + brief.  
- [ ] From Hermes B: same for B; never A’s root/brief.  
- [ ] Gate stderr `TEAM:` (and optional `PROJECT:`) matches bound session only.  
- [ ] Options on A’s Hermes row does not show/edit B’s fields.

### Wrong project named in the task text

- [ ] Pair bound to `~/src/Hermes-Pong` with brief “never touch Natandi”.  
- [ ] Task text says “edit Natandi / SynergyApp / other product”.  
- [ ] Inject includes isolation rule: STOP if task names a repo not under `project_root`.  
- [ ] Manual smoke: worker (or dry-run prompt dump) contains that rule **before** the user task body, and `Bound session` is correct.

### Empty brief / unset project root

- [ ] Empty `team_brief` + empty `project_root`: inject still safe (e.g. brief `(none)`, root `(unset — ask Hermes…)`), no crash, no reading another pair’s fields.  
- [ ] Brief set, root empty (and vice versa): only present fields populated; still session-scoped.  
- [ ] Options Done with both cleared: pairs.json keys empty or removed consistently; `briefs/<session>.md` emptied or updated (no stale previous text left as truth).  
- [ ] Permissions inject still works independently when TEAM CONTEXT is minimal.

### Saved team restore

- [ ] Save Team from Options persists `project_root` + `team_brief` (+ display_name) into `teams.json`.  
- [ ] Spawn saved team → new `hermes-pair-N` gets those fields on live `pairs.json` entry.  
- [ ] `briefs/<new-session>.md` written for the **new** session.  
- [ ] Duplicate team copies brief + root.  
- [ ] Overwrite save (same team name) updates brief/root, does not drop workers/perms/colors.  
- [ ] Old `teams.json` without new keys: load/spawn still works (defaults empty).

### UI / acceptance smoke

- [ ] Hermes row: **Options** only (no Hermes-row **Save Team** title). Save Team lives inside Options.  
- [ ] Workers still have **Perms**; Hermes row has no Perms.  
- [ ] Legend/help: no “Save Team on the Hermes row”; Options wording updated (incl. Show Teams empty state ~2034).  
- [ ] `bash scripts/build-app.sh` exits 0.  
- [ ] `rg` acceptance from task brief all green.

---

## API / state merge pitfalls (`savePairState` / `teams.json`)

### `PairState.savePairState` (critical)

**Current behavior (pre–Task 1):** rebuilds a **new** entry dict with window/worker/autonomy/permissions and only copies `view_hermes` / `view_claude` / `view_worker` from `prev`. It does **not** merge arbitrary prev keys.

**Review must confirm Claude either:**

1. Extends the preserve-list to at least: `display_name`, `colors`, `project_root`, `team_brief` (and any other pair-level fields already in use), **or**  
2. Stops using bare rebuild and does true merge: `entry = prev; overlay known keys`, **or**  
3. Persists Options via a dedicated writer that merges like `Workers.setPairDisplayName` (read entry → set keys → write), and never calls `savePairState` in a way that drops those keys.

**Failure mode:** User sets Options → later New pair refresh / re-link / `savePairState` from pairing path → `project_root` / `team_brief` / even `display_name` wiped → bridge inject silent empty → cross-project freestyle returns.

Also check:

- [ ] Options Done updates **both** `pairs.json[session]` and `active-pair.json` only when `active.session == this session` (mirror `Workers.syncActive`).  
- [ ] Writing active must not broadcast this pair’s brief onto another session’s active file incorrectly.  
- [ ] Concurrent Options Save vs worker Perms save: last-write-wins on whole entry if either path replaces the dict instead of merge.

### `SavedTeams` / `teams.json`

**Current gaps to re-check after implementation:**

| Path | Risk if incomplete |
|------|---------------------|
| `Team` struct | No fields for `project_root` / `team_brief` → cannot round-trip |
| `loadAll` | Drops unknown keys if only known fields mapped |
| `writeAll` | Omits new keys → silent data loss on any team edit |
| `saveFromLivePair` | Must copy from live `pairs.json` entry |
| `spawn` | Must apply onto new live entry + brief file for new session |
| `duplicate` | Must copy new fields |

**Name collision:** save with same display name reuses `id` and replaces team — confirm brief/root update, workers not clobbered incorrectly.

**Do not** store live `window_id` / session name inside the team snapshot (spawn creates fresh); only portable fields.

### Bridge load path

- [ ] Inject reads `load_session_state(bound_session)` / `pairs.json[session]`, **not** raw active without session match.  
- [ ] `pong-delegate.py` and `claude-delegate.py` stay in sync (shared helper preferred).  
- [ ] Inject **before** user task text; order relative to PAIR ACCESS CONSTRAINTS is sensible (TEAM CONTEXT first is clearer for isolation).  
- [ ] `repo_only` + `project_root`: both can appear; inject must not force-enable `repo_only`.  
- [ ] Huge `team_brief` pastes still submit (tmux paste limits) — document or truncate if needed.

### Brief file vs JSON

- [ ] Create `~/.hermes-pong/briefs/` on first write.  
- [ ] Session rename / kill: orphan brief files OK for v1; do not point new pair at old session’s file.  
- [ ] `write-bind` includes project_root + one-line brief when set.

---

## What not to do as reviewer

- Do **not** implement Options / inject / SavedTeams changes unless Claude is blocked and Hermes escalates.  
- Do **not** ship GitHub release / notarize.  
- Do **not** redesign worker Perms or roles.

## Quick re-review commands (post-PR)

```bash
rg -n "Options|TeamOptions|team_brief|project_root" src/MenuBarApp.swift
rg -n "Save Team on the Hermes" src/MenuBarApp.swift   # expect 0
rg -n "team_brief|project_root|TEAM CONTEXT" scripts/pong-delegate.py scripts/claude-delegate.py
rg -n "project_root|team_brief" scripts/hermes_pong.py
bash scripts/build-app.sh
# optional dry-run with two pairs:
# HERMES_PONG_SESSION=hermes-pair python3 scripts/pong-delegate.py --dry-run 'ping'
# HERMES_PONG_SESSION=hermes-pair-1 python3 scripts/pong-delegate.py --dry-run 'ping'
```

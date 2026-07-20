# Pong agent handout — north star & early naming

**Audience:** any AI working in Agent-Pong (conductor or worker)  
**Purpose:** keep building Pong *as Pong*, while naming and shaping code so it can grow into a **personal access-control plane** (live agents + standing grants + place).  
**Not a rewrite brief.** Do not merge Umbra, Gmail, or beacon into this repo unless a human job says so.

---

## 1. One sentence north star

> **Pong is the live runtime console** for agentic actors the user hosts: see them, bound what they may do, hand off work, intervene, kill.  
> Over time it attaches to a **standing trust registry** (apps, AIs, OAuth, geo) — product name for that map may be Umbra or a shared brand.  
> **Today we only own the live layer cleanly.** Naming must not paint us into “coding-pair toy only.”

### Three layers (learn these)

| Layer | Question | Pong today | Later (not this sprint) |
|-------|----------|------------|-------------------------|
| **Live** | What may this actor do *this session / job*? | Teams, jobs, perms sheet, kill | Policy packs bound to principal id |
| **Standing** | What access still exists *over time*? | Out of scope (Umbra / registry) | Link principal → grants |
| **Spatial** | Where may this actor act? | Out of scope | Geo / zone facets on policy |

When you write docs or UI, prefer language that works for **all three later**, without implementing standing/spatial yet.

---

## 2. Product language (use in UI copy, README, comments)

### Prefer

| Use | Meaning |
|-----|---------|
| **Team** | One bound orchestra (session): conductor + workers |
| **Seat** | A place in the team (conductor seat or worker seat) |
| **Actor** / **agent** | Something that can act (CLI agent, later any principal) |
| **Principal** | Stable identity of an actor (internal/docs; not required in UI yet) |
| **Policy** / **access policy** | What a seat/principal is allowed or banned from doing |
| **Grant** | A standing permission (OAuth, key, scope) — *future*; don’t invent UI |
| **Job** | One handoff unit of work to a worker |
| **Claim** | Worker asserts job done |
| **Verdict** | Conductor/human accept/reject of a claim |
| **Mission** | Human’s higher-level goal / mission view |
| **Focus** | Inspector for one seat + its flow |
| **Kill** | Stop / close that seat’s process or mark takeover |

### Avoid (or demote)

| Avoid as product identity | Why |
|---------------------------|-----|
| “Hermes Pong” / Hermes-as-the-product | Conductor-agnostic; Hermes is *a* conductor type |
| “Claude pair” / “the Claude pane” as the only worker | Multi-worker; Claude is default *example* |
| “Permissions” alone for everything | Too vague; see glossary below |
| “Pair” in **new** user-facing strings | Prefer **team**; keep `pair` as legacy schema alias |
| “Subscription / privacy scanner / Umbra” in Pong UI | Wrong surface; sister product |

### “Permissions” — disambiguate

When you touch the Perms UI or docs, be precise:

| Term | Use for |
|------|---------|
| **Session policy** / **seat policy** | Current Pong checkboxes: ban MCP, ban network, repo-only, ask-each, etc. |
| **Standing grant** | Account/app/OAuth access that persists (registry/Umbra) — **do not implement** |
| **macOS permission** | TCC Automation / Accessibility prompts for Terminal control |
| **Policy pack** / **preset** | Saved named set of seat-policy flags (already “permission presets”) |

**UI label guidance (when editing strings):**

- Window title: prefer **“Seat policy”** or **“Access policy”** over bare “Pair permissions” when you touch that sheet.
- Button on canvas: **“Policy”** is better than **“Perms”** if you change labels; if you keep **Perms** short, tooltip should say **“Session access policy”**.
- Presets file can stay `permission-presets.json` for compat; new code comments should say **policy packs**.

Do **not** rename on-disk keys in a big bang without migration + tests.

---

## 3. Canonical vocabulary (code + schema direction)

### Roles (seats)

| Role | id pattern | Notes |
|------|------------|-------|
| Conductor | `c1` (today) | Plans, creates jobs, verdicts |
| Worker | `w1`, `w2`, … | Executes jobs |
| (Future) Subagent | parent worker + child id | Hierarchy later; don’t fake as peer-only forever |

### Session / team ids

- Preferred: `pong-team`, `pong-team-N`
- Legacy still load: `hermes-pair*`, `hermes-claude*`
- Env: `PONG_SESSION` primary; `HERMES_PONG_SESSION` legacy

### State root

- Primary: `~/.pong/`
- Legacy: `~/.hermes-pong/` (read/migrate, don’t write new features only there)

### Core objects (mental model — extend toward this)

```text
Team (session)
  └── seats[]: conductor | worker
        id, type, label, cmd, window binding
        policy          ← today’s “permissions” object
        principal_id?   ← optional later; don’t require now

Job
  session, worker (seat id), task, status, claim, round

Principal (future, docs only for now)
  id, kind: local_worker | ai_service | app | device | human
  standing_grants[]
  runtime_seats[]     ← links to Pong seats
  geo_policy?         ← later

PolicyPack
  id, name, flags…    ← today’s permission presets
```

### Policy flag keys (keep stable)

Existing keys stay authoritative until a versioned migration:

- `ban_mcp`
- `ban_root`
- `repo_only`
- `ban_network`
- `ban_system_paths`
- `ask_each`

When adding a flag: snake_case, boolean, document in this file + handoff text to workers. Prefer flags that could later apply to **any** local agent, not only Claude.

### Jobs remain source of truth

- Job file under `~/.pong/jobs/<session>/<job_id>.json` is authoritative.
- UI reads `pong snapshot`; never invent job state from tmux.
- Paste is optional sugar (`job+paste` / `--no-paste`).

---

## 4. What to change early (allowed / encouraged)

Do these **opportunistically** when you already touch a file:

1. **User-facing copy:** pair → team; Hermes-as-product → conductor; Claude-as-product → worker; “permissions” → “policy” / “session policy” where clear.
2. **Comments & docs:** introduce **seat**, **session policy**, **policy pack**, **principal (future)**.
3. **New APIs / JSON fields:** prefer `policy` as the *concept*; if you add a parallel key, keep writing legacy `permissions` until migration exists.
4. **Snapshot / UI contract:** if Mission or Focus shows policy, label it as session policy for that seat — not “account access.”
5. **Handoff prompts** (`format_permissions_block` etc.): title the block **Session access policy** so workers understand scope.
6. **Brand leftovers:** strip remaining Hermes-Pong product strings from app chrome when editing those surfaces; keep Hermes as a **conductor type**.
7. **Roadmap language:** v1 north star stays “teams + jobs + terminals”; add a short “toward access plane” note only if editing ROADMAP — no scope expansion.

### Small renames that are safe

| Safe | How |
|------|-----|
| UI strings | Free to improve |
| Log messages | Free |
| Doc titles | Free |
| New optional JSON field `policy` mirroring `permissions` | Only with normalize-on-read + tests |
| Preset UI “Full access” / “Ask each time” | Keep; they describe session policy well |

### Renames that need a real migration plan (don’t drive-by)

| Sensitive | Why |
|-----------|-----|
| `permissions` key in `pairs.json` | Live user state |
| `permission-presets.json` path | Existing files |
| Session id formats | Bound teams |
| Job schema fields | Control plane contract |
| `schema_version` bumps | Need tests + `pong check` |

---

## 5. What NOT to do (out of scope unless human says so)

- Do **not** add Gmail, OAuth footprint, Umbra scan, waitlist, or beacon code to Agent-Pong.
- Do **not** turn the canvas into a “permission map of all apps.”
- Do **not** implement geo-fencing UI that pretends hardware/registry exists.
- Do **not** require cloud accounts or send policy data off-machine.
- Do **not** block v1 ship on Umbra integration.
- Do **not** invent a second job system or dual-write ad-hoc JSON shapes.
- Do **not** scrape tmux for truth; extend snapshot + tests first (see `FOUNDATION.md`, `UI-CONTRACT.md`).

---

## 6. Design principles (when choosing an approach)

1. **Live first.** Pong must stay excellent at teams, jobs, terminals, human override.
2. **Local-only control plane.** `~/.pong` remains the spine.
3. **Identity before inventory.** Prefer stable seat ids and (later) principal ids over scraping vendor UIs.
4. **Policy is data.** Session policy is structured flags + presets, not only prose in the task.
5. **Kill switch is sacred.** Easy human takeover / kill must remain one click.
6. **Sister, not sibling rival.** Umbra (or future registry) owns standing grants; Pong owns runtime. Speak as if they will **link**, not **compete**.
7. **Conductor-agnostic.** Grok recommended; Hermes/Claude/custom supported — never hardcode one vendor as the product.

---

## 7. Handoff text conventions (jobs to workers)

When creating jobs or updating templates:

```text
TEAM CONTEXT
- session: <PONG_SESSION>
- project_root: <path>
- seat: w1 (worker type: claude)

SESSION ACCESS POLICY
- (list active bans / ask_each from pair policy)

TASK
- …

ACCEPTANCE
- …
```

Prefer **seat** / **session access policy** over “Claude permissions for this pair.”

Done markers stay as today (`##WORKER_DONE##` / type-specific). Claims + ledger unchanged.

---

## 8. Early checklist for a “north star alignment” job

If the human asks for early alignment work only, do **this set**, nothing more:

- [ ] Grep user-facing strings for “pair”, “Hermes Pong”, “Claude pair”; fix copy where cheap.
- [ ] Perms sheet / canvas button: labels + tooltips → session/seat **policy** language.
- [ ] Handoff / `format_permissions_block`: heading **Session access policy**.
- [ ] `docs/README` or `ARCHITECTURE.md`: one short “Live layer of a broader access plane” paragraph + link to **this file**.
- [ ] `ROADMAP.md`: keep v1 scope; optional one-liner that policy identity is the bridge later.
- [ ] **No** schema break without tests + migration notes.
- [ ] `python3 -m unittest` (or project test cmd) still green; `pong check` still OK if CLI touched.

---

## 9. Glossary (quick)

| Term | Definition |
|------|------------|
| **Access-control plane** | Long-term system: live bounds + standing grants + place |
| **Live layer** | What Pong is now |
| **Standing registry** | Map of durable access (Umbra-shaped); not in this repo yet |
| **Seat** | Conductor or worker slot on a team |
| **Session policy** | Runtime restrictions for a seat/team |
| **Policy pack** | Named preset of session policy flags |
| **Principal** | Stable actor identity (future link key) |
| **Grant** | Durable external access (OAuth etc.) |
| **Job** | Work unit to a worker seat |
| **Bridge** | Conductor skill mode: route via jobs, don’t implement product while BRIDGE_ON |

---

## 10. Related docs (read before large changes)

| Doc | Role |
|-----|------|
| `docs/ARCHITECTURE.md` | Control plane, seats, state root |
| `docs/UI-CONTRACT.md` | Snapshot is UI truth |
| `docs/UI-VISION.md` | Canvas / Mission / Setup |
| `docs/ROADMAP.md` | What’s in v1 |
| `docs/FOUNDATION.md` | Don’t build UI on unready data |
| `docs/PRODUCT-MULTI-WORKER.md` | Multi-worker product rules |
| **This file** | Naming + north star constraints |

---

## 11. Example: good vs bad change

**Good**

- Rename sheet title to “Seat policy — Auth team / w1”.
- Comment: `// Session policy flags (live layer); standing grants live in registry later.`
- Task handoff includes `SESSION ACCESS POLICY` block from current flags.

**Bad**

- Add “Scan Gmail for OAuth” button on canvas.
- Rename `permissions` → `policy` in `pairs.json` without migration.
- Rebrand entire app “Umbra” in the menu bar.
- Block canvas polish until geo-fencing ships.

---

## 12. Message to paste into a Pong job

```text
Read docs/NORTH-STAR-AGENT-HANDOUT.md first.

Goal: early north-star alignment only — naming, copy, comments, handoff labels.
Do NOT implement Umbra/Gmail/geo/registry. Do NOT break pairs.json schema.

Acceptance:
- User-facing “pair”/Hermes-product/Claude-product strings cleaned where you touch UI/docs
- Perms UI or tooltips use session/seat policy language if those files change
- Handoff policy block titled “Session access policy” if that code path changes
- Tests still pass; no drive-by schema renames
- Short note in ARCHITECTURE or README linking to NORTH-STAR-AGENT-HANDOUT.md if missing

End with done marker + CLAIM listing files changed.
```

---

*Handout version: 2026-07-19 · Living doc: update when policy flags or principal linking land.*

---
name: hermes-pong-bridge
description: Load when Hermes Pong is paired or when coding/building. While a pair is active, route ALL implementation through claude-delegate to Claude Code — never code yourself mid-session.
---

# Hermes Pong bridge

## When to load

- Hermes Pong, pair, Claude Code bridge, or tmux pair is mentioned
- You are about to implement, fix, or refactor product code
- `~/.hermes-pong/active-pair.json` may have a live `session`

## Hard rule

**While a pair is ACTIVE, you are the orchestrator only. Claude Code is the only coder.**

Forbidden while ACTIVE (including “quick” fixes after the first bridge send):

- Writing or patching product code yourself
- Dropping the bridge after 1–2 successful sends
- Raw `tmux send-keys` into a hidden pane

Allowed while ACTIVE:

- Read/search for context
- `claude-delegate.py` handoffs
- Run verification commands (tests, builds, diffs) — verifying is not coding
- Pair status / Front / Kill guidance
- Explaining Claude’s results to the user

## Team isolation (multi-pair)

Several pairs can be live at once (`hermes-pair`, `hermes-pair-1`, …). You are
bound to ONE session: env `HERMES_PONG_SESSION` (set at pair start), else your
tmux session name. Check any time:

```bash
python3 ~/bin/hermes_pong.py status   # bound session + team roster
python3 ~/bin/hermes_pong.py session  # bound session only
```

- Send ONLY to your own team: `python3 ~/bin/pong-delegate.py -s "$HERMES_PONG_SESSION" --worker w1 --no-wait '…'` (or omit `-s` and let the env/tmux binding resolve it).
- Worker names repeat across teams (w1, Claude, Grok…). Resolution happens inside your bound session only; a key that matches 0 or 2+ workers fails with exit 2 and prints your roster — it never guesses or reaches into another pair.
- Never target another `hermes-pair*` session or its panes, even if a worker there has the "right" name.
- `--dry-run` prints bound_session / roster / target / worker and exits without sending — use it when unsure where a send would land.
- Your bind card (roster + rules) is at `~/.hermes-pong/binds/<session>.md`.

A pair can also carry a **team brief** and **project root** (Options on the
Hermes row). When set, every delegate handoff starts with a `TEAM CONTEXT`
block naming the bound session, project root, and brief; the brief is mirrored
at `~/.hermes-pong/briefs/<session>.md`. Treat that block as hard scope: a task
naming another product or repo outside the project root is a STOP, not a detour.

## Gate (before every implementation step)

```bash
python3 ~/bin/pong-gate.py
```

| Result | Meaning |
|--------|---------|
| `BRIDGE_OFF` | You may implement yourself |
| `BRIDGE_ON session=…` | **Only** workers of THAT session via `claude-delegate.py -s <session>` |
| exit `2` / unhealthy | Fix Link/New pair before coding |

The gate reports your bound session and prints the `TEAM:` roster on stderr —
that roster is the complete set of terminals you may send to.

Re-run this gate every loop. Do not skip it after the first send.

## How to send work

```bash
python3 ~/bin/claude-delegate.py --no-wait "$(cat <<'EOF'
<task>

When completely done, print exactly ##CLAUDE_DONE## on its own line, then a short summary of files changed / what you did.
EOF
)"
```

Then:

1. Wait / poll `~/.hermes-pong/sessions/<session>/last-claude.txt` (or watch the Claude window). Top-level `last-claude.txt` mirrors the ACTIVE session only — with several pairs live, always read your session's file.
2. Read Claude’s result
3. Run the verdict loop (below)
4. If more code is needed → **another** `claude-delegate` call (never local coding)

For tasks with checkable criteria, write a task file from `~/.hermes-pong/templates/task.md` and send with:

```bash
python3 ~/bin/claude-delegate.py --no-wait --criteria path/to/task.md '<task>'
```

Criteria must be *checkable* — a command with an expected exit/output, not vibes.

## Verdict loop

**Never accept `##CLAUDE_DONE##` on the claim alone** — same rule as never inventing it from a timeout. While ACTIVE you may (and must) run verification commands: the acceptance checks from the task file, plus diffs/greps. Then:

1. All criteria pass → record `accept` (`python3 ~/bin/pong-ledger.py record --task-id <id> --round <N> --verdict accept --evidence '<what you checked>'`), announce `##HERMES_ACCEPT##`, move on.
2. Any criterion fails → record `reject` with evidence, send back through `claude-delegate.py` using this shape: `REJECTED round <N>: <criterion that failed>. Evidence: <exact output>. Fix only this. End with ##CLAUDE_DONE## + CLAIM block.` Rejections without specific evidence are **forbidden** — a bare “no” teaches nothing.
3. Three rejects on one task → record `escalate`, stop, surface the full verdict trail to the user.

**Check-gaming watchlist** — verify specifically that Claude did **not**: delete or skip failing tests, weaken assertions, or edit outside `## Out of scope`. If the check was gamed, that is a reject with the gaming named as evidence.

The loop always runs — there are no ask-modes. Work silently until **accept** (announce `##HERMES_ACCEPT##`, move on) or **escalate** (stop and surface the full verdict trail to the user). Legacy `ask_every` / `ask_on_done` values in old state files mean the same thing: run the loop.

The ledger lives in `~/.hermes-pong/ledger/` (`verdicts.jsonl` + `patterns.md`). `pong-gate.py` re-arms your memory of it (LEDGER / PATTERNS on stderr) every loop; run `python3 ~/bin/pong-ledger.py distill` after notable rejects. Recording is pairing-scoped: `record` refuses (exit 2) unless a pair is ACTIVE — record verdicts in the loop, before the pair is killed.

## Pre-flight

If the Claude side is a bare shell (`$` / `%`), stop and re-Link to the real Claude Code terminal.  
See `references/shell-vs-tui-preflight.md` and `references/routing.md`.

## Prompt bank

**Feature:** Implement `<SPEC>` in the open project. Edit real files. Ship. End with `##CLAUDE_DONE##` + CLAIM block.

**Bug:** Bug `<WHAT>`; evidence `<ERR>`. Root-cause, fix, verify. End with `##CLAUDE_DONE##` + CLAIM block.

**Stepwise:** Goal `<GOAL>`. Do only step N. End with `##CLAUDE_DONE##` + CLAIM block (proposed next step in `notes:`).

**Reject:** REJECTED round `<N>`: `<criterion that failed>`. Evidence: `<exact output>`. Fix only this. End with `##CLAUDE_DONE##` + CLAIM block.

## Recovery

```bash
cat ~/.hermes-pong/active-pair.json
tmux list-sessions | grep hermes || true
python3 ~/bin/pong-gate.py
python3 ~/bin/claude-delegate.py --no-wait 'Reply with pong only. Print ##CLAUDE_DONE##'
```

If bridge is off: open Hermes Pong → **New pair** or **Link existing terminals**.

## Anti-pattern

1. Pair connects  
2. Hermes sends 1–2 tasks to Claude  
3. Hermes starts coding with local tools  

**Never do step 3 while `pong-gate.py` says `BRIDGE_ON`.**

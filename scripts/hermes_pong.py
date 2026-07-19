#!/usr/bin/env python3
"""hermes_pong.py — team-scoped state library + CLI for Hermes Pong.

Several pairs (teams) can be live at once: hermes-pair, hermes-pair-1, …
Each Hermes orchestra is BOUND to exactly one pair session and must only
see that session's workers — worker names repeat across teams (w1, Claude,
Grok…), so resolution is only meaningful inside the bound session.

Public API:
    bound_session() -> str | None
    team_state(session=None) -> dict
    roster(session=None) -> list[dict]
    resolve_worker(state, worker_key) -> dict   (raises WorkerResolveError)
    gate_text() -> str
    write_bind(session) -> Path

Bound session discovery order (first hit wins):
  1. explicit session argument (callers pass CLI -s/--session through)
  2. env HERMES_PONG_SESSION
  3. inside tmux: current session name if it is a pair base
     (hermes-pair, hermes-pair-N) or a view name (-h / -c / -wN) stripped to base
  4. active-pair.json session (single-team compat)

CLI:
    python3 hermes_pong.py status               # bound session + bridge + roster
    python3 hermes_pong.py session              # bound session only
    python3 hermes_pong.py write-bind --session hermes-pair-1
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

STATE_DIR = Path.home() / ".hermes-pong"
ACTIVE_FILE = STATE_DIR / "active-pair.json"
PAIRS_FILE = STATE_DIR / "pairs.json"
BINDS_DIR = STATE_DIR / "binds"
SESSIONS_DIR = STATE_DIR / "sessions"
AGENT_HINT = STATE_DIR / "AGENT-HINT.md"

_PAIR_BASE_RE = re.compile(r"^(hermes-pair(?:-\d+)?|hermes-claude(?:-\d+)?)$")
_VIEW_SUFFIX_RE = re.compile(r"-(?:h|c|w\d+)$")

AGENT_HINT_TEXT = """\
# Hermes Pong active? (multi-team)

Several pairs can be live at once. You are bound to ONE session: env
`HERMES_PONG_SESSION` (set at pair start), else your tmux session name.

First actions:

1. Load skill **hermes-pong-bridge**
2. `python3 ~/bin/pong-gate.py` — expect `BRIDGE_ON session=<yours>` + `TEAM:` roster
3. `python3 ~/bin/hermes_pong.py status` — confirm bound session + workers

If `BRIDGE_ON`, all coding goes through YOUR team only:

```bash
python3 ~/bin/pong-delegate.py -s <session> --worker <id> --no-wait '… ##CLAUDE_DONE##'
```

Never send work to any other hermes-pair* session. Worker names repeat across
teams (w1, Claude, Grok…) — resolution is only valid inside your bound session.
Ambiguous worker keys fail closed (exit 2) instead of guessing.
"""


class WorkerResolveError(Exception):
    """Worker key did not resolve to exactly one worker in the bound team."""


def _read_json(path: Path) -> dict:
    try:
        d = json.loads(path.read_text())
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def load_active() -> dict:
    return _read_json(ACTIVE_FILE)


def load_pairs_db() -> dict:
    return _read_json(PAIRS_FILE)


def pair_base_from_tmux_name(name: str | None) -> str | None:
    """hermes-pair-1-w0 / hermes-pair-h → base pair name; None if not pair-like."""
    if not name:
        return None
    name = name.strip()
    if _PAIR_BASE_RE.match(name):
        return name
    stripped = _VIEW_SUFFIX_RE.sub("", name)
    if stripped != name and _PAIR_BASE_RE.match(stripped):
        return stripped
    return None


def _tmux_current_session() -> str | None:
    if not os.environ.get("TMUX"):
        return None
    try:
        r = subprocess.run(
            ["tmux", "display-message", "-p", "#{session_name}"],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0:
            return (r.stdout or "").strip() or None
    except Exception:
        pass
    return None


def detect_bound_session() -> str | None:
    env = (os.environ.get("HERMES_PONG_SESSION") or "").strip()
    if env:
        return env
    base = pair_base_from_tmux_name(_tmux_current_session())
    if base:
        return base
    s = load_active().get("session")
    return str(s) if s else None


def bound_session() -> str | None:
    return detect_bound_session()


def load_session_state(session: str | None = None) -> dict:
    """Pair state for the bound session, from pairs.json[session].

    active-pair.json is merged on top ONLY when its session matches — another
    pair being "active" must never leak its workers into this team.
    """
    session = session or detect_bound_session()
    if not session:
        return {}
    state: dict = {}
    entry = load_pairs_db().get(session)
    if isinstance(entry, dict):
        state = dict(entry)
    active = load_active()
    if active.get("session") == session:
        merged = dict(state)
        merged.update(active)
        state = merged
    state["session"] = session
    return state


def team_state(session: str | None = None) -> dict:
    return load_session_state(session)


def workers_from_state(state: dict) -> list[dict]:
    ws = state.get("workers")
    if isinstance(ws, list) and ws:
        return [w for w in ws if isinstance(w, dict)]
    # legacy single-worker state (fields live directly on the pair entry)
    wid = state.get("claude_window_id") or state.get("worker_window_id")
    if wid in (None, "", "null"):
        return []
    return [{
        "id": "w1",
        "type": state.get("worker_type") or "claude",
        "label": state.get("worker_label") or "Worker",
        "window_id": wid,
        "mode": state.get("claude_mode") or "tmux",
        "tmux_index": 1,
        "cmd": state.get("worker_cmd") or "claude",
    }]


def roster(session: str | None = None) -> list[dict]:
    return workers_from_state(team_state(session))


def format_team_roster(state: dict) -> str:
    ws = workers_from_state(state)
    if not ws:
        return "(no workers)"
    return ", ".join(
        f"{w.get('id')}={w.get('label')}({w.get('type')})" for w in ws
    )


def resolve_worker(state: dict, worker_key: str | None = None) -> dict:
    """Strict, fail-closed resolution inside the bound team only.

    Precedence: exact id → exact type → exact label (ci) → unique label
    substring → 1-based numeric index. 0 or 2+ matches at any step raises
    WorkerResolveError listing THIS team's roster only.
    """
    ws = workers_from_state(state)
    session = state.get("session") or "?"
    if not ws:
        raise WorkerResolveError(f"no workers registered for session={session}")
    if worker_key is None or not str(worker_key).strip():
        return ws[0]
    key = str(worker_key).strip().lower()
    for attr in ("id", "type", "label"):
        hits = [w for w in ws if str(w.get(attr, "")).strip().lower() == key]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise WorkerResolveError(
                f"worker key '{worker_key}' is ambiguous by {attr} in "
                f"session={session}. Team roster: {format_team_roster(state)}"
            )
    hits = [w for w in ws if key in str(w.get("label", "")).lower()]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        raise WorkerResolveError(
            f"worker key '{worker_key}' matches several labels in "
            f"session={session}. Team roster: {format_team_roster(state)}"
        )
    if key.isdigit():
        i = int(key)
        if 1 <= i <= len(ws):
            return ws[i - 1]
    raise WorkerResolveError(
        f"no worker '{worker_key}' in session={session}. "
        f"Team roster: {format_team_roster(state)}"
    )


# ---------------------------------------------------------------------------
# Session-scoped bridge artifacts — last-sent / last-claude live under
# sessions/<session>/ so two live pairs never overwrite each other's files.
# The top-level ~/.hermes-pong/last-*.txt are a compatibility mirror of the
# ACTIVE session only; the orchestra should always read the session path.
# ---------------------------------------------------------------------------

def session_dir(session: str | None = None) -> Path:
    """~/.hermes-pong/sessions/<session>/ for the bound session (created)."""
    s = session or detect_bound_session() or "default"
    d = SESSIONS_DIR / str(s)
    d.mkdir(parents=True, exist_ok=True)
    return d


def last_sent_path(session: str | None = None) -> Path:
    return session_dir(session) / "last-sent.txt"


def last_reply_path(session: str | None = None) -> Path:
    return session_dir(session) / "last-claude.txt"


def last_sent(session: str | None = None) -> str:
    """Text of this session's last handoff ('' if none yet)."""
    try:
        return last_sent_path(session).read_text()
    except Exception:
        return ""


def last_worker_reply(session: str | None = None) -> str:
    """Text of this session's last captured worker reply ('' if none yet)."""
    try:
        return last_reply_path(session).read_text()
    except Exception:
        return ""


# Explicit aliases for orchestra/Swift callers that want the session wording.
def session_last_reply_path(session: str | None = None) -> Path:
    return last_reply_path(session)


def session_last_sent_path(session: str | None = None) -> Path:
    return last_sent_path(session)


def team_context_block(state: dict) -> str:
    """TEAM CONTEXT block injected at the top of every handoff for this pair.

    Built strictly from the bound session's state (pairs.json[bound_session]),
    never another pair. Returns '' when the pair has neither a team_brief nor
    a project_root, so older pairs keep the exact pre-Task-1 prompt.
    """
    session = str(state.get("session") or "?")
    brief = str(state.get("team_brief") or "").strip()
    root = str(state.get("project_root") or "").strip()
    if not brief and not root:
        return ""
    display = str(state.get("display_name") or "").strip() or session
    lines = [
        "## TEAM CONTEXT (bound session only, do not cross pairs)",
        f"- Bound session: {session}",
        f"- Team: {display}",
        f"- Project root: {root or '(unset, ask Hermes before leaving cwd)'}",
        "- Other live pairs are OTHER projects. Never edit their repos. Never assume their tasks.",
        "",
        "### Team brief",
        brief or "(none)",
        "",
        "### Isolation rules",
        "- Resolve workers only inside this session (already enforced by bridge).",
        "- If the user/task names another product/repo not under the project root, STOP and say so. Do not freestyle into it.",
        "- Prefer paths under the project root for all edits.",
    ]
    return "\n".join(lines)


def gate_text(session: str | None = None) -> str:
    """Same info pong-gate prints, as one string."""
    s = session or detect_bound_session()
    if not s:
        return "BRIDGE_OFF"
    state = load_session_state(s)
    if not workers_from_state(state):
        return "BRIDGE_OFF"
    mode = state.get("claude_mode") or "tmux"
    auto = state.get("autonomy_level") or "full"
    return (
        f"BRIDGE_ON session={s} mode={mode} autonomy={auto}\n"
        f"TEAM: {format_team_roster(state)}"
    )


def write_bind(session: str) -> Path:
    """Write the orchestra bind card + refresh AGENT-HINT (multi-team rules)."""
    state = load_session_state(session)
    ws = workers_from_state(state)
    BINDS_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# ORCHESTRA BIND — {session}",
        "",
        f"You are the Hermes ORCHESTRA for tmux session `{session}` ONLY.",
        "",
        "Team roster:",
    ]
    if ws:
        for w in ws:
            lines.append(
                f"- {w.get('id')} = {w.get('label')} ({w.get('type')}) — "
                f"tmux {session}:{w.get('tmux_index')}"
            )
    else:
        lines.append("- (roster not registered yet — run: python3 ~/bin/hermes_pong.py status)")
    root = str(state.get("project_root") or "").strip()
    brief = str(state.get("team_brief") or "").strip()
    if root:
        lines += ["", f"Project root: {root} (all work stays under this folder)"]
    if brief:
        first = brief.splitlines()[0][:160]
        lines += [
            "",
            f"Team brief: {first}",
            f"Full brief: {STATE_DIR / 'briefs' / (session + '.md')}",
        ]
    lines += [
        "",
        "Hard rules:",
        "- Never send work to any other hermes-pair* session or its panes.",
        "- Worker names repeat across teams; only the roster above is yours.",
        f"- Send only: python3 ~/bin/pong-delegate.py -s {session} --worker <id> --no-wait '…'",
        "",
        "First actions:",
        "1. Load skill hermes-pong-bridge",
        "2. python3 ~/bin/pong-gate.py",
        "3. python3 ~/bin/hermes_pong.py status",
        "",
    ]
    path = BINDS_DIR / f"{session}.md"
    path.write_text("\n".join(lines))
    try:
        AGENT_HINT.write_text(AGENT_HINT_TEXT)
    except Exception:
        pass
    return path


def _cli_status() -> int:
    s = detect_bound_session()
    print(f"session: {s or '(none)'}")
    if s:
        state = load_session_state(s)
        print(f"bridge: {gate_text(s).splitlines()[0]}")
        print(f"team: {format_team_roster(state)}")
        bind = BINDS_DIR / f"{s}.md"
        if bind.exists():
            print(f"bind: {bind}")
        print(f"last_sent: {last_sent_path(s)}")
        print(f"last_reply: {last_reply_path(s)}")
    known = ", ".join(sorted(load_pairs_db().keys())) or "(none)"
    print(f"pairs.json sessions: {known}")
    return 0


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(
        prog="hermes_pong.py",
        description="Team-scoped Hermes Pong state (status / session / write-bind).",
    )
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("status", help="bound session + bridge + roster")
    sub.add_parser("session", help="print bound session only")
    wb = sub.add_parser("write-bind", help="write ~/.hermes-pong/binds/<session>.md")
    wb.add_argument("-s", "--session", default=None)
    lr = sub.add_parser("last-reply", help="print sessions/<session>/last-claude.txt path (--tail N for content)")
    lr.add_argument("-s", "--session", default=None)
    lr.add_argument("--tail", type=int, default=0, metavar="N",
                    help="print the last N lines of the reply instead of the path")
    args = ap.parse_args(argv)

    if args.cmd == "session":
        s = detect_bound_session()
        if not s:
            return 1
        print(s)
        return 0
    if args.cmd == "write-bind":
        s = args.session or detect_bound_session()
        if not s:
            print("[hermes_pong] no bound session (pass --session)", file=sys.stderr)
            return 2
        print(write_bind(s))
        return 0
    if args.cmd == "last-reply":
        path = session_last_reply_path(args.session)
        if args.tail > 0:
            text = last_worker_reply(args.session)
            if not text:
                print(f"[hermes_pong] no reply captured yet: {path}", file=sys.stderr)
                return 1
            print("\n".join(text.splitlines()[-args.tail:]))
            return 0
        print(path)
        return 0
    return _cli_status()


if __name__ == "__main__":
    raise SystemExit(main())

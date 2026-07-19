#!/usr/bin/env python3
"""pong-gate.py — exit guidance for Hermes when a Hermes Pong pair is active.

Team-scoped: the gate reports on the BOUND session only (env
HERMES_PONG_SESSION, else the surrounding tmux pair, else active-pair.json).
Several pairs can be live at once; this Hermes must orchestrate its own.

stdout:
  BRIDGE_OFF
  BRIDGE_ON session=... mode=... autonomy=...

exit codes:
  0 — ok (bridge off or on)
  2 — registered but unhealthy (missing session name / bad state)

stderr additionally carries the team roster (TEAM line) and the
verdict-ledger summary (LEDGER / PATTERNS lines) so the discriminator's
memory is re-armed every loop. stdout and exit codes are a stable contract —
new info goes to stderr only.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

STATE_DIR = Path.home() / ".hermes-pong"
STATE = STATE_DIR / "active-pair.json"
PAIRS = STATE_DIR / "pairs.json"


def _import_hermes_pong():
    candidates = [
        Path(__file__).resolve().parent / "hermes_pong.py",
        Path.home() / "bin" / "hermes_pong.py",
        STATE_DIR / "lib" / "hermes_pong.py",
    ]
    for cand in candidates:
        try:
            if not cand.exists():
                continue
            spec = importlib.util.spec_from_file_location("hermes_pong", cand)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
        except Exception:
            continue
    return None


_HP = _import_hermes_pong()

if _HP is not None:
    detect_bound_session = _HP.detect_bound_session
    load_session_state = _HP.load_session_state
    workers_from_state = _HP.workers_from_state
    format_team_roster = _HP.format_team_roster
else:
    _PAIR_BASE_RE = re.compile(r"^(hermes-pair(?:-\d+)?|hermes-claude(?:-\d+)?)$")
    _VIEW_SUFFIX_RE = re.compile(r"-(?:h|c|w\d+)$")

    def _read_json(path: Path) -> dict:
        try:
            d = json.loads(path.read_text())
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def _pair_base(name):
        if not name:
            return None
        name = name.strip()
        if _PAIR_BASE_RE.match(name):
            return name
        stripped = _VIEW_SUFFIX_RE.sub("", name)
        if stripped != name and _PAIR_BASE_RE.match(stripped):
            return stripped
        return None

    def _tmux_current_session():
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

    def detect_bound_session():
        env = (os.environ.get("HERMES_PONG_SESSION") or "").strip()
        if env:
            return env
        base = _pair_base(_tmux_current_session())
        if base:
            return base
        s = _read_json(STATE).get("session")
        return str(s) if s else None

    def load_session_state(session=None):
        session = session or detect_bound_session()
        if not session:
            return {}
        state = {}
        entry = _read_json(PAIRS).get(session)
        if isinstance(entry, dict):
            state = dict(entry)
        active = _read_json(STATE)
        if active.get("session") == session:
            merged = dict(state)
            merged.update(active)
            state = merged
        state["session"] = session
        return state

    def workers_from_state(state):
        ws = state.get("workers")
        if isinstance(ws, list) and ws:
            return [w for w in ws if isinstance(w, dict)]
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
        }]

    def format_team_roster(state):
        ws = workers_from_state(state)
        if not ws:
            return "(no workers)"
        return ", ".join(
            f"{w.get('id')}={w.get('label')}({w.get('type')})" for w in ws
        )


def print_ledger_stderr() -> None:
    """LEDGER + PATTERNS lines on stderr. Never fatal, never touches stdout."""
    try:
        path = Path(__file__).resolve().parent / "pong-ledger.py"
        spec = importlib.util.spec_from_file_location("pong_ledger", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        line = mod.stats_line()
        if line is None:
            print("LEDGER: empty (first pair — verify everything)", file=sys.stderr)
            return
        print(f"LEDGER: {line}", file=sys.stderr)
        patterns = mod.patterns_line(3)
        if patterns:
            print(f"PATTERNS: {patterns}", file=sys.stderr)
    except Exception as e:
        print(f"LEDGER: unavailable ({e})", file=sys.stderr)


def main() -> int:
    sess = detect_bound_session()
    if not sess:
        print("BRIDGE_OFF")
        return 0

    state = load_session_state(sess)
    if not workers_from_state(state):
        print("BRIDGE_OFF")
        print(f"NOTE: no registered pair state for session={sess}", file=sys.stderr)
        return 0

    mode = state.get("claude_mode") or "tmux"
    # v1.3: the verdict loop always runs; legacy ask_* values may linger in
    # old state files but the stdout token format is unchanged.
    auto = state.get("autonomy_level") or "full"

    # Optional: is tmux session alive for tmux mode?
    alive = True
    if mode == "tmux":
        try:
            out = subprocess.run(
                ["tmux", "has-session", "-t", str(sess)],
                capture_output=True,
                text=True,
            )
            alive = out.returncode == 0
        except FileNotFoundError:
            # still treat as on; PATH issues shouldn't disable the rule
            alive = True

    if not alive:
        print(f"BRIDGE_UNHEALTHY session={sess} mode={mode} autonomy={auto}")
        print("RULE: do not code yourself; re-link or New pair first", file=sys.stderr)
        print_ledger_stderr()
        return 2

    print(f"BRIDGE_ON session={sess} mode={mode} autonomy={auto}")
    print(
        f"RULE: orchestrate ONLY this team (session={sess}). "
        "Load skill hermes-pong-bridge. Send via: "
        f"python3 ~/bin/pong-delegate.py -s {sess} --worker <id> --no-wait '…'",
        file=sys.stderr,
    )
    print(f"TEAM: {format_team_roster(state)}", file=sys.stderr)
    project_root = str(state.get("project_root") or "").strip()
    if project_root:
        print(f"PROJECT: {project_root}", file=sys.stderr)
    print_ledger_stderr()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

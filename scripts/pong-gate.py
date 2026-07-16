#!/usr/bin/env python3
"""pong-gate.py — exit guidance for Hermes when a Hermes Pong pair is active.

stdout:
  BRIDGE_OFF
  BRIDGE_ON session=... mode=... autonomy=...

exit codes:
  0 — ok (bridge off or on)
  2 — registered but unhealthy (missing session name / bad state)
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

STATE = Path.home() / ".hermes-pong" / "active-pair.json"


def main() -> int:
    if not STATE.exists():
        print("BRIDGE_OFF")
        return 0
    try:
        d = json.loads(STATE.read_text())
    except Exception:
        print("BRIDGE_OFF")
        return 0

    sess = d.get("session")
    if not sess:
        print("BRIDGE_OFF")
        return 0

    mode = d.get("claude_mode") or "tmux"
    auto = d.get("autonomy_level") or "ask_on_done"

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
        return 2

    print(f"BRIDGE_ON session={sess} mode={mode} autonomy={auto}")
    print(
        "RULE: orchestrate only — all code via: "
        "python3 ~/bin/claude-delegate.py --no-wait '... ##CLAUDE_DONE##'",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

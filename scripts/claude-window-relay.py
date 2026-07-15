#!/usr/bin/env python3
"""
claude-window-relay.py

For *Link existing* pairs (claude_mode=window):
Hermes often does raw `tmux send-keys -t session:1 …` into a hidden pane.
This relay watches that pane and pastes new content into the real Claude Code
Terminal window (model/session preserved).

New-pair (tmux mode) does not need this — Claude already *is* that pane.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

STATE_DIR = Path.home() / ".hermes-pong"
STATE_FILE = STATE_DIR / "active-pair.json"
PID_FILE = STATE_DIR / "relay.pid"
LAST_SENT = STATE_DIR / "last-sent.txt"
LOG = Path.home() / "Library" / "Logs" / "HermesPong-relay.log"


def log(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    line = time.strftime("%H:%M:%S ") + msg
    try:
        with LOG.open("a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def run(cmd: list[str], input_text: str | None = None) -> str:
    r = subprocess.run(cmd, input=input_text, capture_output=True, text=True)
    return (r.stdout or "").strip()


def load_state() -> dict:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def capture(session: str) -> str:
    return run(["tmux", "capture-pane", "-p", "-t", f"{session}:1", "-S", "-60"])


def paste_to_window(window_id: str, text: str) -> bool:
    """Focus Terminal window + clipboard paste + Return (Quartz preferred)."""
    if not text.strip():
        return False
    LAST_SENT.write_text(text)
    subprocess.run(["pbcopy"], input=text, text=True)

    # Focus window via AppleScript
    focus = f'''
tell application "Terminal"
  try
    set w to window id {window_id}
    set index of w to 1
    set selected of w to true
    activate
  end try
end tell
'''
    subprocess.run(["osascript"], input=focus, text=True, capture_output=True)
    time.sleep(0.35)

    # Quartz key events: Cmd+V then Return (more reliable than System Events alone)
    try:
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventPost,
            CGEventSetFlags,
            kCGHIDEventTap,
            kCGEventFlagMaskCommand,
        )

        def tap(key_code: int, flags: int = 0, down: bool = True):
            ev = CGEventCreateKeyboardEvent(None, key_code, down)
            if flags:
                CGEventSetFlags(ev, flags)
            CGEventPost(kCGHIDEventTap, ev)

        # Cmd+V (keycode 9 = v)
        tap(9, kCGEventFlagMaskCommand, True)
        tap(9, kCGEventFlagMaskCommand, False)
        time.sleep(0.2)
        # Return (36)
        tap(36, 0, True)
        tap(36, 0, False)
        time.sleep(0.05)
        tap(36, 0, True)
        tap(36, 0, False)
        log(f"quartz paste+enter → window {window_id} ({len(text)} chars)")
        return True
    except Exception as e:
        log(f"quartz fail {e}; fallback osascript")

    script = f'''
tell application "System Events"
  tell process "Terminal"
    set frontmost to true
    delay 0.15
    keystroke "v" using {{command down}}
    delay 0.25
    key code 36
    delay 0.05
    key code 36
  end tell
end tell
'''
    r = subprocess.run(["osascript"], input=script, text=True, capture_output=True)
    log(f"osascript paste rc={r.returncode} window={window_id}")
    return r.returncode == 0


def extract_payload(pane: str, prev: str) -> str | None:
    """
    Hermes types a full prompt into the shell pane via send-keys.
    Prefer the new content since last capture; skip pure prompts / noise.
    """
    if not pane or pane == prev:
        return None
    # If previous empty, take full pane
    if not prev.strip():
        body = pane.strip()
    else:
        # delta: lines not in previous
        prev_lines = set(prev.splitlines())
        new_lines = [ln for ln in pane.splitlines() if ln not in prev_lines]
        body = "\n".join(new_lines).strip()
        if len(body) < 12:
            # maybe full rewrite
            if len(pane.strip()) > len(prev.strip()) + 12:
                body = pane.strip()
            else:
                return None

    # Ignore boring shell-only noise
    boring = (
        body.startswith("printf ")
        or body.startswith("tmux ")
        or body in {"$", "%", ">>>", "claude"}
        or (body.count("\n") == 0 and len(body) < 8)
    )
    if boring:
        return None
    # Strip trailing shell prompt crumbs
    lines = [ln for ln in body.splitlines() if ln.strip() not in {"$", "%", ">>>"}]
    body = "\n".join(lines).strip()
    if len(body) < 12:
        return None
    return body


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    log(f"relay start pid={os.getpid()}")

    last_hash = ""
    last_pane = ""
    last_pasted_hash = ""
    idle_loops = 0

    while True:
        try:
            st = load_state()
            if st.get("claude_mode") != "window":
                idle_loops += 1
                if idle_loops > 5:
                    log("not window mode — relay exit")
                    break
                time.sleep(1.0)
                continue
            idle_loops = 0
            session = st.get("session")
            wid = str(st.get("claude_window_id") or "")
            if not session or not wid.isdigit():
                time.sleep(1.0)
                continue

            pane = capture(session)
            h = hashlib.sha256(pane.encode()).hexdigest()
            if h == last_hash:
                time.sleep(0.7)
                continue

            payload = extract_payload(pane, last_pane)
            last_hash = h
            last_pane = pane
            if not payload:
                time.sleep(0.5)
                continue

            ph = hashlib.sha256(payload.encode()).hexdigest()
            if ph == last_pasted_hash:
                time.sleep(0.5)
                continue

            log(f"new payload {len(payload)} chars → window {wid}")
            if paste_to_window(wid, payload):
                last_pasted_hash = ph
            time.sleep(1.0)
        except KeyboardInterrupt:
            break
        except Exception as e:
            log(f"loop error: {e}")
            time.sleep(1.5)

    try:
        if PID_FILE.exists() and PID_FILE.read_text().strip() == str(os.getpid()):
            PID_FILE.unlink()
    except Exception:
        pass
    log("relay stop")


if __name__ == "__main__":
    main()

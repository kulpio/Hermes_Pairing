"""Optional: clipboard paste into a Terminal.app window — verify-after-focus (V4)."""

from __future__ import annotations

import subprocess
import time
from typing import Any

from .base import TransportResult


def _osascript(script: str) -> tuple[bool, str]:
    try:
        r = subprocess.run(
            ["osascript"],
            input=script,
            text=True,
            capture_output=True,
            timeout=30,
        )
        out = (r.stdout or "").strip()
        err = (r.stderr or "").strip()
        return r.returncode == 0, out or err
    except Exception as e:
        return False, str(e)


def _frontmost_info() -> dict[str, str] | None:
    """Return frontmost process name + Terminal front window id if Terminal is front."""
    script = '''
tell application "System Events"
  set frontApp to name of first application process whose frontmost is true
end tell
set wid to ""
try
  tell application "Terminal"
    if (count of windows) > 0 then
      set wid to id of front window as string
    end if
  end tell
end try
return frontApp & "|" & wid
'''
    ok, out = _osascript(script)
    if not ok or not out:
        return None
    parts = out.split("|", 1)
    return {
        "app": parts[0].strip() if parts else "",
        "window_id": parts[1].strip() if len(parts) > 1 else "",
    }


def _read_clipboard() -> str:
    try:
        r = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=10)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def _write_clipboard(text: str) -> bool:
    try:
        r = subprocess.run(["pbcopy"], input=text, text=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def send(job: dict[str, Any], worker: dict[str, Any], state: dict[str, Any]) -> TransportResult:
    # V4: only the worker's own window_id — never fall back to global state.claude_window_id
    # when it could be another team's seat. Worker record is authoritative.
    wid = str(worker.get("window_id") or "")
    if not wid.isdigit():
        return TransportResult(
            "window_paste",
            False,
            "no numeric worker window_id (refusing state.claude_window_id fallback)",
        )
    prompt = job.get("_prompt") or ""
    session = str(job.get("session") or state.get("session") or "")

    saved_clip = _read_clipboard()
    if not _write_clipboard(prompt):
        return TransportResult("window_paste", False, "pbcopy failed")

    # Focus: do NOT swallow failures
    focus = f'''
tell application "Terminal"
  set w to window id {wid}
  set index of w to 1
  set selected of w to true
  activate
end tell
return "ok"
'''
    ok, detail = _osascript(focus)
    if not ok:
        _write_clipboard(saved_clip)
        try:
            from .. import events

            events.emit(
                "route.refused",
                session=session or None,
                reason="window_paste_focus_failed",
                message=detail or "focus failed",
                window_id=wid,
            )
        except Exception:
            pass
        return TransportResult(
            "window_paste", False, f"focus failed for window {wid}: {detail}"
        )

    time.sleep(0.35)

    # V4 verify-after-focus: frontmost must be Terminal AND front window id == wid
    info = _frontmost_info()
    if not info or info.get("app") != "Terminal" or info.get("window_id") != wid:
        _write_clipboard(saved_clip)
        msg = (
            f"verify-after-focus failed: front={info!r} expected Terminal id={wid}"
        )
        try:
            from .. import events

            events.emit(
                "route.refused",
                session=session or None,
                reason="window_paste_verify_failed",
                message=msg,
                window_id=wid,
            )
        except Exception:
            pass
        return TransportResult("window_paste", False, msg)

    script = '''
tell application "System Events"
  tell process "Terminal"
    set frontmost to true
    delay 0.15
    keystroke "v" using {command down}
    delay 0.25
    key code 36
    delay 0.05
    key code 36
  end tell
end tell
'''
    r_ok, r_detail = _osascript(script)
    # Restore prior clipboard
    _write_clipboard(saved_clip)
    return TransportResult(
        "window_paste",
        r_ok,
        f"window {wid} paste ok={r_ok} {r_detail}",
        meta={"window_id": wid},
    )

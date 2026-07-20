"""Cross-team routing isolation — zero chance of wrong-team delivery.

See ~/.pong/briefs/pong-team-3dmap-perf-audit.md Addendum 2.
"""

from __future__ import annotations

import os
import secrets
import subprocess
from pathlib import Path
from typing import Any

from . import events
from .paths import ensure_layout, sessions_dir, state_dir


class RouteRefused(Exception):
    """Mutating op refused — CLI should exit 2."""

    exit_code = 2

    def __init__(self, message: str, *, reason: str = "route.refused"):
        super().__init__(message)
        self.reason = reason


def session_token_path(session: str) -> Path:
    return sessions_dir(session) / "token"


def read_session_token(session: str) -> str | None:
    p = session_token_path(session)
    if not p.is_file():
        return None
    try:
        return p.read_text(encoding="utf-8").strip() or None
    except Exception:
        return None


def ensure_session_token(session: str) -> str:
    """Create per-session token file if missing. Returns token string."""
    ensure_layout(session)
    p = session_token_path(session)
    existing = read_session_token(session)
    if existing:
        return existing
    tok = secrets.token_hex(16)
    p.write_text(tok + "\n", encoding="utf-8")
    try:
        p.chmod(0o600)
    except Exception:
        pass
    return tok


def presented_token() -> str | None:
    for key in ("PONG_TOKEN", "PONG_SESSION_TOKEN"):
        v = (os.environ.get(key) or "").strip()
        if v:
            return v
    return None


def _tmux_current_session() -> str | None:
    if not os.environ.get("TMUX"):
        return None
    try:
        r = subprocess.run(
            ["tmux", "display-message", "-p", "#{session_name}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            return (r.stdout or "").strip() or None
    except Exception:
        return None
    return None


def resolve_caller_session() -> str | None:
    """Identity of the calling seat — never active-pair."""
    for key in ("PONG_SESSION", "HERMES_PONG_SESSION"):
        v = (os.environ.get(key) or "").strip()
        if v:
            return v
    from .state import pair_base_from_tmux_name

    return pair_base_from_tmux_name(_tmux_current_session())


def resolve_read_session(explicit: str | None = None) -> str | None:
    """Read-only resolution: explicit → env → tmux → active-pair (legacy)."""
    if explicit and str(explicit).strip():
        return str(explicit).strip()
    caller = resolve_caller_session()
    if caller:
        return caller
    from .state import load_active

    active = load_active()
    sess = active.get("session")
    return str(sess) if sess else None


def _token_ok_for(session: str) -> bool:
    expected = read_session_token(session)
    if not expected:
        # First touch: create token for in-session caller only
        return False
    presented = presented_token()
    if presented and secrets.compare_digest(presented, expected):
        return True
    # In-session seat without exporting token: allow if caller session matches
    # and token file exists (worker was spawned into this session).
    caller = resolve_caller_session()
    if caller and caller == session:
        return True
    return False


def resolve_write_session(explicit: str | None = None) -> str:
    """
    Session for mutating ops. Never falls back to active-pair.
    Cross-session --session requires PONG_TOKEN matching the *target*.
    """
    caller = resolve_caller_session()
    target: str | None = None

    if explicit and str(explicit).strip():
        target = str(explicit).strip()
    elif caller:
        target = caller
    else:
        refuse(
            "no write session — set PONG_SESSION or run inside the team tmux "
            "(active-pair is not used for mutations)",
            reason="no_write_session",
        )

    assert target is not None

    # Ensure token exists for legitimate in-session first use
    if caller and caller == target:
        ensure_session_token(target)
        if not _token_ok_for(target):
            # still ok: we just ensured token; in-session always ok after ensure
            pass
        return target

    # Cross-session or no caller identity with explicit target
    ensure_layout(target)
    expected = read_session_token(target)
    if not expected:
        # Target session never initialized — refuse cross (don't create token for stranger)
        if caller and caller != target:
            refuse(
                f"cross-session write to {target!r} refused "
                f"(caller bound to {caller!r}; target has no token / not initialized)",
                reason="cross_session_no_token",
                target=target,
                caller=caller,
            )
        # explicit with no caller: require token already present, or create if env asks
        ensure_session_token(target)
        expected = read_session_token(target)

    presented = presented_token()
    if not presented or not expected or not secrets.compare_digest(presented, expected):
        refuse(
            f"write to session {target!r} refused — present matching PONG_TOKEN "
            f"(caller={caller or 'none'})",
            reason="token_mismatch",
            target=target,
            caller=caller,
        )
    return target


def refuse(
    message: str,
    *,
    reason: str = "route.refused",
    target: str | None = None,
    caller: str | None = None,
    **extra: Any,
) -> None:
    try:
        events.emit(
            "route.refused",
            session=caller or target,
            reason=reason,
            message=message,
            target=target,
            caller=caller,
            **extra,
        )
    except Exception:
        pass
    raise RouteRefused(message, reason=reason)


def assert_claim_session(job_session: str, *, claim_token: str | None = None) -> None:
    """Claim must be for a session the caller can write, with matching seat token."""
    try:
        write_sess = resolve_write_session(None)
    except RouteRefused:
        # try with explicit job session + presented token
        write_sess = None

    tok = claim_token or presented_token()
    expected = read_session_token(job_session)

    if write_sess and write_sess == job_session:
        ensure_session_token(job_session)
        return

    if expected and tok and secrets.compare_digest(tok, expected):
        return

    refuse(
        f"claim refused for job session {job_session!r} "
        f"(caller write session={write_sess!r})",
        reason="claim_session_mismatch",
        target=job_session,
        caller=write_sess,
    )


def register_worker_pane(
    session: str,
    worker_id: str,
    *,
    pane_id: str,
    start_command: str | None = None,
    title: str | None = None,
) -> Path:
    """Persist immutable pane registration for a worker seat."""
    ensure_layout(session)
    ensure_session_token(session)
    path = sessions_dir(session) / "panes.json"
    from .jsonutil import read_json, write_json

    data = read_json(path) if path.exists() else {}
    if not isinstance(data, dict):
        data = {}
    data[str(worker_id)] = {
        "pane_id": pane_id,
        "start_command": start_command or "",
        "title": title or f"pong.{session}.{worker_id}",
        "session": session,
    }
    write_json(path, data)
    return path


def load_pane_registration(session: str, worker_id: str) -> dict[str, Any] | None:
    from .jsonutil import read_json

    path = sessions_dir(session) / "panes.json"
    data = read_json(path)
    if not isinstance(data, dict):
        return None
    row = data.get(str(worker_id))
    return dict(row) if isinstance(row, dict) else None


def exact_window_title(session: str, seat: str) -> str:
    """Exact recovery token — no fuzzy match."""
    return f"pong.{session}.{seat}"


def partition_last_paths(session: str) -> dict[str, Path]:
    """Per-session last-* paths (global root mirrors deprecated)."""
    ensure_layout(session)
    d = sessions_dir(session)
    return {
        "last_sent": d / "last-sent.txt",
        "last_reply": d / "last-reply.txt",
        "last_claude": d / "last-claude.txt",
    }


def write_session_last(session: str, name: str, text: str) -> None:
    paths = partition_last_paths(session)
    key = {
        "last-sent": "last_sent",
        "last_sent": "last_sent",
        "last-reply": "last_reply",
        "last_reply": "last_reply",
        "last-claude": "last_claude",
        "last_claude": "last_claude",
    }.get(name, name)
    p = paths.get(key)
    if p:
        p.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
    # Do NOT write global root mirrors (V6 isolation)


def brief_send(
    *,
    source_session: str,
    to_session: str,
    body: str,
    subject: str | None = None,
) -> Path:
    """
    Sole legitimate inter-team channel: file drop into briefs/<to>/inbox/.
    Never auto-pasted.
    """
    if not (body or "").strip():
        raise ValueError("empty brief body")
    # source must be write-capable for source_session
    resolve_write_session(source_session if source_session else None)

    root = state_dir() / "briefs" / to_session / "inbox"
    root.mkdir(parents=True, exist_ok=True)
    import time

    ts = time.strftime("%Y%m%d_%H%M%S")
    name = f"{ts}-from-{source_session}.md"
    path = root / name
    title = subject or f"brief from {source_session}"
    path.write_text(
        f"# {title}\n\n"
        f"- from: `{source_session}`\n"
        f"- to: `{to_session}`\n"
        f"- channel: pong brief send (not auto-pasted)\n\n"
        f"{body.rstrip()}\n",
        encoding="utf-8",
    )
    try:
        events.emit(
            "brief.sent",
            session=source_session,
            to=to_session,
            path=str(path),
        )
    except Exception:
        pass
    return path

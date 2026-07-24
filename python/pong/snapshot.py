"""UI snapshot — single document the panel polls."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from . import events
from . import ledger as ledger_mod
from .jobs import (
    activity_open_jobs,
    cancel_stale_abandoned_jobs,
    open_jobs,
    summarize_jobs,
)
from .jsonutil import write_json
from .paths import binds_dir, sessions_dir, state_dir
from .schema import CONTRACT_VERSION, SCHEMA_VERSION
from .state import (
    conductor_from_state,
    detect_bound_session,
    gate_text,
    load_pairs_db,
    load_session_state,
    normalize_pair_state,
    workers_from_state,
)


def _worker_status_hint(session: str, worker_id: str) -> tuple[str, int]:
    """Map status for UI: running/notified → in-flight; queued → busy; none → idle.

    Only age-fresh open jobs count (stale notified/queued/running do not pulse seats).
    """
    act = activity_open_jobs(session)
    open_j = [
        j
        for j in act
        if j.get("worker") == worker_id and not j.get("human_takeover")
    ]
    takeover = [
        j
        for j in act
        if j.get("worker") == worker_id and j.get("status") == "human_takeover"
    ]
    if takeover:
        return "human_takeover", len(open_j) + len(takeover)
    if not open_j:
        return "idle", 0
    # Prefer real in-flight over soft "busy" so map seats calm when only queued
    for j in open_j:
        st = str(j.get("status") or "").lower()
        if st in ("running", "notified") or "working" in st:
            return "running", len(open_j)
    return "busy", len(open_j)


def team_snapshot(session: str, entry: dict[str, Any] | None = None) -> dict[str, Any]:
    from .subagents import collect_ephemeral_subs

    # Hygiene first: auto-cancel abandoned notified/queued (>2h) / running (>24h)
    try:
        cancel_stale_abandoned_jobs(session)
    except Exception:
        pass

    state = load_session_state(session)
    if not state and entry:
        state = normalize_pair_state({**entry, "session": session})
    if not state:
        state = {"session": session, "workers": [], "conductor": {}}
    c = conductor_from_state(state)
    cond_id = str(c.get("id") or "c1")
    permanent_ids: set[str] = {cond_id}
    workers_out = []
    for w in workers_from_state(state):
        wid = str(w.get("id"))
        permanent_ids.add(wid)
        hint, nopen = _worker_status_hint(session, wid)
        # Permanent roster workers tagged ephemeral only appear while busy
        is_eph_worker = bool(w.get("ephemeral"))
        workers_out.append(
            {
                "id": wid,
                "type": w.get("type"),
                "label": w.get("label"),
                "cmd": w.get("cmd"),
                "mode": w.get("mode"),
                "window_id": w.get("window_id"),
                "tmux_index": w.get("tmux_index"),
                "done_marker": w.get("done_marker"),
                "status_hint": hint,
                "open_jobs": nopen,
                "parent_id": w.get("parent_id") or w.get("parent"),
                "ephemeral": is_eph_worker,
                "mission_role": w.get("mission_role") or w.get("role") or "coder",
                # Hidden from map when ephemeral + idle (vanish when done)
                "map_visible": (not is_eph_worker) or nopen > 0 or hint not in ("idle", ""),
            }
        )
    jobs = summarize_jobs(session)
    # Ephemeral seats track activity-fresh jobs so stale notified does not pin them
    open_list = activity_open_jobs(session)
    eph_subs = collect_ephemeral_subs(
        session,
        permanent_ids=permanent_ids,
        open_job_list=open_list,
        conductor_id=cond_id,
    )
    sess_dir = sessions_dir(session)
    return {
        "session": session,
        "display_name": state.get("display_name") or "",
        "stowed": bool(state.get("stowed")),
        "schema_version": state.get("schema_version") or SCHEMA_VERSION,
        "conductor": {
            "id": c.get("id"),
            "type": c.get("type"),
            "label": c.get("label"),
            "cmd": c.get("cmd"),
            "window_id": c.get("window_id"),
            "mode": c.get("mode"),
            "tmux_index": c.get("tmux_index"),
        },
        "workers": workers_out,
        "ephemeral_subs": eph_subs,
        "project_root": state.get("project_root") or "",
        "team_brief": state.get("team_brief") or "",
        "transport_default": state.get("transport_default") or "job+paste",
        "jobs": jobs,
        "artifacts": {
            "last_sent": str(sess_dir / "last-sent.txt"),
            "last_reply": str(sess_dir / "last-reply.txt"),
            "bind_card": str(binds_dir() / f"{session}.md"),
        },
    }


def list_team_sessions() -> list[str]:
    from .state import is_pair_name

    names = set()
    for k in load_pairs_db().keys():
        if is_pair_name(str(k)):
            names.add(str(k))
    # also sessions with job dirs
    jobs_root = state_dir() / "jobs"
    if jobs_root.exists():
        for p in jobs_root.iterdir():
            if p.is_dir() and is_pair_name(p.name):
                names.add(p.name)
    return sorted(names)


def build_snapshot(*, session: str | None = None, events_n: int = 40) -> dict[str, Any]:
    bound = detect_bound_session(session)
    bridge_line, bridge_code = gate_text(bound)
    bridge_on = bridge_line.startswith("BRIDGE_ON")
    db = load_pairs_db()
    if session:
        teams_list = [session]
    else:
        teams_list = list_team_sessions()
        # if bound not in list but has state, include
        if bound and bound not in teams_list:
            teams_list = [bound] + teams_list

    teams = []
    for s in teams_list:
        entry = db.get(s) if isinstance(db.get(s), dict) else None
        teams.append(team_snapshot(s, entry))

    try:
        led = ledger_mod.summary()
        led_public = {
            "rounds": led.get("rounds"),
            "accepts": led.get("accepts"),
            "rejects": led.get("rejects"),
            "escalations": led.get("escalations"),
            "accept_rate": led.get("accept_rate"),
            "reject_streak": led.get("reject_streak"),
            "last": led.get("last"),
        }
    except Exception:
        led_public = {
            "rounds": 0,
            "accepts": 0,
            "rejects": 0,
            "escalations": 0,
            "accept_rate": 0.0,
            "reject_streak": 0,
            "last": None,
        }

    snap = {
        "schema_version": SCHEMA_VERSION,
        "contract_version": CONTRACT_VERSION,
        "generated_at": time.time(),
        "state_dir": str(state_dir()),
        "bound_session": bound,
        "bridge": bridge_line,
        "bridge_on": bridge_on,
        "bridge_code": bridge_code,
        "teams": teams,
        "ledger": led_public,
        "events_tail": events.tail(events_n, session=session),
    }
    return snap


def write_snapshot(snap: dict[str, Any] | None = None, *, session: str | None = None) -> Path:
    snap = snap or build_snapshot(session=session)
    path = state_dir() / "snapshot.json"
    write_json(path, snap)
    return path

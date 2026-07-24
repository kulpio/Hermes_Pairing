"""Job control plane — source of truth for handoffs."""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import Any

from . import events
from .jsonutil import read_json, write_json
from .paths import ensure_layout, jobs_dir
from .schema import (
    JOB_STATUSES,
    SchemaError,
    TERMINAL_STATUSES,
    assert_transition,
    job_summary,
    validate_job,
)
from .state import (
    format_permissions_block,
    format_team_context,
    load_session_state,
    resolve_worker,
    session_artifact,
)

# re-export for callers
STATUSES = JOB_STATUSES


def new_job_id() -> str:
    ts = time.strftime("%Y%m%d_%H%M%S")
    return f"job_{ts}_{uuid.uuid4().hex[:6]}"


def job_path(session: str, job_id: str) -> Path:
    return jobs_dir(session) / f"{job_id}.json"


def load_job(session: str, job_id: str) -> dict[str, Any]:
    return read_json(job_path(session, job_id))


def save_job(job: dict[str, Any]) -> Path:
    errs = validate_job(job)
    if errs:
        raise SchemaError("invalid job: " + "; ".join(errs))
    sess = str(job["session"])
    jid = str(job["id"])
    ensure_layout(sess)
    job["updated_at"] = time.time()
    # strip ephemeral keys before disk
    disk = {k: v for k, v in job.items() if not str(k).startswith("_")}
    path = job_path(sess, jid)
    write_json(path, disk)
    write_json(jobs_dir(sess) / "latest.json", {"id": jid, "path": str(path)})
    return path


def list_jobs(session: str, *, status: str | None = None) -> list[dict[str, Any]]:
    d = jobs_dir(session)
    if not d.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(d.glob("job_*.json"), reverse=True):
        j = read_json(p)
        if not j:
            continue
        if status and j.get("status") != status:
            continue
        out.append(j)
    return out


def open_jobs(session: str) -> list[dict[str, Any]]:
    return [
        j
        for j in list_jobs(session)
        if j.get("status") not in TERMINAL_STATUSES
    ]


# --- Activity age (align Mission STUCK / RUNTIME thresholds) ---
# notified/queued soft-activity: 20 minutes; running: 45 minutes.
# Auto-cancel abandoned notified/queued after 2 hours; running after 24 hours.
ACTIVITY_NOTIFIED_QUEUED_MAX_AGE = 20 * 60
ACTIVITY_RUNNING_MAX_AGE = 45 * 60
STALE_NOTIFIED_CANCEL_AGE = 2 * 3600
STALE_RUNNING_CANCEL_AGE = 24 * 3600


def job_age_seconds(job: dict[str, Any], *, now: float | None = None) -> float:
    """Age from updated_at, then created_at. Missing timestamps → 0 (treat as fresh)."""
    now_t = time.time() if now is None else now
    raw = job.get("updated_at")
    if raw is None:
        raw = job.get("created_at")
    try:
        ts = float(raw or 0)
    except (TypeError, ValueError):
        ts = 0.0
    if ts <= 0:
        return 0.0
    return max(0.0, now_t - ts)


def is_activity_fresh(job: dict[str, Any], *, now: float | None = None) -> bool:
    """Whether a non-terminal job still counts toward map seat activity."""
    st = str(job.get("status") or "").lower()
    age = job_age_seconds(job, now=now)
    if st == "human_takeover" or job.get("human_takeover"):
        return True
    if st in ("notified", "queued"):
        return age <= ACTIVITY_NOTIFIED_QUEUED_MAX_AGE
    if st == "running" or "working" in st:
        return age <= ACTIVITY_RUNNING_MAX_AGE
    # Other non-terminal: include while under notified threshold
    return age <= ACTIVITY_NOTIFIED_QUEUED_MAX_AGE


def activity_open_jobs(session: str, *, now: float | None = None) -> list[dict[str, Any]]:
    """Open jobs fresh enough to drive status_hint / map ACTIVE pulse."""
    now_t = time.time() if now is None else now
    return [j for j in open_jobs(session) if is_activity_fresh(j, now=now_t)]


def cancel_stale_abandoned_jobs(
    session: str, *, now: float | None = None
) -> list[str]:
    """
    Durable hygiene: auto-cancel abandoned jobs.
    - notified / queued age > 2h → cancelled (cancel_reason=stale_notified)
    - running age > 24h → cancelled (cancel_reason=stale_running)
    Returns cancelled job ids.
    """
    now_t = time.time() if now is None else now
    cancelled: list[str] = []
    for j in list(open_jobs(session)):
        jid = str(j.get("id") or "")
        if not jid:
            continue
        st = str(j.get("status") or "").lower()
        age = job_age_seconds(j, now=now_t)
        reason: str | None = None
        if st in ("notified", "queued") and age > STALE_NOTIFIED_CANCEL_AGE:
            reason = "stale_notified"
        elif st == "running" and age > STALE_RUNNING_CANCEL_AGE:
            reason = "stale_running"
        if not reason:
            continue
        try:
            set_status(
                session,
                jid,
                "cancelled",
                skip_snapshot=True,
                cancel_reason=reason,
                error=f"auto-cancelled: {reason}",
            )
            cancelled.append(jid)
        except Exception:
            # Best-effort hygiene; never break snapshot
            pass
    return cancelled


def build_task_prompt(job: dict[str, Any], state: dict[str, Any]) -> str:
    """Full text a worker would see (TUI paste or headless)."""
    parts: list[str] = []
    worker_id = str(job.get("worker") or "")

    ctx = format_team_context(state)
    if ctx:
        parts.append(ctx.rstrip())
    perms = format_permissions_block(state)
    if perms:
        parts.append(perms.rstrip())

    # Durable role + who-is-who (so humans need not re-brief each boot)
    if not job.get("no_identity"):
        try:
            from .role_identity import format_seat_identity

            ident = format_seat_identity(state, worker_id)
            if ident.strip():
                parts.append(ident.rstrip())
        except Exception:
            pass

    # Architecture road + hop recap (hard guardrails, not suggestions)
    if not job.get("no_recap"):
        try:
            from .role_identity import format_architecture_guardrails

            road = format_architecture_guardrails(state, worker_id)
            if road.strip():
                parts.append(road.rstrip())
        except Exception:
            try:
                from .handoff_recap import architecture_recap_for_seat

                recap = architecture_recap_for_seat(state, worker_id)
                if recap.strip():
                    parts.append(recap.rstrip())
            except Exception:
                pass

    parts.append(f"## JOB `{job['id']}`")
    parts.append(f"- worker: {job.get('worker')}")
    try:
        from .role_identity import role_meta, seat_mission_role

        mr = seat_mission_role(state, worker_id)
        parts.append(f"- mission_role: {role_meta(mr)['title']} ({mr})")
    except Exception:
        pass
    parts.append(f"- round: {job.get('round', 1)}")
    if job.get("project_root"):
        parts.append(f"- project_root: {job['project_root']}")
    parts.append("")
    parts.append(str(job.get("task") or "").rstrip())
    parts.append("")
    acc = job.get("acceptance") or []
    if acc:
        parts.append("## Acceptance")
        for i, a in enumerate(acc, 1):
            if isinstance(a, dict):
                parts.append(
                    f"{i}. `{a.get('cmd')}` (expect exit {a.get('expect_exit', 0)})"
                )
            else:
                parts.append(f"{i}. {a}")
        parts.append("")
    marker = job.get("done_marker") or "##WORKER_DONE##"
    if job.get("require_claim", True):
        parts.append(
            "When completely done, print exactly "
            f"{marker} on its own line, then a CLAIM block:\n"
            "```\nCLAIM:\nfiles: <comma-separated paths>\n"
            "commands: <what you ran>\n"
            "summary: <one short paragraph>\n```"
        )
        try:
            from .flow import claim_notify_targets

            targets = claim_notify_targets(state, worker_id)
            if targets:
                joined = ", ".join(targets)
                parts.append(
                    f"Architecture claim path: ** Send claim to {joined} ** "
                    f"(also run `pong job claim` so the control plane records it)."
                )
        except Exception:
            pass
    else:
        parts.append(
            f"When completely done, print exactly {marker} on its own line, "
            "then a short summary."
        )
    parts.append("")
    parts.append(
        f"Job file: {job_path(str(job['session']), str(job['id']))}\n"
        "Prefer updating the job claim via `pong job claim` if available; "
        "CLAIM text is the fallback."
    )
    return "\n".join(parts) + "\n"


def create_job(
    *,
    session: str | None,
    worker_key: str | None,
    task: str,
    acceptance: list[Any] | None = None,
    require_claim: bool = True,
    round_n: int = 1,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    from .flow import assert_assign_allowed
    from .routing import resolve_write_session, write_session_last

    # V1/V2: never fall back to active-pair; require session token for cross-team
    sess = resolve_write_session(session)
    state = load_session_state(sess)
    if not state.get("session"):
        state = dict(state)
        state["session"] = sess
    if not (task or "").strip():
        raise ValueError("empty task")
    worker = resolve_worker(state, worker_key)
    # Architecture edges are enforced when flow_graph is non-empty (UI topology).
    from_seat = None
    if extra and extra.get("from_seat"):
        from_seat = str(extra.get("from_seat"))
    assert_assign_allowed(state, str(worker.get("id") or ""), from_seat=from_seat)
    jid = new_job_id()
    now = time.time()
    job: dict[str, Any] = {
        "id": jid,
        "session": sess,
        "worker": worker.get("id"),
        "worker_type": worker.get("type"),
        "worker_label": worker.get("label"),
        "status": "queued",
        "task": task.strip(),
        "project_root": state.get("project_root") or "",
        "team_brief": state.get("team_brief") or "",
        "acceptance": acceptance or [],
        "done_marker": worker.get("done_marker") or "##WORKER_DONE##",
        "require_claim": require_claim,
        "human_takeover": False,
        "round": round_n,
        "created_at": now,
        "updated_at": now,
        "claim": None,
        "error": None,
        "transports_used": [],
        "prompt_path": None,
        "schema_version": 2,
    }
    if extra:
        for k, v in extra.items():
            if not str(k).startswith("_"):
                job[k] = v
    prompt = build_task_prompt(job, state)
    ensure_layout(str(sess))
    prompt_path = session_artifact(state, f"{jid}.prompt.txt")
    prompt_path.write_text(prompt, encoding="utf-8")
    job["prompt_path"] = str(prompt_path)
    # V6: per-session last-sent only — no global root mirror
    write_session_last(str(sess), "last-sent", prompt)
    save_job(job)
    events.emit(
        "job.created",
        session=str(sess),
        job_id=jid,
        worker=worker.get("id"),
        worker_type=worker.get("type"),
    )
    job["_prompt"] = prompt
    job["_state"] = state
    job["_worker"] = worker
    return job


def _clear_ephemeral_for_job(session: str, job_id: str) -> None:
    """Drop registry marks tied to a finished job so the 3D seat vanishes."""
    try:
        from . import subagents

        subagents.unregister(session, job_id)
        subagents.unregister(session, f"eph_{job_id}")
    except Exception:
        pass


def set_status(
    session: str,
    job_id: str,
    status: str,
    *,
    skip_snapshot: bool = False,
    **fields: Any,
) -> dict[str, Any]:
    from .routing import resolve_write_session

    sess = resolve_write_session(session)
    job = load_job(sess, job_id)
    if not job:
        raise FileNotFoundError(job_id)
    if str(job.get("session") or sess) != sess:
        from .routing import refuse

        refuse(
            f"set_status refused — job session {job.get('session')!r} ≠ write session {sess!r}",
            reason="job_session_mismatch",
            target=str(job.get("session")),
            caller=sess,
        )
    prev = str(job.get("status") or "queued")
    assert_transition(prev, status)
    job["status"] = status
    if status == "human_takeover":
        job["human_takeover"] = True
    if status == "running" and job.get("human_takeover") and status != "human_takeover":
        # resuming from takeover
        pass
    for k, v in fields.items():
        if not str(k).startswith("_"):
            job[k] = v
    save_job(job)
    if status in TERMINAL_STATUSES:
        _clear_ephemeral_for_job(sess, job_id)
        # Push UI snapshot so map seats calm without waiting for the next panel poll.
        # skip_snapshot=True when hygiene runs inside team_snapshot (avoids re-entry).
        if not skip_snapshot:
            try:
                from .snapshot import write_snapshot

                write_snapshot(session=sess)
            except Exception:
                pass
    events.emit(
        "job.status",
        session=sess,
        job_id=job_id,
        status=status,
        **{"from": prev},
    )
    return job


def record_claim(
    session: str,
    job_id: str,
    *,
    files: list[str] | None = None,
    commands: str | None = None,
    summary: str | None = None,
    raw: str | None = None,
    claim_token: str | None = None,
) -> dict[str, Any]:
    import secrets

    from .routing import (
        assert_claim_session,
        presented_token,
        read_session_token,
        resolve_write_session,
        write_session_last,
    )

    # V2/V7: write gate + session-bound claim token
    write_sess = resolve_write_session(session)
    job = load_job(write_sess, job_id)
    if not job:
        raise FileNotFoundError(job_id)
    job_sess = str(job.get("session") or write_sess)
    if job_sess != write_sess:
        from .routing import refuse

        refuse(
            f"claim refused — write session {write_sess!r} ≠ job session {job_sess!r}",
            reason="claim_session_mismatch",
            target=job_sess,
            caller=write_sess,
        )
    assert_claim_session(job_sess, claim_token=claim_token)
    prev = str(job.get("status") or "queued")
    # claim implies done — allow from non-terminal via transition rules
    if prev not in TERMINAL_STATUSES or prev == "human_takeover":
        try:
            assert_transition(prev, "done")
        except SchemaError:
            # force path: if already done, just update claim
            if prev != "done":
                raise
    tok = claim_token or presented_token()
    expected = read_session_token(job_sess)
    claim = {
        "files": files or [],
        "commands": commands or "",
        "summary": summary or "",
        "raw": raw or "",
        "at": time.time(),
        "session": job_sess,
        "token_ok": bool(
            tok and expected and secrets.compare_digest(tok, expected)
        ),
    }
    job["claim"] = claim
    job["status"] = "done"
    job["human_takeover"] = False
    save_job(job)
    _clear_ephemeral_for_job(job_sess, job_id)
    events.emit("job.claim", session=job_sess, job_id=job_id, worker=job.get("worker"))
    if prev != "done":
        events.emit(
            "job.status",
            session=job_sess,
            job_id=job_id,
            status="done",
            **{"from": prev},
        )
    text = raw or summary or json_fallback(claim)
    # V6: per-session last-* only — no global root mirrors
    write_session_last(job_sess, "last-reply", text)
    write_session_last(job_sess, "last-claude", text)
    # Push claim recap along architecture claim edges (usually → orchestrator TUI)
    try:
        from .flow import notify_claim
        from .state import load_session_state as _lss

        st = _lss(job_sess) or {"session": job_sess}
        st.setdefault("session", job_sess)
        notify_claim(st, job, claim)
    except Exception:
        pass
    try:
        from .snapshot import write_snapshot

        write_snapshot(session=job_sess)
    except Exception:
        pass
    return job


def json_fallback(claim: dict[str, Any]) -> str:
    import json

    return json.dumps(claim, indent=2)


def pending_for_worker(session: str, worker_id: str) -> list[dict[str, Any]]:
    return [
        j
        for j in list_jobs(session)
        if j.get("worker") == worker_id
        and j.get("status") in ("queued", "notified")
        and not j.get("human_takeover")
    ]


def summarize_jobs(session: str, *, recent_n: int = 10, now: float | None = None) -> dict[str, Any]:
    all_j = list_jobs(session)
    open_j = [j for j in all_j if j.get("status") not in TERMINAL_STATUSES]
    now_t = time.time() if now is None else now
    activity_j = [j for j in open_j if is_activity_fresh(j, now=now_t)]
    recent = [j for j in all_j if j.get("status") in TERMINAL_STATUSES][:recent_n]
    # Per-status tallies for Mission “Jobs by status” (design handoff)
    by_status: dict[str, int] = {}
    for j in all_j:
        st = str(j.get("status") or "unknown")
        by_status[st] = by_status.get(st, 0) + 1
    return {
        # Full open list (Mission STUCK/RUNTIME watchlist)
        "open": [job_summary(j) for j in open_j],
        # Age-filtered open jobs for map seat pulse / ACTIVE chrome
        "activity_open": [job_summary(j) for j in activity_j],
        "recent": [job_summary(j) for j in recent],
        "counts": {
            "open": len(open_j),
            "activity_open": len(activity_j),
            "total": len(all_j),
            "done": sum(1 for j in all_j if j.get("status") == "done"),
            "failed": sum(1 for j in all_j if j.get("status") == "failed"),
            "by_status": by_status,
        },
    }

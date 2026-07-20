"""Canonical constants + validation for the control plane."""

from __future__ import annotations

from typing import Any, Iterable

# Pair / job document schema
SCHEMA_VERSION = 2

# Snapshot envelope for UI consumers — bump when snapshot shape breaks
CONTRACT_VERSION = 1

JOB_STATUSES = (
    "queued",
    "notified",
    "running",
    "done",
    "failed",
    "rejected",
    "human_takeover",
    "cancelled",
)

TERMINAL_STATUSES = frozenset(
    {"done", "failed", "rejected", "cancelled", "human_takeover"}
)

# from_status -> allowed next statuses
TRANSITIONS: dict[str, frozenset[str]] = {
    # done allowed from queued: job file only (no notify) still completable via claim
    "queued": frozenset(
        {"notified", "running", "cancelled", "failed", "human_takeover", "done", "rejected"}
    ),
    "notified": frozenset(
        {"running", "cancelled", "failed", "done", "human_takeover", "rejected"}
    ),
    "running": frozenset({"done", "failed", "rejected", "human_takeover", "cancelled"}),
    "done": frozenset(),
    "failed": frozenset(),
    "rejected": frozenset(),
    "cancelled": frozenset(),
    # human may return control or finish
    "human_takeover": frozenset({"running", "done", "cancelled", "failed", "rejected"}),
}

CONDUCTOR_TYPES = frozenset({"grok", "hermes", "claude", "custom"})
TRANSPORT_DEFAULTS = frozenset(
    {"job", "job_file", "job+paste", "paste", "tmux", "window", "headless", "cli"}
)

EVENT_TYPES = frozenset(
    {
        "job.created",
        "job.status",
        "job.claim",
        "job.dispatch",
        "verdict",
        "pair.saved",
        "bridge.gate",
        "system",
        "route.refused",
        "brief.sent",
    }
)


class SchemaError(ValueError):
    pass


def assert_job_status(status: str) -> str:
    if status not in JOB_STATUSES:
        raise SchemaError(f"invalid job status {status!r}; want one of {JOB_STATUSES}")
    return status


def can_transition(from_status: str, to_status: str) -> bool:
    if from_status == to_status:
        return True
    allowed = TRANSITIONS.get(from_status, frozenset())
    return to_status in allowed


def assert_transition(from_status: str, to_status: str) -> None:
    assert_job_status(from_status)
    assert_job_status(to_status)
    if not can_transition(from_status, to_status):
        raise SchemaError(
            f"illegal job transition {from_status!r} → {to_status!r}; "
            f"allowed={sorted(TRANSITIONS.get(from_status, frozenset()))}"
        )


def validate_job(job: dict[str, Any], *, partial: bool = False) -> list[str]:
    """Return list of problems (empty = ok)."""
    errs: list[str] = []
    if not partial:
        for key in ("id", "session", "worker", "status", "task"):
            if key not in job or job[key] in (None, ""):
                errs.append(f"missing {key}")
    st = job.get("status")
    if st is not None:
        try:
            assert_job_status(str(st))
        except SchemaError as e:
            errs.append(str(e))
    return errs


def validate_pair(pair: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    c = pair.get("conductor")
    if not isinstance(c, dict):
        errs.append("conductor must be object")
    else:
        if not c.get("type"):
            errs.append("conductor.type required")
        elif str(c.get("type")) not in CONDUCTOR_TYPES and str(c.get("type")) != "custom":
            # allow unknown custom types as custom-like
            pass
    ws = pair.get("workers")
    if ws is not None and not isinstance(ws, list):
        errs.append("workers must be array")
    elif isinstance(ws, list):
        ids: list[str] = []
        for i, w in enumerate(ws):
            if not isinstance(w, dict):
                errs.append(f"workers[{i}] not object")
                continue
            wid = str(w.get("id") or "")
            if not wid:
                errs.append(f"workers[{i}].id required")
            elif wid in ids:
                errs.append(f"duplicate worker id {wid}")
            else:
                ids.append(wid)
    td = pair.get("transport_default")
    if td is not None and str(td) not in TRANSPORT_DEFAULTS:
        errs.append(f"unknown transport_default {td!r}")
    return errs


def task_preview(task: str, n: int = 80) -> str:
    t = (task or "").replace("\n", " ").strip()
    if len(t) <= n:
        return t
    return t[: n - 1] + "…"


def job_summary(job: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": job.get("id"),
        "worker": job.get("worker"),
        "status": job.get("status"),
        "round": job.get("round", 1),
        "task_preview": task_preview(str(job.get("task") or "")),
        "created_at": job.get("created_at"),
        "updated_at": job.get("updated_at"),
        "human_takeover": bool(job.get("human_takeover")),
        "worker_type": job.get("worker_type"),
        "worker_label": job.get("worker_label"),
    }

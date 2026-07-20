"""Ephemeral subagents — appear on the 3D map while active, vanish when done.

Sources (union):
1. Open jobs with parent_worker / ephemeral_seat / kind=subagent
2. Session registry file: ~/.pong/sessions/<session>/active-subs.json

CLI:
  pong subagent up   --parent w1 --label "Explore auth"
  pong subagent down <id>
  pong job create --parent w1 --ephemeral -t "…"
"""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import Any

from .jsonutil import read_json, write_json
from .paths import ensure_layout, sessions_dir
from .schema import TERMINAL_STATUSES


def registry_path(session: str) -> Path:
    return sessions_dir(session) / "active-subs.json"


def load_registry(session: str) -> list[dict[str, Any]]:
    ensure_layout(session)
    data = read_json(registry_path(session)) or {}
    rows = data.get("subs") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        return []
    return [r for r in rows if isinstance(r, dict) and r.get("id")]


def save_registry(session: str, rows: list[dict[str, Any]]) -> None:
    ensure_layout(session)
    write_json(
        registry_path(session),
        {"subs": rows, "updated_at": time.time()},
    )


def register(
    session: str,
    *,
    parent_id: str,
    label: str,
    task: str = "",
    sub_id: str | None = None,
    mission_role: str = "coder",
) -> dict[str, Any]:
    """Mark a live subagent under parent. Returns the registry row."""
    parent_id = (parent_id or "").strip()
    if not parent_id:
        raise ValueError("parent_id required")
    label = (label or task or "Subagent").strip()[:48]
    sid = (sub_id or f"eph_{uuid.uuid4().hex[:8]}").strip()
    rows = [r for r in load_registry(session) if r.get("id") != sid]
    row = {
        "id": sid,
        "parent_id": parent_id,
        "label": label,
        "task": (task or label).strip()[:200],
        "mission_role": mission_role or "coder",
        "status": "busy",
        "created_at": time.time(),
        "updated_at": time.time(),
        "source": "registry",
    }
    rows.append(row)
    save_registry(session, rows)
    return row


def unregister(session: str, sub_id: str) -> bool:
    """Remove a registry subagent. Returns True if something was removed."""
    before = load_registry(session)
    after = [r for r in before if r.get("id") != sub_id]
    if len(after) == len(before):
        # also allow job-id style: eph_job_…
        after = [r for r in before if r.get("job_id") != sub_id and r.get("id") != f"eph_{sub_id}"]
    if len(after) == len(before):
        return False
    save_registry(session, after)
    return True


def _task_preview(task: str, n: int = 40) -> str:
    t = (task or "").replace("\n", " ").strip()
    if len(t) <= n:
        return t
    return t[: n - 1] + "…"


def collect_ephemeral_subs(
    session: str,
    *,
    permanent_ids: set[str],
    open_job_list: list[dict[str, Any]],
    conductor_id: str = "c1",
) -> list[dict[str, Any]]:
    """Build the list of live subagent seats for the UI snapshot.

    Each item: id, parent_id, label, status, task_preview, mission_role, job_id?, source
    """
    by_id: dict[str, dict[str, Any]] = {}

    # 1) Registry marks (manual / agent-reported)
    for r in load_registry(session):
        pid = str(r.get("parent_id") or conductor_id)
        sid = str(r.get("id"))
        by_id[sid] = {
            "id": sid,
            "parent_id": pid,
            "label": str(r.get("label") or "Subagent")[:48],
            "status": str(r.get("status") or "busy"),
            "task_preview": _task_preview(str(r.get("task") or r.get("label") or "")),
            "mission_role": str(r.get("mission_role") or "coder"),
            "job_id": r.get("job_id"),
            "source": "registry",
            "ephemeral": True,
        }

    # 2) Open jobs that declare a parent / ephemeral seat
    for j in open_job_list:
        if j.get("status") in TERMINAL_STATUSES:
            continue
        jid = str(j.get("id") or "")
        worker = str(j.get("worker") or "")
        parent = (
            j.get("parent_worker")
            or j.get("spawned_by")
            or j.get("parent_id")
            or j.get("parent")
        )
        kind = str(j.get("kind") or j.get("role") or "").lower()
        eph_flag = bool(j.get("ephemeral_seat") or j.get("ephemeral"))
        foreign_worker = bool(worker) and worker not in permanent_ids

        is_sub = eph_flag or kind in ("subagent", "sub", "task", "spawn") or foreign_worker
        if not is_sub:
            continue

        parent_id = str(parent or (worker if worker in permanent_ids else conductor_id))
        # If job is assigned to a permanent worker but marked subagent of another, use parent field
        if parent:
            parent_id = str(parent)
        elif foreign_worker:
            parent_id = str(conductor_id)

        sid = f"eph_{jid}" if jid else f"eph_{uuid.uuid4().hex[:8]}"
        label = str(j.get("worker_label") or j.get("label") or _task_preview(str(j.get("task") or "Sub"), 28))
        by_id[sid] = {
            "id": sid,
            "parent_id": parent_id,
            "label": label[:48],
            "status": "busy" if j.get("status") != "human_takeover" else "human",
            "task_preview": _task_preview(str(j.get("task") or "")),
            "mission_role": str(j.get("mission_role") or j.get("role") or "coder"),
            "job_id": jid,
            "source": "job",
            "ephemeral": True,
        }

    return sorted(by_id.values(), key=lambda r: (r.get("parent_id") or "", r.get("id") or ""))

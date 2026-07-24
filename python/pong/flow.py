"""Architecture / flow_graph enforcement.

The Architecture UI stores intent edges on the team:

  flow_graph.edges = [{ from, to, kind, dir, label, id }, …]

Kinds used by the map:
  delegate — orch → agent
  sub      — parent agent → subagent
  claim    — worker → orch (or parent) for results
  peer / review — lateral

Until this module, edges were decorative: conductors could job-create any seat
and claims never notified the claim target. Enforcement is fail-closed when a
non-empty graph is present.
"""

from __future__ import annotations

import os
from typing import Any

from .routing import refuse


FORWARD_KINDS = frozenset({"delegate", "sub", "peer", "review", ""})
CLAIM_KINDS = frozenset({"claim"})


def conductor_id(state: dict[str, Any]) -> str:
    from .state import conductor_from_state

    c = conductor_from_state(state)
    return str(c.get("id") or "c1")


def load_edges(state: dict[str, Any]) -> list[dict[str, Any]]:
    raw = state.get("flow_graph")
    if not isinstance(raw, dict):
        return []
    edges = raw.get("edges")
    if not isinstance(edges, list):
        return []
    out: list[dict[str, Any]] = []
    for e in edges:
        if not isinstance(e, dict):
            continue
        fr = str(e.get("from") or "").strip()
        to = str(e.get("to") or "").strip()
        if not fr or not to:
            continue
        kind = str(e.get("kind") or "delegate").strip().lower()
        out.append(
            {
                "from": fr,
                "to": to,
                "kind": kind,
                "dir": str(e.get("dir") or "forward"),
                "id": str(e.get("id") or f"{fr}>{to}"),
                "label": e.get("label"),
            }
        )
    return out


def default_edges_from_state(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Mirror Swift FlowGraph.defaultEdges when stored graph is empty.

    Used so architecture is always a real road (guardrails), not optional decor.
    """
    from .state import workers_from_state

    cond = conductor_id(state)
    workers = list(workers_from_state(state))
    edges: list[dict[str, Any]] = []
    for w in workers:
        wid = str(w.get("id") or "w1")
        parent = str(w.get("parent_id") or "").strip()
        if parent:
            edges.append(
                {
                    "from": parent,
                    "to": wid,
                    "kind": "sub",
                    "dir": "forward",
                    "id": f"{parent}>{wid}:sub",
                }
            )
            edges.append(
                {
                    "from": wid,
                    "to": parent,
                    "kind": "claim",
                    "dir": "forward",
                    "id": f"{wid}>{parent}:claim",
                }
            )
        else:
            edges.append(
                {
                    "from": cond,
                    "to": wid,
                    "kind": "delegate",
                    "dir": "forward",
                    "id": f"{cond}>{wid}:delegate",
                }
            )
            edges.append(
                {
                    "from": wid,
                    "to": cond,
                    "kind": "claim",
                    "dir": "forward",
                    "id": f"{wid}>{cond}:claim",
                }
            )
    tops = [
        str(w.get("id") or "")
        for w in workers
        if not str(w.get("parent_id") or "").strip()
    ]
    tops = [t for t in tops if t]
    for i in range(max(0, len(tops) - 1)):
        a, b = tops[i], tops[i + 1]
        edges.append(
            {
                "from": a,
                "to": b,
                "kind": "peer",
                "dir": "forward",
                "id": f"{a}>{b}:peer",
            }
        )
    return edges


def effective_edges(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Stored edges if non-empty, else default topology. Always a road."""
    edges = load_edges(state)
    if edges:
        return edges
    return default_edges_from_state(state)


def caller_seat(state: dict[str, Any]) -> str:
    """Who is creating the job — PONG_SEAT, conductor role, else c1."""
    seat = (os.environ.get("PONG_SEAT") or "").strip()
    if seat:
        return seat
    role = (os.environ.get("PONG_ROLE") or os.environ.get("HERMES_PONG_ROLE") or "").strip().lower()
    if role in ("conductor", "orchestra", "orchestrator"):
        return conductor_id(state)
    # Default: treat as conductor (CLI from outside a seat still routes from orch)
    return conductor_id(state)


def _has_forward_edge(edges: list[dict[str, Any]], src: str, dst: str) -> bool:
    for e in edges:
        if e["from"] != src or e["to"] != dst:
            continue
        if e.get("dir") == "back":
            continue
        if e["kind"] in CLAIM_KINDS:
            continue  # claim edges are return path, not assign path
        return True
    return False


def _parents_of(edges: list[dict[str, Any]], dst: str) -> list[str]:
    parents: list[str] = []
    for e in edges:
        if e["to"] != dst:
            continue
        if e.get("dir") == "back":
            continue
        if e["kind"] in CLAIM_KINDS:
            continue
        if e["from"] not in parents:
            parents.append(e["from"])
    return parents


def assert_assign_allowed(
    state: dict[str, Any],
    worker_id: str,
    *,
    from_seat: str | None = None,
) -> None:
    """Refuse job create that steps off the architecture road.

    Always enforces using *effective* edges (stored graph, or default topology
    when empty). The flow is a hard road — not decorative.
    """
    edges = effective_edges(state)
    if not edges:
        # No seats at all — nothing to enforce
        return

    src = (from_seat or caller_seat(state)).strip()
    dst = str(worker_id).strip()
    if not dst:
        return
    if src == dst:
        refuse(
            f"flow refused — cannot assign job from {src} to itself",
            reason="flow_self_assign",
        )

    if _has_forward_edge(edges, src, dst):
        return

    parents = _parents_of(edges, dst)
    cond = conductor_id(state)
    if parents:
        hop = ", ".join(parents)
        refuse(
            f"flow refused — no architecture edge {src}→{dst}. "
            f"Stay on the road: route via {hop} first. "
            f"Example: assign to {parents[0]}, then that seat assigns to {dst}.",
            reason="flow_hop_required",
            target=dst,
            caller=src,
        )

    known = {e["from"] for e in edges} | {e["to"] for e in edges}
    if dst not in known:
        refuse(
            f"flow refused — seat {dst!r} is not on the architecture road "
            f"(known seats: {sorted(known)}). Add a link in Architecture first.",
            reason="flow_unknown_seat",
            target=dst,
            caller=src,
        )

    refuse(
        f"flow refused — no forward edge {src}→{dst} in architecture. "
        f"You may only assign along the road from this seat: "
        + ", ".join(
            sorted({e["to"] for e in edges if e["from"] == src and e["kind"] not in CLAIM_KINDS})
            or ["(none)"]
        )
        + (f". Conductor is {cond}." if src != cond else ""),
        reason="flow_no_edge",
        target=dst,
        caller=src,
    )


def claim_notify_targets(state: dict[str, Any], worker_id: str) -> list[str]:
    """Seats that should receive a claim notification (claim edges worker→seat).

    Uses effective edges so claim path is always defined.
    """
    edges = effective_edges(state)
    wid = str(worker_id).strip()
    if not edges:
        return [conductor_id(state)]
    targets: list[str] = []
    for e in edges:
        if e["from"] != wid:
            continue
        if e["kind"] in CLAIM_KINDS or e.get("dir") == "back":
            t = e["to"]
            if t not in targets:
                targets.append(t)
    # Also reverse of delegate/sub if no explicit claim edge (common incomplete graphs)
    if not targets:
        for e in edges:
            if e["to"] == wid and e["kind"] in FORWARD_KINDS:
                t = e["from"]
                if t not in targets:
                    targets.append(t)
    if not targets:
        targets = [conductor_id(state)]
    return targets


def notify_claim(
    state: dict[str, Any],
    job: dict[str, Any],
    claim: dict[str, Any],
) -> list[str]:
    """Paste a short claim recap into claim-edge targets (usually the orchestrator).

    Best-effort: never raises. Returns list of seat ids we attempted.
    """
    session = str(job.get("session") or state.get("session") or "")
    worker = str(job.get("worker") or "")
    if not session or not worker:
        return []
    targets = claim_notify_targets(state, worker)
    summary = (claim.get("summary") or claim.get("raw") or "").strip()
    if not summary:
        summary = f"(claim recorded for job {job.get('id')})"
    files = claim.get("files") or []
    files_s = ", ".join(str(f) for f in files[:8]) if files else "—"
    text = (
        f"\n—— CLAIM · {worker} · {job.get('id')} ——\n"
        f"{summary}\n"
        f"files: {files_s}\n"
        f"(job file is source of truth; run acceptance before ledger verdict)\n"
    )
    workers = {str(w.get("id")): w for w in _all_seats(state)}
    attempted: list[str] = []
    for tid in targets:
        seat = workers.get(tid) or {"id": tid}
        # Conductor seat may only live under conductor key
        if tid == conductor_id(state):
            from .state import conductor_from_state

            seat = dict(conductor_from_state(state))
            seat.setdefault("id", tid)
        attempted.append(tid)
        try:
            from .transports import tmux_paste

            job_proxy = {
                "session": session,
                "worker": tid,
                "_prompt": text,
            }
            r = tmux_paste.send(job_proxy, seat, state)
            if not r.ok:
                # Fall back: paste into base session window by tmux index
                _paste_by_index(session, seat, text)
        except Exception:
            try:
                _paste_by_index(session, seat, text)
            except Exception:
                pass
    try:
        from . import events

        events.emit(
            "claim.notified",
            session=session,
            job_id=str(job.get("id")),
            worker=worker,
            targets=attempted,
        )
    except Exception:
        pass
    return attempted


def _all_seats(state: dict[str, Any]) -> list[dict[str, Any]]:
    from .state import conductor_from_state, workers_from_state

    seats = list(workers_from_state(state))
    c = conductor_from_state(state)
    if c:
        seats.append(c)
    return seats


def _paste_by_index(session: str, seat: dict[str, Any], text: str) -> None:
    import subprocess
    import time

    idx = seat.get("tmux_index")
    if idx is None:
        sid = str(seat.get("id") or "")
        if sid in ("c1", "hermes"):
            idx = 0
        elif sid.startswith("w") and sid[1:].isdigit():
            idx = int(sid[1:])
        else:
            return
    target = f"{session}:{int(idx)}"
    try:
        subprocess.run(
            ["tmux", "load-buffer", "-"],
            input=text,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        subprocess.run(
            ["tmux", "paste-buffer", "-t", target, "-d"],
            capture_output=True,
            timeout=10,
            check=False,
        )
        time.sleep(0.1)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except Exception:
        pass

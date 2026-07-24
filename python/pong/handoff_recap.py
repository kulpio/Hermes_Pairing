"""Architecture-aware handoff recaps for job prompts.

Built from live ``flow_graph`` edges (or implicit defaults matching Swift
``FlowGraph.defaultEdges``). Injected into every job wrapper so seats know
where to claim and whom they may assign next.
"""

from __future__ import annotations

from typing import Any

from .flow import (
    CLAIM_KINDS,
    FORWARD_KINDS,
    conductor_id,
    default_edges_from_state,
    effective_edges,
)

# Re-export for callers/tests that imported from this module
__all__ = [
    "architecture_recap_for_seat",
    "default_edges_from_state",
    "effective_edges",
]


def _workers(state: dict[str, Any]) -> list[dict[str, Any]]:
    from .state import workers_from_state

    return list(workers_from_state(state))


def _seat_label(state: dict[str, Any], seat_id: str) -> str:
    from .state import conductor_from_state

    if seat_id == conductor_id(state):
        c = conductor_from_state(state)
        return str(c.get("label") or seat_id)
    for w in _workers(state):
        if str(w.get("id")) == seat_id:
            return str(w.get("label") or seat_id)
    return seat_id


def _mission_role(state: dict[str, Any], seat_id: str) -> str:
    from .role_identity import seat_mission_role

    return seat_mission_role(state, seat_id)


def architecture_recap_for_seat(
    state: dict[str, Any],
    seat_id: str,
    *,
    max_lines: int = 28,
) -> str:
    """Short imperative recap for *seat_id* based on architecture edges."""
    sid = str(seat_id or "").strip()
    if not sid:
        return ""
    edges = effective_edges(state)
    role = _mission_role(state, sid)
    label = _seat_label(state, sid)

    claim_targets: list[str] = []
    assign_targets: list[str] = []
    peer_targets: list[str] = []
    review_targets: list[str] = []
    inbound_from: list[str] = []

    for e in edges:
        fr, to, kind = e["from"], e["to"], e["kind"]
        if fr == sid:
            if kind in CLAIM_KINDS:
                if to not in claim_targets:
                    claim_targets.append(to)
            elif kind == "peer":
                if to not in peer_targets:
                    peer_targets.append(to)
            elif kind == "review":
                if to not in review_targets:
                    review_targets.append(to)
            elif kind in FORWARD_KINDS or kind in ("delegate", "sub", ""):
                if to not in assign_targets:
                    assign_targets.append(to)
        if to == sid and kind not in CLAIM_KINDS:
            if fr not in inbound_from:
                inbound_from.append(fr)

    if not claim_targets:
        for e in edges:
            if e["to"] == sid and e["kind"] in FORWARD_KINDS:
                if e["from"] not in claim_targets:
                    claim_targets.append(e["from"])
    if not claim_targets and sid != conductor_id(state):
        claim_targets = [conductor_id(state)]

    lines: list[str] = [
        f"## ARCHITECTURE HANDOFF (seat {sid})",
        f"You are **{sid}** · {label} · role={role}.",
        "These hops are the **only** legal roads (control plane enforces them):",
    ]

    for t in claim_targets:
        tlab = _seat_label(state, t)
        lines.append(f"- ** Send claim to {t} ** ({tlab}) when the job is done.")

    for t in assign_targets:
        tlab = _seat_label(state, t)
        kind_hint = next(
            (
                e["kind"]
                for e in edges
                if e["from"] == sid and e["to"] == t and e["kind"] not in CLAIM_KINDS
            ),
            "delegate",
        )
        lines.append(
            f"- ** May assign jobs to {t} ** ({tlab}, {kind_hint}) — only this hop."
        )

    for t in peer_targets:
        tlab = _seat_label(state, t)
        lines.append(f"- ** Peer handoff to {t} ** ({tlab}) when the job says so.")

    for t in review_targets:
        tlab = _seat_label(state, t)
        lines.append(f"- ** Send review to {t} ** ({tlab}).")

    if not assign_targets and not peer_targets:
        lines.append(
            "- ** No outbound assign edges ** — do the work and claim; do not invent routing."
        )

    if inbound_from:
        srcs = ", ".join(f"{s} ({_seat_label(state, s)})" for s in inbound_from[:6])
        lines.append(f"- Jobs usually arrive from: {srcs}.")

    if sid == conductor_id(state):
        lines.append(
            "- Orchestrate **only** along architecture edges; hop-skips are refused."
        )

    lines.append(
        "- Leaving this road (wrong seat, skip hop, freestyle peer) is a **STOP**, not a shortcut."
    )

    if len(lines) > max_lines:
        lines = lines[: max_lines - 1] + ["- …(recap truncated)"]

    return "\n".join(lines) + "\n"

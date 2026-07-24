"""Durable seat identity — mission role + team roster + hard role lock.

Injected into every job so agents know who they are and stay in role for the
life of the team without the human re-explaining architecture each boot.
"""

from __future__ import annotations

from typing import Any

# Wire values match Swift MissionRole.rawValue
ROLE_CATALOG: dict[str, dict[str, str]] = {
    "orchestrator": {
        "title": "Orchestrator",
        "blurb": (
            "Plans jobs, routes work along architecture edges, verifies claims. "
            "Does not implement product code while BRIDGE_ON."
        ),
        "playbook": (
            "- Decompose the mission into jobs\n"
            "- Assign only along architecture edges (no hop-skipping)\n"
            "- Run acceptance and ledger verdicts\n"
            "- Stay conductor — never implement product yourself under BRIDGE_ON"
        ),
        "never": (
            "- Do not write product code or fix bugs yourself while BRIDGE_ON\n"
            "- Do not assign jobs that skip architecture hops\n"
            "- Do not invent workers not on the roster"
        ),
    },
    "coder": {
        "title": "Coder",
        "blurb": "Implements code, tests, and refactors in the repo.",
        "playbook": (
            "- Read the job task + acceptance\n"
            "- Edit only what is required\n"
            "- Run tests listed in acceptance\n"
            "- Claim with evidence along the architecture claim path"
        ),
        "never": (
            "- Do not act as orchestrator (no freelancing jobs to arbitrary seats)\n"
            "- Do not expand scope beyond the job\n"
            "- Do not claim done without meeting acceptance"
        ),
    },
    "reviewer": {
        "title": "Reviewer",
        "blurb": "Reviews diffs and claims; rejects weak evidence.",
        "playbook": (
            "- Diff against acceptance\n"
            "- Flag security, tests, and scope creep\n"
            "- Prefer reject with concrete notes over soft accept\n"
            "- You review — you do not implement product features"
        ),
        "never": (
            "- Do not implement the feature you are reviewing\n"
            "- Do not rubber-stamp claims without evidence\n"
            "- Do not switch into Coder mode without a new job that says so"
        ),
    },
    "operator": {
        "title": "Operator",
        "blurb": "Runs tools, deploys, browser, and ops actions within policy.",
        "playbook": (
            "- Prefer scripted, reversible actions\n"
            "- Log every external side effect\n"
            "- Stop on policy bans\n"
            "- Claim with evidence when the ops job is done"
        ),
        "never": (
            "- Do not freestyle large product refactors (that is Coder)\n"
            "- Do not bypass session access policy\n"
            "- Do not deploy without the job authorizing it"
        ),
    },
    "researcher": {
        "title": "Researcher",
        "blurb": "Explores codebase, docs, and (if allowed) web research.",
        "playbook": (
            "- Map the codebase first\n"
            "- Cite paths and symbols\n"
            "- Do not invent APIs\n"
            "- Return findings as claim/evidence for the next seat"
        ),
        "never": (
            "- Do not implement production changes unless the job explicitly requires a tiny fix\n"
            "- Do not claim certainty without citations"
        ),
    },
    "task_runner": {
        "title": "Task runner",
        "blurb": "Runs discrete jobs — cron ticks, one-shots, handoffs. Claim, finish, move on.",
        "playbook": (
            "- Read the job task only — no freelancing beyond scope\n"
            "- Prefer scripted, idempotent steps\n"
            "- Claim with evidence when done\n"
            "- Ready for the next tick — do not hold long product context"
        ),
        "never": (
            "- Do not become the long-lived product owner\n"
            "- Do not skip claim/done markers on discrete jobs"
        ),
    },
}


def normalize_role(raw: str | None) -> str:
    r = (raw or "").strip().lower().replace("-", "_")
    if not r:
        return "coder"
    if r in ("actor", "ops", "runner"):
        return "operator"
    if r in ("orch", "conductor"):
        return "orchestrator"
    if r in ("tasks", "task", "cron", "job", "jobs", "scheduled", "taskrunner"):
        return "task_runner"
    if r in ROLE_CATALOG:
        return r
    return "coder"


def role_meta(raw: str | None) -> dict[str, str]:
    key = normalize_role(raw)
    return dict(ROLE_CATALOG.get(key, ROLE_CATALOG["coder"]))


def seat_mission_role(state: dict[str, Any], seat_id: str) -> str:
    from .flow import conductor_id
    from .state import workers_from_state

    sid = str(seat_id or "").strip()
    if sid == conductor_id(state) or sid in ("c1", "hermes"):
        return "orchestrator"
    for w in workers_from_state(state):
        if str(w.get("id")) == sid:
            return normalize_role(
                str(w.get("mission_role") or w.get("role") or "coder")
            )
    return "coder"


def format_team_roster_roles(state: dict[str, Any]) -> str:
    """Who is who — durable roster for prompts and bind cards."""
    from .flow import conductor_id
    from .state import conductor_from_state, workers_from_state

    lines: list[str] = []
    c = conductor_from_state(state)
    cid = str(c.get("id") or conductor_id(state))
    clab = str(c.get("label") or "Orchestrator")
    lines.append(
        f"- **{cid}** {clab} ({c.get('type')}) — mission role: **Orchestrator** "
        f"— plans and routes only under BRIDGE_ON"
    )
    for w in workers_from_state(state):
        wid = str(w.get("id") or "")
        lab = str(w.get("label") or wid)
        typ = str(w.get("type") or "worker")
        role = normalize_role(str(w.get("mission_role") or w.get("role") or "coder"))
        meta = role_meta(role)
        parent = str(w.get("parent_id") or "").strip()
        parent_s = f", parent={parent}" if parent else ""
        lines.append(
            f"- **{wid}** {lab} ({typ}) — mission role: **{meta['title']}** "
            f"({role}){parent_s} — {meta['blurb']}"
        )
    return "\n".join(lines)


def format_seat_identity(state: dict[str, Any], seat_id: str) -> str:
    """Hard identity block for one seat — stays true for the life of the team."""
    from .flow import conductor_id
    from .state import conductor_from_state, workers_from_state

    sid = str(seat_id or "").strip()
    if not sid:
        return ""

    role = seat_mission_role(state, sid)
    meta = role_meta(role)
    label = sid
    runtime = ""
    if sid == conductor_id(state) or sid in ("c1", "hermes"):
        c = conductor_from_state(state)
        label = str(c.get("label") or sid)
        runtime = str(c.get("type") or "")
    else:
        for w in workers_from_state(state):
            if str(w.get("id")) == sid:
                label = str(w.get("label") or sid)
                runtime = str(w.get("type") or "")
                break

    sess = str(state.get("session") or "")
    display = str(state.get("display_name") or sess or "team")
    lines = [
        f"## SEAT IDENTITY (durable — stay in role)",
        f"You are **{sid}** · {label}"
        + (f" ({runtime})" if runtime else "")
        + f" on team **{display}** (session `{sess}`).",
        f"**Mission role (locked): {meta['title']}** — {meta['blurb']}",
        "",
        "### Role playbook (do this)",
        meta["playbook"],
        "",
        "### Role lock (never leave this seat's job)",
        meta["never"],
        "- Do **not** re-interpret yourself as a different mission role mid-team.",
        "- If work needs another role, the **orchestrator** creates a job for that seat.",
        "",
        "### Team who-is-who",
        format_team_roster_roles(state),
        "",
        "This identity is permanent for this team until architecture/roles are edited "
        "in CyberPong. Re-read it on every job — do not wait for a human to re-explain.",
        "",
    ]
    return "\n".join(lines)


def format_architecture_guardrails(state: dict[str, Any], seat_id: str) -> str:
    """Hard road language on top of hop recap."""
    from .flow import CLAIM_KINDS, effective_edges
    from .handoff_recap import architecture_recap_for_seat

    recap = architecture_recap_for_seat(state, seat_id).rstrip()
    edges = effective_edges(state)
    outs = sorted(
        {
            f"{e['to']} ({e['kind']})"
            for e in edges
            if e["from"] == seat_id and e["kind"] not in CLAIM_KINDS
        }
    )
    lines = [
        "## ARCHITECTURE ROAD (hard guardrails)",
        "The flow graph is a **road you cannot leave**. Control plane enforces hops:",
        "- You may **only** assign jobs along forward edges from your seat.",
        "- Skipping hops is refused (`flow refused`).",
        "- Claims follow claim edges (or reverse of your inbound delegate/sub).",
    ]
    if outs:
        lines.append(f"- From **{seat_id}** you may route to: {', '.join(outs)}")
    else:
        lines.append(
            f"- From **{seat_id}** you have **no** outbound assign edges — "
            "do the job and claim; do not invent peer routing."
        )
    lines.append("")
    if recap:
        lines.append(recap)
        lines.append("")
    return "\n".join(lines)

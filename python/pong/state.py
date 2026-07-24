"""Team / pair state, binding, workers, conductors."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION
from .jsonutil import read_json, write_json
from .paths import (
    active_path,
    binds_dir,
    briefs_dir,
    ensure_layout,
    pairs_path,
    sessions_dir,
    state_dir,
)

PAIR_BASE_RE = re.compile(
    r"^(pong-team(?:-\d+)?|hermes-pair(?:-\d+)?|hermes-claude(?:-\d+)?)$"
)
VIEW_SUFFIX_RE = re.compile(r"-(?:h|c|w\d+)$")

DONE_MARKERS = {
    "claude": "##CLAUDE_DONE##",
    "default": "##WORKER_DONE##",
}


class WorkerResolveError(Exception):
    pass


def load_pairs_db() -> dict[str, Any]:
    return read_json(pairs_path())


def save_pairs_db(db: dict[str, Any]) -> None:
    write_json(pairs_path(), db)


def load_active() -> dict[str, Any]:
    return read_json(active_path())


def pair_base_from_tmux_name(name: str | None) -> str | None:
    if not name:
        return None
    name = name.strip()
    if PAIR_BASE_RE.match(name):
        return name
    stripped = VIEW_SUFFIX_RE.sub("", name)
    if stripped != name and PAIR_BASE_RE.match(stripped):
        return stripped
    return None


def is_pair_name(name: str) -> bool:
    return pair_base_from_tmux_name(name) == name


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


def detect_bound_session(explicit: str | None = None) -> str | None:
    """Read-oriented session resolution (may fall back to active-pair).

    Mutating ops must use ``routing.resolve_write_session`` instead — that path
    never falls back to active-pair and enforces per-session tokens (Addendum 2).
    """
    if explicit and explicit.strip():
        return explicit.strip()
    for key in ("PONG_SESSION", "HERMES_PONG_SESSION"):
        v = (os.environ.get(key) or "").strip()
        if v:
            return v
    base = pair_base_from_tmux_name(_tmux_current_session())
    if base:
        return base
    active = load_active()
    sess = active.get("session")
    return str(sess) if sess else None


def load_session_state(session: str | None = None) -> dict[str, Any]:
    sess = detect_bound_session(session)
    if not sess:
        return {}
    db = load_pairs_db()
    entry = db.get(sess)
    if isinstance(entry, dict) and entry:
        state = dict(entry)
        state["session"] = sess
        return normalize_pair_state(state)
    active = load_active()
    if active.get("session") == sess:
        state = dict(active)
        state["session"] = sess
        return normalize_pair_state(state)
    return {}


def default_conductor(ctype: str = "grok") -> dict[str, Any]:
    presets = {
        "grok": {"type": "grok", "label": "Grok Build", "cmd": "grok"},
        "hermes": {"type": "hermes", "label": "Hermes", "cmd": "hermes chat"},
        "claude": {"type": "claude", "label": "Claude Code", "cmd": "claude"},
        "custom": {"type": "custom", "label": "Custom", "cmd": ""},
    }
    base = dict(presets.get(ctype, presets["custom"]))
    base.update({"id": "c1", "mode": "tmux", "tmux_index": 0, "window_id": None})
    # User overrides
    cond_path = state_dir() / "conductors.json"
    row = read_json(cond_path).get(ctype)
    if isinstance(row, dict):
        if row.get("cmd"):
            base["cmd"] = row["cmd"]
        if row.get("label"):
            base["label"] = row["label"]
    return base


def workers_from_state(state: dict[str, Any]) -> list[dict[str, Any]]:
    arr = state.get("workers")
    if isinstance(arr, list) and arr:
        out = []
        for i, w in enumerate(arr):
            if not isinstance(w, dict):
                continue
            ww = dict(w)
            ww.setdefault("id", f"w{i + 1}")
            ww.setdefault("type", "claude")
            ww.setdefault("label", ww.get("type", "Worker"))
            ww.setdefault("mode", state.get("claude_mode") or "tmux")
            ww.setdefault("tmux_index", i + 1)
            ww.setdefault(
                "done_marker",
                DONE_MARKERS.get(str(ww.get("type")), DONE_MARKERS["default"]),
            )
            out.append(ww)
        return out
    wid = state.get("claude_window_id") or state.get("worker_window_id")
    if wid in (None, "", "null"):
        return []
    return [
        {
            "id": "w1",
            "type": state.get("worker_type") or "claude",
            "label": state.get("worker_label") or "Worker",
            "window_id": wid,
            "mode": state.get("claude_mode") or "tmux",
            "cmd": state.get("worker_cmd") or "claude",
            "tmux_index": 1,
            "done_marker": DONE_MARKERS.get(
                str(state.get("worker_type") or "claude"), DONE_MARKERS["default"]
            ),
        }
    ]


def conductor_from_state(state: dict[str, Any]) -> dict[str, Any]:
    c = state.get("conductor")
    if isinstance(c, dict) and c.get("type"):
        out = default_conductor(str(c.get("type")))
        out.update({k: v for k, v in c.items() if v is not None})
        return out
    # Legacy: Hermes was always the hub
    out = default_conductor("hermes")
    out["window_id"] = state.get("hermes_window_id") or state.get("conductor_window_id")
    out["label"] = state.get("conductor_label") or out["label"]
    return out


def normalize_pair_state(state: dict[str, Any]) -> dict[str, Any]:
    """Upgrade v1 → v2 shape in memory."""
    s = dict(state)
    s["schema_version"] = max(int(s.get("schema_version") or 1), SCHEMA_VERSION)
    workers = workers_from_state(s)
    s["workers"] = workers
    s["conductor"] = conductor_from_state(s)
    # Compat mirrors
    c = s["conductor"]
    if c.get("window_id") not in (None, "", "null"):
        s["hermes_window_id"] = c["window_id"]
        s["conductor_window_id"] = c["window_id"]
    if workers:
        w0 = workers[0]
        s["claude_window_id"] = w0.get("window_id")
        s["worker_window_id"] = w0.get("window_id")
        s["worker_type"] = w0.get("type")
        s["worker_label"] = w0.get("label")
        s["worker_cmd"] = w0.get("cmd")
        s["claude_mode"] = w0.get("mode") or "tmux"
    # File-first handoffs; paste remains optional notify
    # job+paste: always write job file AND paste into Claude's tmux pane so the
    # human-visible TUI shows the handoff (job-only left Claude "idle" on the bridge).
    s.setdefault("transport_default", "job+paste")
    s.setdefault("autonomy_level", "full")
    # flow_graph: editable topology (UI); missing ⇒ consumers default conductor→workers
    if "flow_graph" not in s:
        s["flow_graph"] = {"edges": []}
    return s


def format_team_roster(state: dict[str, Any]) -> str:
    c = conductor_from_state(state)
    parts = [f"conductor={c.get('id')}:{c.get('label')}({c.get('type')})"]
    for w in workers_from_state(state):
        parts.append(f"{w.get('id')}={w.get('label')}({w.get('type')})")
    return " ".join(parts)


def resolve_worker(state: dict[str, Any], key: str | None) -> dict[str, Any]:
    workers = workers_from_state(state)
    if not workers:
        raise WorkerResolveError("no workers on this team")
    if not key or not str(key).strip():
        return workers[0]
    k = str(key).strip().lower()
    matches: list[dict[str, Any]] = []
    for w in workers:
        ids = {
            str(w.get("id", "")).lower(),
            str(w.get("type", "")).lower(),
            str(w.get("label", "")).lower(),
        }
        if k in ids:
            matches.append(w)
            continue
        # 1-based index
        if k.isdigit():
            idx = int(k)
            if 1 <= idx <= len(workers) and w is workers[idx - 1]:
                matches.append(w)
    # unique by id
    by_id: dict[str, dict[str, Any]] = {}
    for m in matches:
        by_id[str(m.get("id"))] = m
    uniq = list(by_id.values())
    if len(uniq) == 1:
        return uniq[0]
    if len(uniq) == 0:
        roster = format_team_roster(state)
        raise WorkerResolveError(
            f"worker {key!r} not found on this team. roster: {roster}"
        )
    raise WorkerResolveError(
        f"worker {key!r} is ambiguous on this team: "
        + ", ".join(f"{u.get('id')}={u.get('label')}" for u in uniq)
    )


def format_team_context(state: dict[str, Any]) -> str:
    sess = state.get("session") or ""
    root = (state.get("project_root") or "").strip()
    brief = (state.get("team_brief") or "").strip()
    if not root and not brief:
        return ""
    lines = [
        "## TEAM CONTEXT",
        f"- session: {sess}",
    ]
    if root:
        lines.append(f"- project_root: {root}")
    if brief:
        lines.append(f"- team_brief: {brief}")
    lines.append(
        "Treat this as hard scope. Do not work outside project_root. "
        "Another product/repo is a STOP, not a detour."
    )
    lines.append("")
    return "\n".join(lines)


def format_permissions_block(state: dict[str, Any]) -> str:
    perms = state.get("permissions")
    if not isinstance(perms, dict):
        return ""
    bans = []
    if perms.get("ban_mcp"):
        bans.append("no MCP tools")
    if perms.get("ban_root"):
        bans.append("no root/sudo")
    if perms.get("ban_network"):
        bans.append("no network/installs")
    if perms.get("ban_system_paths"):
        bans.append("no system paths (~/.ssh, /etc, keychains)")
    if perms.get("repo_only"):
        bans.append("repo-only file edits")
    if perms.get("ask_each"):
        bans.append("ask before elevated actions")
    note = (perms.get("custom_prompt") or "").strip()
    if not bans and not note:
        return ""
    # North-star: live-layer seat restrictions (not standing grants)
    lines = ["## Session access policy"]
    if bans:
        lines.append("- " + "; ".join(bans))
    if note:
        lines.append(f"- note: {note}")
    lines.append("")
    return "\n".join(lines)


def session_artifact(state: dict[str, Any], name: str) -> Path:
    sess = state.get("session") or "unknown"
    ensure_layout(str(sess))
    return sessions_dir(str(sess)) / name


def write_bind_card(session: str) -> Path:
    ensure_layout(session)
    try:
        from .routing import ensure_session_token

        ensure_session_token(session)
    except Exception:
        pass
    state = load_session_state(session)
    c = conductor_from_state(state)
    display = (state.get("display_name") or session or "").strip()
    lines = [
        f"# Pong bind — {session}",
        "",
        f"- team: {display}",
        f"- conductor: {c.get('label')} (`{c.get('type')}`) cmd=`{c.get('cmd')}` "
        f"role=Orchestrator",
        f"- transport_default: {state.get('transport_default') or 'job+paste'}",
        f"- project_root: {state.get('project_root') or '(unset)'}",
        "",
        "## Who is who (mission roles — durable)",
    ]
    try:
        from .role_identity import format_team_roster_roles

        lines.append(format_team_roster_roles(state))
    except Exception:
        for w in workers_from_state(state):
            lines.append(
                f"- `{w.get('id')}` {w.get('label')} ({w.get('type')}) "
                f"role={w.get('mission_role') or w.get('role') or 'coder'} "
                f"marker={w.get('done_marker')}"
            )
    lines += [
        "",
        "## Architecture road (hard guardrails)",
        "Job assign/claim must follow edges. Hop-skips are refused by `pong job create`.",
        "Print a seat's road: `pong architecture recap --seat <id>`",
        "Print durable identity: `pong seat brief --seat <id>`",
        "",
    ]
    try:
        from .flow import effective_edges

        edges = effective_edges(state)
        if edges:
            for e in edges:
                lines.append(
                    f"- {e['from']} → {e['to']}  ({e.get('kind') or 'delegate'})"
                )
        else:
            lines.append("- (no seats — empty road)")
    except Exception:
        lines.append("- (architecture unavailable)")
    lines += [
        "",
        "## Rules",
        "- You are bound to THIS session only (enforced: PONG_SESSION + PONG_TOKEN).",
        "- Each seat keeps its **mission role** for the life of the team "
        "(coder stays coder, reviewer stays reviewer) unless CyberPong edits it.",
        "- Submit work with: `pong job create --worker <id> --task '…'` "
        "(only along architecture edges from your seat).",
        "- Or: `pong delegate --worker <id> --no-wait '…'`",
        "- Cross-team paste/jobs are refused. Sole inter-team channel: "
        "`pong brief send --to <other-session> '…'` (file inbox, never auto-pasted).",
        "- While bridge is on: orchestrator routes only — do not implement product code yourself.",
        "",
    ]
    path = binds_dir() / f"{session}.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    brief = (state.get("team_brief") or "").strip()
    if brief:
        (briefs_dir() / f"{session}.md").write_text(brief + "\n", encoding="utf-8")
    return path


def gate_text(session: str | None = None) -> tuple[str, int]:
    """Return (stdout_line, exit_code). stderr details printed by CLI."""
    sess = detect_bound_session(session)
    state = load_session_state(sess)
    if not sess or not workers_from_state(state):
        return "BRIDGE_OFF", 0
    if not state.get("session"):
        return f"BRIDGE_UNHEALTHY session={sess!r}", 2
    mode = state.get("claude_mode") or "tmux"
    auto = state.get("autonomy_level") or "full"
    c = conductor_from_state(state)
    return (
        f"BRIDGE_ON session={sess} conductor={c.get('type')} mode={mode} autonomy={auto}",
        0,
    )

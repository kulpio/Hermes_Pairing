#!/usr/bin/env python3
"""
claude-delegate.py / pong-delegate.py — send a task to a Hermes Pong worker.

Team-scoped: the sender is BOUND to one pair session (CLI -s, else env
HERMES_PONG_SESSION, else the surrounding tmux pair, else active-pair.json).
Workers/labels/window ids always come from THAT session's entry in pairs.json
— never from whichever pair happens to be "active". Ambiguous worker keys
fail closed (exit 2) listing this team's roster only.

Phase 2: one Hermes can have multiple workers. Use --worker w1|w2|… (or type id).
Default worker = first in the bound team.

Two modes:
  tmux   — worker in tmux: paste into bound_session:N (tmux_index)
  window — live Terminal: clipboard paste + Return into that window

Always submits with Enter (no silent text sitting in the box).
--dry-run prints bound_session / roster / target / worker and exits 0 without sending.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

MARKER = "##CLAUDE_DONE##"
STATE_DIR = Path.home() / ".hermes-pong"
STATE_FILE = STATE_DIR / "active-pair.json"
PAIRS_FILE = STATE_DIR / "pairs.json"
SESSIONS_DIR = STATE_DIR / "sessions"
# Top-level compatibility mirrors — updated only for the ACTIVE session.
# The source of truth is sessions/<session>/last-{sent,claude}.txt.
LAST_REPLY = STATE_DIR / "last-claude.txt"
LAST_SENT = STATE_DIR / "last-sent.txt"


# ---------------------------------------------------------------------------
# Team scoping — import hermes_pong.py (single source of truth) when present,
# else fall back to a standalone copy of the same logic.
# ---------------------------------------------------------------------------

def _import_hermes_pong():
    import importlib.util
    candidates = [
        Path(__file__).resolve().parent / "hermes_pong.py",
        Path.home() / "bin" / "hermes_pong.py",
        STATE_DIR / "lib" / "hermes_pong.py",
    ]
    for cand in candidates:
        try:
            if not cand.exists():
                continue
            spec = importlib.util.spec_from_file_location("hermes_pong", cand)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
        except Exception:
            continue
    return None


_HP = _import_hermes_pong()

if _HP is not None:
    WorkerResolveError = _HP.WorkerResolveError
    pair_base_from_tmux_name = _HP.pair_base_from_tmux_name
    detect_bound_session = _HP.detect_bound_session
    load_pairs_db = _HP.load_pairs_db
    load_session_state = _HP.load_session_state
    workers_from_state = _HP.workers_from_state
    format_team_roster = _HP.format_team_roster
    resolve_worker = _HP.resolve_worker
else:
    _PAIR_BASE_RE = re.compile(r"^(hermes-pair(?:-\d+)?|hermes-claude(?:-\d+)?)$")
    _VIEW_SUFFIX_RE = re.compile(r"-(?:h|c|w\d+)$")

    class WorkerResolveError(Exception):
        pass

    def _read_json(path: Path) -> dict:
        try:
            d = json.loads(path.read_text())
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def load_pairs_db() -> dict:
        return _read_json(PAIRS_FILE)

    def pair_base_from_tmux_name(name: str | None) -> str | None:
        if not name:
            return None
        name = name.strip()
        if _PAIR_BASE_RE.match(name):
            return name
        stripped = _VIEW_SUFFIX_RE.sub("", name)
        if stripped != name and _PAIR_BASE_RE.match(stripped):
            return stripped
        return None

    def _tmux_current_session() -> str | None:
        if not os.environ.get("TMUX"):
            return None
        try:
            r = subprocess.run(
                ["tmux", "display-message", "-p", "#{session_name}"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0:
                return (r.stdout or "").strip() or None
        except Exception:
            pass
        return None

    def detect_bound_session() -> str | None:
        env = (os.environ.get("HERMES_PONG_SESSION") or "").strip()
        if env:
            return env
        base = pair_base_from_tmux_name(_tmux_current_session())
        if base:
            return base
        s = _read_json(STATE_FILE).get("session")
        return str(s) if s else None

    def load_session_state(session: str | None = None) -> dict:
        session = session or detect_bound_session()
        if not session:
            return {}
        state: dict = {}
        entry = load_pairs_db().get(session)
        if isinstance(entry, dict):
            state = dict(entry)
        active = _read_json(STATE_FILE)
        if active.get("session") == session:
            merged = dict(state)
            merged.update(active)
            state = merged
        state["session"] = session
        return state

    def workers_from_state(state: dict) -> list[dict]:
        ws = state.get("workers")
        if isinstance(ws, list) and ws:
            return [w for w in ws if isinstance(w, dict)]
        wid = state.get("claude_window_id") or state.get("worker_window_id")
        if wid in (None, "", "null"):
            return []
        return [{
            "id": "w1",
            "type": state.get("worker_type") or "claude",
            "label": state.get("worker_label") or "Worker",
            "window_id": wid,
            "mode": state.get("claude_mode") or "tmux",
            "tmux_index": 1,
            "cmd": state.get("worker_cmd") or "claude",
        }]

    def format_team_roster(state: dict) -> str:
        ws = workers_from_state(state)
        if not ws:
            return "(no workers)"
        return ", ".join(
            f"{w.get('id')}={w.get('label')}({w.get('type')})" for w in ws
        )

    def resolve_worker(state: dict, worker_key: str | None = None) -> dict:
        ws = workers_from_state(state)
        session = state.get("session") or "?"
        if not ws:
            raise WorkerResolveError(f"no workers registered for session={session}")
        if worker_key is None or not str(worker_key).strip():
            return ws[0]
        key = str(worker_key).strip().lower()
        for attr in ("id", "type", "label"):
            hits = [w for w in ws if str(w.get(attr, "")).strip().lower() == key]
            if len(hits) == 1:
                return hits[0]
            if len(hits) > 1:
                raise WorkerResolveError(
                    f"worker key '{worker_key}' is ambiguous by {attr} in "
                    f"session={session}. Team roster: {format_team_roster(state)}"
                )
        hits = [w for w in ws if key in str(w.get("label", "")).lower()]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise WorkerResolveError(
                f"worker key '{worker_key}' matches several labels in "
                f"session={session}. Team roster: {format_team_roster(state)}"
            )
        if key.isdigit():
            i = int(key)
            if 1 <= i <= len(ws):
                return ws[i - 1]
        raise WorkerResolveError(
            f"no worker '{worker_key}' in session={session}. "
            f"Team roster: {format_team_roster(state)}"
        )


# ---------------------------------------------------------------------------
# Prompt assembly
# ---------------------------------------------------------------------------

def claim_instruction(marker: str = MARKER) -> str:
    return (
        f"\n\nWhen completely done, print exactly {marker} on its own line, then a CLAIM block:\n"
        "CLAIM:\n"
        "files: <comma-separated files you changed>\n"
        "commands: <commands you ran, with exit codes>\n"
        'tests_tail: <last 5 lines of test output, or "none run">\n'
        "notes: <1-2 lines>"
    )


def extract_acceptance(text: str) -> str:
    """The body of a task file's `## Acceptance` section (up to the next `## `)."""
    lines = text.splitlines()
    out: list[str] = []
    in_section = False
    for line in lines:
        if line.strip().lower().startswith("## acceptance"):
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            out.append(line)
    return "\n".join(out).strip()


def format_team_context(state: dict) -> str:
    """TEAM CONTEXT block (bound session + project root + team brief), or ''.

    Prefers hermes_pong.team_context_block (single source of truth); falls back
    to a standalone copy when the imported module predates it. Fields come from
    the BOUND session's state only, never another pair.
    """
    fn = getattr(_HP, "team_context_block", None) if _HP is not None else None
    if fn is not None:
        try:
            return fn(state)
        except Exception:
            pass
    session = str(state.get("session") or "?")
    brief = str(state.get("team_brief") or "").strip()
    root = str(state.get("project_root") or "").strip()
    if not brief and not root:
        return ""
    display = str(state.get("display_name") or "").strip() or session
    lines = [
        "## TEAM CONTEXT (bound session only, do not cross pairs)",
        f"- Bound session: {session}",
        f"- Team: {display}",
        f"- Project root: {root or '(unset, ask Hermes before leaving cwd)'}",
        "- Other live pairs are OTHER projects. Never edit their repos. Never assume their tasks.",
        "",
        "### Team brief",
        brief or "(none)",
        "",
        "### Isolation rules",
        "- Resolve workers only inside this session (already enforced by bridge).",
        "- If the user/task names another product/repo not under the project root, STOP and say so. Do not freestyle into it.",
        "- Prefer paths under the project root for all edits.",
    ]
    return "\n".join(lines)


def load_pair_permissions(state: dict) -> dict:
    """Permissions from the bound pair state (pairs.json entry / active merge)."""
    perms = state.get("permissions")
    if isinstance(perms, dict) and perms:
        return perms
    return {}


def format_permissions_block(state: dict, worker: dict | None = None) -> str:
    """Hard access constraints (pair-level, or per-worker if set)."""
    perms = {}
    if worker and isinstance(worker.get("permissions"), dict):
        perms = worker["permissions"]
    if not perms:
        perms = load_pair_permissions(state)
    if not perms:
        return ""
    lines: list[str] = []
    if perms.get("ask_each"):
        lines.append(
            "- ASK BEFORE ELEVATED ACCESS: Before using MCP tools, network/installs, "
            "files outside the project, system paths (~/.ssh, /etc, keychains), sudo/root, "
            "or destructive shell, STOP and ask me in this chat. Wait for an explicit yes "
            "for that specific action. One yes does not unlock the rest."
        )
    if perms.get("ban_mcp"):
        lines.append("- Do NOT use MCP tools or external tool servers.")
    if perms.get("ban_root"):
        lines.append("- Do NOT write outside the project / working tree. No sudo or root-owned paths.")
    if perms.get("repo_only"):
        lines.append("- Stay inside the project repository only. No edits or reads outside that tree unless required to run project tools.")
    if perms.get("ban_network"):
        lines.append("- Do NOT install packages from the network or make outbound fetches unless the task explicitly requires it.")
    if perms.get("ban_system_paths"):
        lines.append("- Do NOT read or write system paths (~/.ssh, /etc, keychains, browser profiles, credentials stores).")
    custom = str(perms.get("custom_prompt") or "").strip()
    if custom:
        lines.append(f"- Additional constraints from the user:\n{custom}")
    if not lines:
        return ""
    return (
        "\n\nPAIR ACCESS CONSTRAINTS (hard rules for this pair — obey):\n"
        + "\n".join(lines)
    )


def build_prompt(
    text: str,
    criteria_path: str | None = None,
    claim: bool = False,
    state: dict | None = None,
    marker: str = MARKER,
) -> str:
    """v1.3 prompt assembly. Without criteria/claim/permissions this is v1.2-compatible.

    Task 1: when the bound pair carries a team_brief and/or project_root, a
    TEAM CONTEXT block goes ABOVE the user task text on every handoff.
    """
    prompt = text
    if state:
        ctx = format_team_context(state)
        if ctx:
            prompt = ctx + "\n\n" + prompt
    use_claim = claim or bool(criteria_path)
    if criteria_path:
        section = extract_acceptance(Path(criteria_path).read_text())
        if section:
            prompt = (
                prompt.rstrip()
                + "\n\nACCEPTANCE CRITERIA (Hermes will verify these independently):\n"
                + section
            )
        else:
            print(f"[bridge] no '## Acceptance' section in {criteria_path}", file=sys.stderr)
    if state:
        prompt = prompt.rstrip() + format_permissions_block(state, state.get("_resolved_worker") if isinstance(state.get("_resolved_worker"), dict) else None)
    if use_claim:
        return prompt.rstrip() + claim_instruction(marker)
    if marker not in prompt:
        prompt = (
            prompt.rstrip()
            + f"\n\nWhen completely done, print exactly {marker} on its own line, "
            "then a short summary of what you did."
        )
    return prompt


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

def run(cmd: list[str], input_text: str | None = None) -> str:
    r = subprocess.run(cmd, input=input_text, capture_output=True, text=True)
    return (r.stdout or "").strip()


def run_ok(cmd: list[str], input_text: str | None = None) -> bool:
    r = subprocess.run(cmd, input=input_text, capture_output=True, text=True)
    return r.returncode == 0


def flash_tmux(target: str, msg: str) -> None:
    run_ok(["tmux", "display-message", "-t", target, msg])


def capture_tmux(target: str, lines: int = 400) -> str:
    return run(["tmux", "capture-pane", "-p", "-t", target, "-S", f"-{lines}"])


def _session_artifact(state: dict | None, name: str) -> Path | None:
    """sessions/<bound session>/<name>, or None when no session is bound."""
    sess = (state or {}).get("session")
    if not sess:
        return None
    d = SESSIONS_DIR / str(sess)
    d.mkdir(parents=True, exist_ok=True)
    return d / name


def _is_active_session(sess) -> bool:
    try:
        return json.loads(STATE_FILE.read_text()).get("session") == sess
    except Exception:
        return False


def reply_path(state: dict | None = None) -> Path:
    return _session_artifact(state, "last-claude.txt") or LAST_REPLY


def save_sent(prompt: str, state: dict | None = None) -> None:
    """Session-scoped last-sent. Two live pairs never clobber each other; the
    top-level file mirrors the active session only (old tools keep working)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = _session_artifact(state, "last-sent.txt")
    if p is not None:
        p.write_text(prompt)
    sess = (state or {}).get("session")
    if p is None or _is_active_session(sess):
        LAST_SENT.write_text(prompt)


def save_reply(text: str, state: dict | None = None) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = _session_artifact(state, "last-claude.txt")
    if p is not None:
        p.write_text(text)
    sess = (state or {}).get("session")
    if p is None or _is_active_session(sess):
        LAST_REPLY.write_text(text)
    if sess:
        preview = text[-1500:] if len(text) > 1500 else text
        banner = (
            f"\n\n──────── Hermes Pong · Claude reply ────────\n"
            f"{preview}\n"
            f"──────── end (full: {p or LAST_REPLY}) ────────\n\n"
        )
        run_ok(["tmux", "load-buffer", "-"], input_text=banner)
        run_ok(["tmux", "paste-buffer", "-t", f"{sess}:0", "-d"])


def quartz_paste_enter() -> bool:
    try:
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventPost,
            CGEventSetFlags,
            kCGHIDEventTap,
            kCGEventFlagMaskCommand,
        )

        def tap(key_code: int, flags: int = 0, down: bool = True):
            ev = CGEventCreateKeyboardEvent(None, key_code, down)
            if flags:
                CGEventSetFlags(ev, flags)
            CGEventPost(kCGHIDEventTap, ev)

        tap(9, kCGEventFlagMaskCommand, True)
        tap(9, kCGEventFlagMaskCommand, False)
        time.sleep(0.2)
        tap(36, 0, True)
        tap(36, 0, False)
        time.sleep(0.05)
        tap(36, 0, True)
        tap(36, 0, False)
        return True
    except Exception as e:
        print(f"[bridge] quartz paste failed: {e}", file=sys.stderr)
        return False


def send_via_tmux(target: str, prompt: str, state: dict | None = None) -> None:
    save_sent(prompt, state)

    run_ok(["tmux", "select-window", "-t", target])
    flash_tmux(target, "⚡ Hermes Pong: submitting task (paste + Enter)…")
    time.sleep(0.05)

    if not run_ok(["tmux", "load-buffer", "-"], input_text=prompt):
        for i in range(0, len(prompt), 400):
            run_ok(["tmux", "send-keys", "-t", target, "-l", prompt[i : i + 400]])
            time.sleep(0.02)
    else:
        run_ok(["tmux", "paste-buffer", "-t", target, "-d"])

    time.sleep(0.2)
    run_ok(["tmux", "send-keys", "-t", target, "Enter"])
    time.sleep(0.05)
    run_ok(["tmux", "send-keys", "-t", target, "C-m"])
    flash_tmux(target, "⚡ Hermes Pong: Enter sent — watch Claude window")
    print(f"[bridge] tmux submit → {target} ({len(prompt)} chars) + Enter")
    vc = (state or {}).get("view_claude")
    if vc:
        run_ok(["tmux", "select-window", "-t", f"{vc}:1"])


def send_via_terminal_window(window_id: str, prompt: str, state: dict | None = None) -> None:
    """Clipboard paste + Return into the live Claude Terminal window."""
    save_sent(prompt, state)

    p = subprocess.run(["pbcopy"], input=prompt, text=True)
    if p.returncode != 0:
        print("[bridge] pbcopy failed", file=sys.stderr)
        sys.exit(1)

    focus = f'''
tell application "Terminal"
  try
    set w to window id {window_id}
    set index of w to 1
    set selected of w to true
    activate
  end try
end tell
'''
    subprocess.run(["osascript"], input=focus, text=True, capture_output=True)
    time.sleep(0.4)

    if quartz_paste_enter():
        print(f"[bridge] → Claude window {window_id} quartz paste+Enter ({len(prompt)} chars)")
    else:
        script = f'''
tell application "System Events"
  tell process "Terminal"
    set frontmost to true
    delay 0.15
    keystroke "v" using {{command down}}
    delay 0.25
    key code 36
    delay 0.05
    key code 36
  end tell
end tell
'''
        r = subprocess.run(["osascript"], input=script, text=True, capture_output=True)
        print(f"[bridge] → Claude window {window_id} osascript paste rc={r.returncode}")
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            print(
                "[bridge] Enable Accessibility for Terminal/osascript if paste fails",
                file=sys.stderr,
            )

    # Also dump into tmux :1 so the relay/log has a copy
    sess = (state or {}).get("session")
    if sess:
        run_ok(["tmux", "load-buffer", "-"], input_text=prompt)
        run_ok(["tmux", "paste-buffer", "-t", f"{sess}:1", "-d"])
        run_ok(["tmux", "send-keys", "-t", f"{sess}:1", "Enter"])

    print(f"[bridge] saved {_session_artifact(state, 'last-sent.txt') or LAST_SENT}")
    print("[bridge] Watch your Claude Code window — task should appear and submit.")


def wait_tmux(target: str, max_wait: int = 600, poll: float = 3.0,
              marker: str = MARKER, state: dict | None = None) -> str:
    start = time.time()
    last = ""
    stable = 0
    last_flash = 0.0
    while time.time() - start < max_wait:
        out = capture_tmux(target)
        if marker in out:
            flash_tmux(target, "⚡ Hermes Pong: done marker seen")
            parts = out.split(marker)
            reply = parts[-1].strip() if len(parts) > 1 else out
            save_reply(reply, state)
            return reply
        if out == last:
            stable += 1
            if stable >= 8:
                flash_tmux(target, "⚡ Hermes Pong: output stable")
                reply = "\n".join(out.split("\n")[-200:])
                save_reply(reply, state)
                return reply
        else:
            stable = 0
            last = out
        now = time.time()
        if now - last_flash > 15:
            flash_tmux(target, f"⚡ Hermes Pong: Claude working… {int(now - start)}s")
            last_flash = now
        time.sleep(poll)
    flash_tmux(target, "⚡ Hermes Pong: timeout")
    reply = capture_tmux(target)[-2000:]
    save_reply(reply, state)
    return "Timeout.\n" + reply


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="*")
    ap.add_argument("-s", "--session", default=None,
                    help="pair session to bind to (default: HERMES_PONG_SESSION / tmux / active-pair)")
    ap.add_argument("-w", "--window", default=None,
                    help="tmux window index (default: from worker tmux_index or 1)")
    ap.add_argument("--worker", default=None,
                    help="worker id (w1), type (claude/kimi), label, or 1-based index — this team only")
    ap.add_argument("--no-wait", action="store_true")
    ap.add_argument("--max-wait", type=int, default=600)
    ap.add_argument("--mode", choices=("auto", "tmux", "window"), default="auto")
    ap.add_argument("--dry-run", action="store_true",
                    help="print bound_session, roster, target, worker; exit 0 without sending")
    ap.add_argument("--criteria", default=None, metavar="PATH",
                    help="task file; its ## Acceptance section is appended and a CLAIM block is required")
    ap.add_argument("--claim", action="store_true",
                    help="require a CLAIM block on done (implied by --criteria)")
    ap.add_argument("--record-verdict", choices=("accept", "reject", "escalate"),
                    default=None, help="record a verdict via pong-ledger.py and exit")
    ap.add_argument("--task-id", default=None)
    ap.add_argument("--round", type=int, default=None)
    ap.add_argument("--evidence", default="")
    args = ap.parse_args()

    if args.record_verdict:
        if not args.task_id or args.round is None:
            print("[bridge] --record-verdict needs --task-id and --round", file=sys.stderr)
            sys.exit(1)
        ledger = Path(__file__).resolve().parent / "pong-ledger.py"
        if not ledger.exists():
            print(f"[bridge] pong-ledger.py not found next to {__file__}", file=sys.stderr)
            sys.exit(1)
        r = subprocess.run(
            [sys.executable, str(ledger), "record",
             "--task-id", args.task_id, "--round", str(args.round),
             "--verdict", args.record_verdict, "--evidence", args.evidence]
        )
        sys.exit(r.returncode)

    if not args.prompt and not args.dry_run:
        print(
            "Usage: claude-delegate.py [-s session] [--worker w1] 'task…'\n"
            "  Alias: pong-delegate.py\n"
            "  Pastes + Enter into a worker terminal of YOUR bound team only.\n"
            "  --dry-run shows bound_session/roster/target without sending.\n"
            f"  Writes {SESSIONS_DIR}/<session>/last-sent.txt (+ last-claude.txt);\n"
            f"  top-level {LAST_SENT.name}/{LAST_REPLY.name} mirror the active session only.",
            file=sys.stderr,
        )
        sys.exit(1)

    # --- bound session -----------------------------------------------------
    env_sess = (os.environ.get("HERMES_PONG_SESSION") or "").strip() or None
    session = args.session
    if session and env_sess and session != env_sess:
        print(
            f"[bridge] WARNING: env HERMES_PONG_SESSION={env_sess} != -s {session}; "
            "honoring explicit -s (operator override)",
            file=sys.stderr,
        )
    if not session:
        session = detect_bound_session()
    state = load_session_state(session)
    if not session or not workers_from_state(state):
        known = ", ".join(sorted(load_pairs_db().keys())) or "none"
        print(
            f"[bridge] no team for session={session!r}. Start a pair in Hermes Pong "
            f"or pass -s <session>. Known pairs: {known}",
            file=sys.stderr,
        )
        sys.exit(2)

    # --- worker resolution: strict, inside the bound team only -------------
    try:
        worker = resolve_worker(state, args.worker)
    except WorkerResolveError as e:
        print(f"[bridge] {e}", file=sys.stderr)
        sys.exit(2)

    state = {**state, "_resolved_worker": worker}
    if worker.get("window_id") not in (None, "", "null"):
        state = {**state, "claude_window_id": worker.get("window_id"),
                 "worker_window_id": worker.get("window_id")}
    if worker.get("mode"):
        state = {**state, "claude_mode": worker.get("mode")}
    tmux_idx = worker.get("tmux_index")
    if tmux_idx is not None and args.window is None:
        args.window = str(tmux_idx)
    if args.window is None:
        args.window = "1"

    marker = str(worker.get("done_marker") or MARKER)

    try:
        prompt = build_prompt(
            " ".join(args.prompt) if args.prompt else "(dry-run ping)",
            criteria_path=args.criteria,
            claim=args.claim,
            state=state,
            marker=marker,
        )
    except OSError as e:
        print(f"[bridge] cannot read --criteria file: {e}", file=sys.stderr)
        sys.exit(1)

    mode = args.mode
    if mode == "auto":
        if state.get("claude_mode") == "window" and state.get("claude_window_id"):
            mode = "window"
        else:
            mode = "tmux"

    # tmux target is ALWAYS inside the bound session — never another pair's panes
    target = f"{session}:{args.window}"

    auto = state.get("autonomy_level") or "full"
    wdesc = f"{worker.get('id')}={worker.get('label')}({worker.get('type')})"
    print(f"[bridge] bound_session={session} worker={wdesc} mode={mode} autonomy={auto}")
    print(f"[bridge] roster: {format_team_roster(state)}")

    if args.dry_run:
        tgt = target if mode == "tmux" else f"window:{state.get('claude_window_id')}"
        print(f"[bridge] DRY-RUN target={tgt} marker={marker} prompt_chars={len(prompt)} (nothing sent)")
        return

    print("[bridge] verdict loop: Hermes verifies each CLAIM and loops until accept or escalate")
    if format_permissions_block(state):
        print("[bridge] pair access constraints injected from pair permissions")
    if format_team_context(state):
        print(f"[bridge] TEAM CONTEXT injected (session={session}, project root + team brief)")

    if mode == "tmux":
        if not run_ok(["tmux", "has-session", "-t", session]):
            print(f"[bridge] tmux session '{session}' is not running (Link or New pair first)",
                  file=sys.stderr)
            sys.exit(2)
        print(f"[bridge] target {target}")
        run_ok(["tmux", "select-window", "-t", target])
        send_via_tmux(target, prompt, state)
        if args.no_wait:
            print(f"[bridge] submitted (no-wait). Watch worker Terminal. Later: cat {reply_path(state)}")
            return
        print("[bridge] waiting for worker…")
        result = wait_tmux(target, max_wait=args.max_wait, marker=marker, state=state)
        print("\n=== WORKER RESPONSE ===\n")
        print(result)
        print(f"\n[bridge] also saved → {reply_path(state)}")
        return

    wid = str(state.get("claude_window_id") or "")
    if not wid.isdigit():
        print("[bridge] No worker window_id in state for window mode", file=sys.stderr)
        sys.exit(2)
    send_via_terminal_window(wid, prompt, state)
    if args.no_wait:
        print(f"[bridge] submitted to worker window {wid} (no-wait).")
        return
    print("[bridge] window mode: watch the worker Terminal for the reply.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
claude-delegate.py — send a task to the Claude side of a Hermes Pong pair.

Two modes:
  tmux   — Claude runs inside tmux (New pair): paste into session:1
  window — Claude is a live Terminal (Link existing): clipboard paste + Return
           into that window; also writes last-sent for the relay.

Always submits with Enter (no silent text sitting in the box).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

MARKER = "##CLAUDE_DONE##"
STATE_DIR = Path.home() / ".hermes-pong"
STATE_FILE = STATE_DIR / "active-pair.json"
LAST_REPLY = STATE_DIR / "last-claude.txt"
LAST_SENT = STATE_DIR / "last-sent.txt"

CLAIM_INSTRUCTION = (
    f"\n\nWhen completely done, print exactly {MARKER} on its own line, then a CLAIM block:\n"
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


def load_pair_permissions(state: dict) -> dict:
    """Permissions from active-pair, falling back to pairs.json for the session."""
    perms = state.get("permissions")
    if isinstance(perms, dict) and perms:
        return perms
    session = state.get("session")
    if not session:
        return {}
    pairs_path = STATE_DIR / "pairs.json"
    if not pairs_path.exists():
        return {}
    try:
        db = json.loads(pairs_path.read_text())
        entry = db.get(session) or {}
        p = entry.get("permissions")
        return p if isinstance(p, dict) else {}
    except Exception:
        return {}


def format_permissions_block(state: dict) -> str:
    """Hard access constraints the user set on this pair (bans + freeform note)."""
    perms = load_pair_permissions(state)
    if not perms:
        return ""
    lines: list[str] = []
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
) -> str:
    """v1.3 prompt assembly. Without criteria/claim/permissions this is v1.2-compatible."""
    prompt = text
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
        prompt = prompt.rstrip() + format_permissions_block(state)
    if use_claim:
        return prompt.rstrip() + CLAIM_INSTRUCTION
    if MARKER not in prompt:
        prompt = (
            prompt.rstrip()
            + f"\n\nWhen completely done, print exactly {MARKER} on its own line, "
            "then a short summary of what you did."
        )
    return prompt


def run(cmd: list[str], input_text: str | None = None) -> str:
    r = subprocess.run(cmd, input=input_text, capture_output=True, text=True)
    return (r.stdout or "").strip()


def run_ok(cmd: list[str], input_text: str | None = None) -> bool:
    r = subprocess.run(cmd, input=input_text, capture_output=True, text=True)
    return r.returncode == 0


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {}


def list_pair_sessions() -> list[str]:
    out = run(["tmux", "list-sessions", "-F", "#{session_name}"])
    names = []
    for line in out.splitlines():
        s = line.strip()
        if s.endswith("-h") or s.endswith("-c"):
            continue
        if s == "hermes-claude" or s.startswith("hermes-claude-") or s.startswith("hermes-pair"):
            names.append(s)
    return names


def resolve_tmux_target(session: str | None, window: str) -> str | None:
    if session:
        return f"{session}:{window}"
    state = load_state()
    if state.get("session"):
        return f"{state['session']}:{window}"
    pairs = list_pair_sessions()
    if not pairs:
        return None
    name = "hermes-claude" if "hermes-claude" in pairs else pairs[0]
    return f"{name}:{window}"


def flash_tmux(target: str, msg: str) -> None:
    run_ok(["tmux", "display-message", "-t", target, msg])


def capture_tmux(target: str, lines: int = 400) -> str:
    return run(["tmux", "capture-pane", "-p", "-t", target, "-S", f"-{lines}"])


def save_reply(text: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LAST_REPLY.write_text(text)
    state = load_state()
    sess = state.get("session")
    if sess:
        preview = text[-1500:] if len(text) > 1500 else text
        banner = (
            f"\n\n──────── Hermes Pong · Claude reply ────────\n"
            f"{preview}\n"
            f"──────── end (full: {LAST_REPLY}) ────────\n\n"
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


def send_via_tmux(target: str, prompt: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LAST_SENT.write_text(prompt)

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
    state = load_state()
    vc = state.get("view_claude")
    if vc:
        run_ok(["tmux", "select-window", "-t", f"{vc}:1"])


def send_via_terminal_window(window_id: str, prompt: str) -> None:
    """Clipboard paste + Return into the live Claude Terminal window."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LAST_SENT.write_text(prompt)

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
    state = load_state()
    sess = state.get("session")
    if sess:
        run_ok(["tmux", "load-buffer", "-"], input_text=prompt)
        run_ok(["tmux", "paste-buffer", "-t", f"{sess}:1", "-d"])
        run_ok(["tmux", "send-keys", "-t", f"{sess}:1", "Enter"])

    print(f"[bridge] saved {LAST_SENT}")
    print("[bridge] Watch your Claude Code window — task should appear and submit.")


def wait_tmux(target: str, max_wait: int = 600, poll: float = 3.0) -> str:
    start = time.time()
    last = ""
    stable = 0
    last_flash = 0.0
    while time.time() - start < max_wait:
        out = capture_tmux(target)
        if MARKER in out:
            flash_tmux(target, "⚡ Hermes Pong: done marker seen")
            parts = out.split(MARKER)
            reply = parts[-1].strip() if len(parts) > 1 else out
            save_reply(reply)
            return reply
        if out == last:
            stable += 1
            if stable >= 8:
                flash_tmux(target, "⚡ Hermes Pong: output stable")
                reply = "\n".join(out.split("\n")[-200:])
                save_reply(reply)
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
    save_reply(reply)
    return "Timeout.\n" + reply


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="*")
    ap.add_argument("-s", "--session", default=None)
    ap.add_argument("-w", "--window", default="1")
    ap.add_argument("--no-wait", action="store_true")
    ap.add_argument("--max-wait", type=int, default=600)
    ap.add_argument("--mode", choices=("auto", "tmux", "window"), default="auto")
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

    if not args.prompt:
        print(
            "Usage: claude-delegate.py 'task…'\n"
            "  Pastes + Enter into Claude (window or tmux).\n"
            f"  Writes {LAST_SENT} and often {LAST_REPLY}",
            file=sys.stderr,
        )
        sys.exit(1)

    state = load_state()
    try:
        prompt = build_prompt(
            " ".join(args.prompt),
            criteria_path=args.criteria,
            claim=args.claim,
            state=state,
        )
    except OSError as e:
        print(f"[bridge] cannot read --criteria file: {e}", file=sys.stderr)
        sys.exit(1)

    mode = args.mode
    if mode == "auto":
        if state.get("claude_mode") == "window" and state.get("claude_window_id"):
            mode = "window"
        elif state.get("claude_mode") == "tmux" and resolve_tmux_target(args.session, args.window):
            mode = "tmux"
        elif state.get("claude_window_id"):
            mode = "window"
        elif resolve_tmux_target(args.session, args.window):
            mode = "tmux"
        else:
            print("[bridge] No pair. Use Hermes Pong → New pair or Link first.", file=sys.stderr)
            sys.exit(2)

    auto = state.get("autonomy_level") or "full"
    print(f"[bridge] mode={mode} session={state.get('session')} claude_window={state.get('claude_window_id')} autonomy={auto}")
    print("[bridge] verdict loop: Hermes verifies each CLAIM and loops until accept or escalate")
    if format_permissions_block(state):
        print("[bridge] pair access constraints injected from pair permissions")

    if mode == "tmux":
        target = resolve_tmux_target(args.session, args.window)
        if not target:
            print("[bridge] No tmux pair session", file=sys.stderr)
            sys.exit(2)
        print(f"[bridge] target {target}")
        run_ok(["tmux", "select-window", "-t", target])
        send_via_tmux(target, prompt)
        if args.no_wait:
            print(f"[bridge] submitted (no-wait). Watch Claude Terminal. Later: cat {LAST_REPLY}")
            return
        print("[bridge] waiting for Claude…")
        result = wait_tmux(target, max_wait=args.max_wait)
        print("\n=== CLAUDE RESPONSE ===\n")
        print(result)
        print(f"\n[bridge] also saved → {LAST_REPLY}")
        return

    wid = str(state.get("claude_window_id") or "")
    if not wid.isdigit():
        print("[bridge] No claude_window_id in state for window mode", file=sys.stderr)
        sys.exit(2)
    send_via_terminal_window(wid, prompt)
    if args.no_wait:
        print("[bridge] submitted to Claude window (no-wait).")
        return
    print("[bridge] window mode: watch Claude Code for the reply.")


if __name__ == "__main__":
    main()

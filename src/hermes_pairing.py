#!/usr/bin/env python3
"""
Hermes Pong control panel — multi-pair list, click-to-link with guide popup.
"""

from __future__ import annotations

import subprocess
import threading
import time
from pathlib import Path

from AppKit import (
    NSApplication,
    NSApp,
    NSObject,
    NSWindow,
    NSView,
    NSButton,
    NSTextField,
    NSImageView,
    NSMakeRect,
    NSBackingStoreBuffered,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskBorderless,
    NSFloatingWindowLevel,
    NSStatusWindowLevel,
    NSFont,
    NSImage,
    NSColor,
    NSApplicationActivationPolicyRegular,
    NSApplicationActivationPolicyAccessory,
    NSLineBreakByWordWrapping,
    NSBezelStyleRounded,
    NSImageScaleProportionallyUpOrDown,
    NSImageAlignCenter,
    NSScreen,
    NSBezierPath,
    NSTimer,
    NSMenu,
    NSMenuItem,
    NSAlert,
    NSAlertFirstButtonReturn,
)
from Foundation import NSMakeSize, NSProcessInfo, NSBundle
import objc
from objc import python_method

HERMES_BLUE = (0x26 / 255.0, 0x02 / 255.0, 0xF1 / 255.0, 1.0)
CLAUDE_ORANGE = (0xD9 / 255.0, 0x77 / 255.0, 0x56 / 255.0, 1.0)

_OVERLAYS: list = []

LOG = Path.home() / "Library" / "Logs" / "HermesPong.log"
HERE = Path(__file__).resolve().parent
ICON = HERE / "AppIcon-1024.png"
ILLU = HERE / "pair-illustration.png"

W, H = 460, 800
PAD = 28
GUIDE_W, GUIDE_H = 340, 160


def log(msg: str):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except Exception:
        pass


def sh(cmd: str) -> str:
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return (r.stdout or "").strip()
    except Exception as e:
        return str(e)


def osascript(script: str) -> str:
    """Run multi-line AppleScript via temp file (reliable)."""
    import tempfile
    import os

    path = None
    try:
        f = tempfile.NamedTemporaryFile("w", suffix=".applescript", delete=False)
        f.write(script)
        f.close()
        path = f.name
        r = subprocess.run(["osascript", path], capture_output=True, text=True)
        return (r.stdout or "").strip()
    except Exception as e:
        log(f"osascript err: {e}")
        return ""
    finally:
        if path:
            try:
                os.unlink(path)
            except Exception:
                pass


def list_terminal_windows() -> list[tuple[str, str]]:
    """Return [(window_id, title), ...] for all Terminal windows."""
    script = '''
tell application "Terminal"
  set acc to ""
  repeat with w in windows
    try
      set wid to id of w as string
      set nm to name of w
      set acc to acc & wid & "|||" & nm & linefeed
    end try
  end repeat
  return acc
end tell
'''
    out = osascript(script)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if "|||" not in line:
            continue
        wid, title = line.split("|||", 1)
        wid = wid.strip()
        if wid.isdigit():
            # Shorten title for button
            t = title.strip()
            if len(t) > 42:
                t = t[:39] + "…"
            rows.append((wid, t))
    log(f"list_terminal_windows n={len(rows)} {rows}")
    return rows


def _front_terminal_id() -> str | None:
    script = '''
tell application "Terminal"
  try
    if (count of windows) is 0 then return "NONE"
    return id of front window as string
  on error
    return "NONE"
  end try
end tell
'''
    r = osascript(script)
    return r if r.isdigit() else None


def list_pairs() -> list[str]:
    out = sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
    names = []
    for s in out.splitlines():
        s = s.strip()
        if not s:
            continue
        if s == "hermes-claude" or s.startswith("hermes-claude-") or s.startswith("hermes-pair"):
            names.append(s)
    log(f"list_pairs raw={out!r} filtered={names}")
    return names


def next_pair_name() -> str:
    existing = set(list_pairs())
    if "hermes-claude" not in existing:
        return "hermes-claude"
    n = 1
    while n <= 50:
        name = f"hermes-pair-{n}"
        if name not in existing:
            return name
        n += 1
    return f"hermes-pair-{int(time.time()) % 10000}"


def start_fresh(name: str | None = None):
    """
    Create a new pair: two Terminal windows (Hermes + Claude) attached to tmux.
    Claude starts fresh here (no prior model/context) — use Link for existing Claude.
    """
    name = name or next_pair_name()
    sh(f"tmux has-session -t {name} 2>/dev/null && tmux kill-session -t {name} || true")
    sh(f"tmux new-session -d -s {name} -n Hermes")
    wins = sh(f"tmux list-windows -t {name} -F '#{{window_index}}'")
    if "1" not in wins.split():
        sh(f"tmux new-window -t {name} -n Claude")
    # Start claude in pane 1 before attaching so the window shows it
    sh(f"tmux send-keys -t {name}:1 -l 'claude'")
    time.sleep(0.05)
    sh(f"tmux send-keys -t {name}:1 Enter")

    # Open two real Terminal windows and hop into the panes
    script = f'''
tell application "Terminal"
  activate
  set wHermes to do script "tmux attach -t {name}:0 || tmux attach -t {name}"
  delay 0.35
  set idH to id of front window
  set wClaude to do script "tmux attach -t {name}:1 || tmux attach -t {name}"
  delay 0.35
  set idC to id of front window
  return (idH as string) & "," & (idC as string)
end tell
'''
    out = osascript(script)
    hid, cid = None, None
    if out and "," in out:
        parts = out.split(",", 1)
        hid, cid = parts[0].strip(), parts[1].strip()
    save_pair_state(
        name,
        hermes_window_id=hid,
        claude_window_id=cid,
        claude_mode="tmux",
    )
    if hid:
        flash_pair_windows(hid, cid)
    log(f"start_fresh {name} hermes={hid} claude={cid}")
    return name

def load_pairs_db() -> dict:
    import json
    path = Path.home() / ".hermes-pong" / "pairs.json"
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:
            pass
    return {}


def flash_terminal_window(window_id: str, times: int = 1) -> None:
    """Quick clean blink (<0.25s). Prefer flash_pair_windows for Front."""
    if not window_id or not str(window_id).isdigit():
        return
    flash_pair_windows(str(window_id), None)


def flash_pair_windows(hermes_id: str | None, claude_id: str | None) -> None:
    """
    One clean macOS-style blink of the paired windows.
    Total animation ~0.12s — raise both, hide once, show once.
    """
    ids = []
    for wid in (claude_id, hermes_id):
        if wid and str(wid).isdigit() and str(wid) not in ids:
            ids.append(str(wid))
    if not ids:
        return

    # Build AppleScript that pulses all target windows in one shot
    lines = [
        'tell application "Terminal"',
        "  try",
    ]
    for i, wid in enumerate(ids):
        lines.append(f"    set w{i} to window id {wid}")
    # Raise Claude first (if present), Hermes on top
    for i in range(len(ids)):
        lines.append(f"    set index of w{i} to 1")
    lines.append("    activate")
    for i in range(len(ids)):
        lines.append(f"    set visible of w{i} to false")
    lines.append("    delay 0.10")
    for i in range(len(ids)):
        lines.append(f"    set visible of w{i} to true")
    for i in range(len(ids)):
        lines.append(f"    set index of w{i} to 1")
    lines += ["  end try", "end tell"]
    osascript("\n".join(lines))
    log(f"flash_pair_windows ids={ids}")


def bring_to_front(name: str):
    """
    Bring the *paired* Hermes + Claude Terminal windows to front and flash them.
    Uses saved window ids from Link — not “most recent” Terminal.
    """
    db = load_pairs_db()
    entry = db.get(name) or {}
    if not entry:
        import json
        ap = Path.home() / ".hermes-pong" / "active-pair.json"
        if ap.exists():
            try:
                cur = json.loads(ap.read_text())
                if cur.get("session") == name:
                    entry = cur
            except Exception:
                pass

    hid = entry.get("hermes_window_id")
    cid = entry.get("claude_window_id")
    log(f"bring_to_front {name} hermes={hid} claude={cid}")

    if (hid and str(hid).isdigit()) or (cid and str(cid).isdigit()):
        flash_pair_windows(
            str(hid) if hid and str(hid).isdigit() else None,
            str(cid) if cid and str(cid).isdigit() else None,
        )
    else:
        sh(f"tmux switch-client -t {name}:0 2>/dev/null || true")
        sh('''osascript -e 'tell application "Terminal" to activate' ''')
        log("bring_to_front: no saved window ids — Terminal activate only")


def run_in_terminal_window(window_id: str, command: str) -> str:
    """
    Run a shell command inside the *selected tab* of an existing Terminal window.
    `do script … in window id` creates a NEW tab — we never want that for link.
    """
    # Escape for AppleScript string
    cmd = command.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
tell application "Terminal"
  try
    set w to window id {window_id}
    set index of w to 1
    set selected of w to true
    -- Hop INTO the current tab (does not open a new window/tab)
    do script "{cmd}" in selected tab of w
    activate
    return "OK"
  on error errMsg
    return "ERR:" & errMsg
  end try
end tell
'''
    out = osascript(script)
    log(f"run_in_terminal_window id={window_id} → {out!r} cmd={command!r}")
    return out


def focus_terminal_window(window_id: str) -> None:
    osascript(
        f'''
tell application "Terminal"
  try
    set index of window id {window_id} to 1
    set selected of window id {window_id} to true
    activate
  end try
end tell
'''
    )


def save_pair_state(
    session: str,
    hermes_window_id: str | None = None,
    claude_window_id: str | None = None,
    claude_mode: str = "tmux",
) -> None:
    """Persist active pair + per-session window map for Front."""
    import json

    state_dir = Path.home() / ".hermes-pong"
    state_dir.mkdir(parents=True, exist_ok=True)
    data = {
        "session": session,
        "hermes_window_id": hermes_window_id,
        "claude_window_id": claude_window_id,
        "claude_mode": claude_mode,
        "updated": time.time(),
    }
    (state_dir / "active-pair.json").write_text(json.dumps(data, indent=2))
    db = load_pairs_db()
    db[session] = {
        "hermes_window_id": hermes_window_id,
        "claude_window_id": claude_window_id,
        "claude_mode": claude_mode,
        "updated": time.time(),
    }
    (state_dir / "pairs.json").write_text(json.dumps(db, indent=2))
    reply = state_dir / "last-claude.txt"
    if not reply.exists():
        reply.write_text(
            "(no Claude reply yet — run claude-delegate.py after Claude finishes a task)\n"
        )
    log(f"saved pair state {data}")


def terminal_tab_looks_like_tui(window_id: str) -> bool:
    """True if the Terminal tab is already Hermes/Claude app UI (not a bare shell)."""
    for wid, title in list_terminal_windows():
        if wid == str(window_id):
            t = title.lower()
            return any(x in t for x in ("claude", "✳", "fable", "hermes", "⚕", "grok"))
    return False


def wire_pair(name: str, w1: str, w2: str):
    """
    Soft pair: save real window ids. Never dump shell/tmux into Hermes or Claude TUIs.
    Shells can attach to tmux; live apps are register-only.
    """
    sh(f"tmux has-session -t {name} 2>/dev/null || tmux new-session -d -s {name} -n Hermes")
    wins = sh(f"tmux list-windows -t {name} -F '#{{window_index}}'")
    if "1" not in wins.split():
        sh(f"tmux new-window -t {name} -n Claude")

    hermes_tui = terminal_tab_looks_like_tui(w1)
    claude_tui = terminal_tab_looks_like_tui(w2)

    # Hermes: only inject attach if bare shell
    if not hermes_tui:
        run_in_terminal_window(
            w1,
            f"printf '\\n  HERMES · {name}:0\\n  replies: cat ~/.hermes-pong/last-claude.txt\\n\\n'; "
            f"tmux attach -t {name}:0 || tmux attach -t {name}",
        )
        time.sleep(0.3)
    else:
        log(f"Hermes window {w1} is live TUI — register only (no printf/tmux inject)")

    if claude_tui:
        log(f"Claude window {w2} is live TUI — register only (no chat junk)")
        save_pair_state(name, hermes_window_id=w1, claude_window_id=w2, claude_mode="window")
        log(f"wired {name} mode=window hermes={w1} claude={w2}")
        return

    # Claude shell → attach :1 and run claude so work is visible in that window
    run_in_terminal_window(
        w2,
        f"printf '\\n  CLAUDE · {name}:1  (work appears here)\\n\\n'; "
        f"tmux attach -t {name}:1 || tmux attach -t {name}",
    )
    time.sleep(0.4)
    pane = sh(f"tmux capture-pane -p -t {name}:1 -S -40 2>/dev/null || true")
    already = any(
        x in pane.lower()
        for x in ("claude code", "trust this folder", "bypass permissions", "fable", "✳")
    )
    if not already:
        sh(f"tmux send-keys -t {name}:1 -l 'claude'")
        time.sleep(0.05)
        sh(f"tmux send-keys -t {name}:1 Enter")
    save_pair_state(name, hermes_window_id=w1, claude_window_id=w2, claude_mode="tmux")
    log(f"wired {name} mode=tmux hermes={w1} claude={w2}")


def kill_pair(name: str):
    sh(f"tmux kill-session -t {name} 2>/dev/null || true")
    try:
        import json
        db = load_pairs_db()
        if name in db:
            del db[name]
            (Path.home() / ".hermes-pong" / "pairs.json").write_text(json.dumps(db, indent=2))
    except Exception:
        pass
    log(f"killed {name}")


def claude_stream_text(session: str | None = None) -> str:
    """What Hermes actually sent / what the Claude *tmux* pane shows."""
    import json
    state_dir = Path.home() / ".hermes-pong"
    sess = session
    if not sess:
        ap = state_dir / "active-pair.json"
        if ap.exists():
            try:
                sess = json.loads(ap.read_text()).get("session")
            except Exception:
                pass
    if not sess:
        pairs = list_pairs()
        sess = pairs[0] if pairs else None

    last_sent = ""
    p = state_dir / "last-sent.txt"
    if p.exists():
        last_sent = p.read_text()
    last_reply = ""
    r = state_dir / "last-claude.txt"
    if r.exists():
        last_reply = r.read_text()

    pane = ""
    if sess:
        pane = sh(f"tmux capture-pane -p -t {sess}:1 -S -80 2>/dev/null || true")
        if not pane.strip():
            pane = sh(f"tmux capture-pane -p -t {sess} -S -80 2>/dev/null || true")

    mode = ""
    if (state_dir / "active-pair.json").exists():
        try:
            mode = json.loads((state_dir / "active-pair.json").read_text()).get("claude_mode", "")
        except Exception:
            pass

    parts = [
        f"session: {sess or '(none)'}   mode: {mode or '?'}",
        "",
        "═══ LAST SENT (bridge) ═══",
        last_sent.strip() or "(nothing recorded in last-sent.txt yet)",
        "",
        "═══ CLAUDE TMUX PANE (:1) — this is where Hermes send-keys land ═══",
        pane.strip() or "(empty / no tmux pane)",
        "",
        "═══ LAST REPLY MIRROR ═══",
        last_reply.strip() or "(no last-claude.txt yet)",
    ]
    if mode == "window":
        parts.insert(
            2,
            "NOTE: Pair is window-mode — your Claude Code UI window is separate.\n"
            "Hermes often writes to tmux :1 (shown below). Watch this stream for that I/O.\n"
            "For Hermes to paste into the live Claude Code window, it must use claude-delegate.py\n"
            "(window mode), not raw tmux send-keys.\n",
        )
    return "\n".join(parts)


# Global stream controller ref
_STREAM = None


class ClaudeStreamController(NSObject):
    """Floating window: live I/O Hermes ↔ Claude (tmux pane + last-sent)."""

    window = None
    textView = None
    scroll = None
    timer = None
    session = None
    statusLabel = None

    @python_method
    def open_for_session(self, session: str | None = None):
        self.session = session
        self._ensure()
        self.refresh_(None)
        self.window.center()
        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)
        self._arm()
        log(f"claude stream open session={session}")

    @python_method
    def _ensure(self):
        if self.window is not None:
            return
        from AppKit import (
            NSScrollView,
            NSTextView,
            NSFont,
            NSMakeSize,
        )
        ww, hh = 560, 520
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, ww, hh),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Hermes Pong — Claude stream")
        self.window.setLevel_(NSStatusWindowLevel + 3)
        self.window.setReleasedWhenClosed_(False)
        try:
            self.window.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.08, 0.09, 1.0)
            )
        except Exception:
            pass
        content = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, ww, hh))
        self.statusLabel = lbl(
            "Live view of what Hermes sent + Claude tmux pane",
            NSMakeRect(12, hh - 28, ww - 24, 18),
            size=11,
            secondary=True,
        )
        content.addSubview_(self.statusLabel)

        scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(12, 44, ww - 24, hh - 80))
        scroll.setHasVerticalScroller_(True)
        scroll.setBorderType_(1)
        tv = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, ww - 40, hh - 80))
        tv.setEditable_(False)
        tv.setRichText_(False)
        try:
            tv.setFont_(NSFont.userFixedPitchFontOfSize_(11.0))
            tv.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.9, 1.0))
            tv.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.06, 1.0))
        except Exception:
            pass
        scroll.setDocumentView_(tv)
        self.scroll = scroll
        self.textView = tv
        content.addSubview_(scroll)
        content.addSubview_(btn("Refresh", "refresh:", NSMakeRect(12, 10, 90, 28), self))
        content.addSubview_(btn("Close", "closeStream:", NSMakeRect(ww - 100, 10, 84, 28), self))
        self.window.setContentView_(content)

    @python_method
    def _arm(self):
        if self.timer:
            try:
                self.timer.invalidate()
            except Exception:
                pass
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.2, self, "refresh:", None, True
        )

    def refresh_(self, sender):
        if self.textView is None:
            return
        body = claude_stream_text(self.session)
        self.textView.setString_(body)
        # scroll to end
        try:
            length = len(body)
            self.textView.scrollRangeToVisible_((length, 0))
        except Exception:
            pass
        if self.statusLabel:
            self.statusLabel.setStringValue_(
                f"Live · {time.strftime('%H:%M:%S')} · session {self.session or 'auto'}"
            )

    def closeStream_(self, sender):
        if self.timer:
            try:
                self.timer.invalidate()
            except Exception:
                pass
            self.timer = None
        if self.window:
            self.window.orderOut_(None)


def open_claude_stream(session: str | None = None):
    global _STREAM
    if _STREAM is None:
        _STREAM = ClaudeStreamController.alloc().init()
    _STREAM.open_for_session(session)


def show_pair_persist_tip(pair_name: str = "") -> None:
    """
    After connect: pair survives app quit until Kill.
    Always on top of other windows (including Terminal).
    Don't remind me → ~/.hermes-pong/dont-remind-pair-persist
    """
    flag = Path.home() / ".hermes-pong" / "dont-remind-pair-persist"
    if flag.exists():
        return
    label = pair_name or "this pair"
    alert = NSAlert.alloc().init()
    alert.setMessageText_("Pair stays connected")
    alert.setInformativeText_(
        f"“{label}” stays linked until you hit Kill — even if you quit Hermes Pong.\n\n"
        "Link existing = keeps your Claude model, resume, and chat.\n"
        "New pair = two fresh Terminals (Claude starts clean).\n\n"
        "When Hermes delegates, watch the Claude window (or Watch Claude stream)."
    )
    alert.addButtonWithTitle_("Got it")
    alert.addButtonWithTitle_("Don't remind me")
    alert.setAlertStyle_(0)
    # Always front — never under Terminal / panel
    try:
        NSApp.activateIgnoringOtherApps_(True)
        w = alert.window()
        if w:
            w.setLevel_(NSStatusWindowLevel + 5)
            w.makeKeyAndOrderFront_(None)
    except Exception:
        pass
    resp = alert.runModal()
    if resp == NSAlertFirstButtonReturn + 1:
        try:
            flag.parent.mkdir(parents=True, exist_ok=True)
            flag.write_text("1\n")
            log("dont-remind-pair-persist set")
        except Exception as e:
            log(f"dont-remind write fail: {e}")


def _front_terminal_frame_cocoa():
    script = '''
    tell application "System Events"
        tell process "Terminal"
            try
                set w to front window
                set pos to position of w
                set sz to size of w
                return (item 1 of pos as text) & "," & (item 2 of pos as text) & "," & (item 1 of sz as text) & "," & (item 2 of sz as text)
            on error
                return "NONE"
            end try
        end tell
    end tell
    '''
    r = sh(f"osascript -e {repr(script)}").strip()
    if not r or r == "NONE" or "," not in r:
        return None
    try:
        x, y_top, w, h = [float(p) for p in r.split(",")]
    except ValueError:
        return None
    try:
        main_h = NSScreen.mainScreen().frame().size.height
    except Exception:
        main_h = 900.0
    return (x, main_h - y_top - h, w, h)


class _BorderView(NSView):
    color = None
    thickness = 5.0

    def drawRect_(self, rect):
        NSColor.clearColor().set()
        NSBezierPath.fillRect_(rect)
        c = self.color or NSColor.systemBlueColor()
        c.set()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(
                self.thickness / 2,
                self.thickness / 2,
                rect.size.width - self.thickness,
                rect.size.height - self.thickness,
            ),
            10,
            10,
        )
        path.setLineWidth_(self.thickness)
        path.stroke()


def clear_overlays():
    global _OVERLAYS
    for w in _OVERLAYS:
        try:
            w.orderOut_(None)
            w.close()
        except Exception:
            pass
    _OVERLAYS = []


def show_window_overlay(label: str, color_rgba, duration: float = 1.6):
    frame = _front_terminal_frame_cocoa()
    if not frame:
        return
    x, y, w, h = frame
    r, g, b, a = color_rgba
    color = NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, a)
    win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(x, y, w, h),
        NSWindowStyleMaskBorderless,
        NSBackingStoreBuffered,
        False,
    )
    win.setOpaque_(False)
    win.setBackgroundColor_(NSColor.clearColor())
    win.setIgnoresMouseEvents_(True)
    win.setLevel_(NSStatusWindowLevel)
    win.setHasShadow_(False)
    view = _BorderView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
    view.color = color
    win.setContentView_(view)
    win.orderFrontRegardless()
    _OVERLAYS.append(win)

    def _later():
        time.sleep(duration)
        try:
            win.orderOut_(None)
        except Exception:
            pass

    threading.Thread(target=_later, daemon=True).start()


def lbl(text, frame, bold=False, size=13.0, secondary=False):
    f = NSTextField.labelWithString_(text)
    f.setFont_(NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size))
    if secondary:
        try:
            f.setTextColor_(NSColor.secondaryLabelColor())
        except Exception:
            pass
    f.setFrame_(frame)
    f.setEditable_(False)
    f.setBordered_(False)
    f.setDrawsBackground_(False)
    try:
        f.setLineBreakMode_(NSLineBreakByWordWrapping)
        f.setMaximumNumberOfLines_(4)
    except Exception:
        pass
    return f


def btn(title, action, frame, target):
    b = NSButton.alloc().initWithFrame_(frame)
    b.setTitle_(title)
    b.setBezelStyle_(NSBezelStyleRounded)
    b.setTarget_(target)
    b.setAction_(action)
    return b


class GuideController(NSObject):
    """
    Click real Terminal windows to select them.
    Marks appear only in this popup — nothing drawn on the Terminals.
    No shell scripts injected into Claude chat.
    """

    window = None
    stepLabel = None
    titleLabel = None
    hermesMark = None
    claudeMark = None
    hintLabel = None
    cancelBtn = None
    timer = None
    monitor = None
    phase = None  # hermes | claude | wiring | None
    hermes_id = None
    claude_id = None
    pair_name = None
    parent = None
    baseline_id = None
    started = 0.0
    last_front = None

    GW = 400
    GH = 280

    def startLinkWithParent_(self, parent):
        self.parent = parent
        clear_overlays()  # never leave rings up
        self.phase = "hermes"
        self.hermes_id = None
        self.claude_id = None
        self.pair_name = next_pair_name()
        self.started = time.time()
        self.baseline_id = _front_terminal_id()
        self.last_front = self.baseline_id
        log(f"startLink click-select pair={self.pair_name} baseline={self.baseline_id}")
        self._ensure_window()
        self._render()
        self.window.center()
        # Keep guide visible but do not steal focus from Terminals
        self.window.orderFrontRegardless()
        self._install_click_monitor()
        self._arm_timer()

    @python_method
    def _ensure_window(self):
        if self.window is not None:
            return
        gw, gh = self.GW, self.GH
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, gw, gh),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Hermes Pong — Link")
        self.window.setLevel_(NSStatusWindowLevel + 4)
        self.window.setReleasedWhenClosed_(False)
        try:
            self.window.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.10, 0.10, 0.12, 1.0)
            )
        except Exception:
            pass
        content = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, gw, gh))
        self.stepLabel = lbl("Step 1 of 2", NSMakeRect(16, gh - 36, gw - 32, 18), size=11, secondary=True)
        self.titleLabel = lbl(
            "Click the HERMES Terminal window",
            NSMakeRect(16, gh - 68, gw - 32, 28),
            bold=True,
            size=15,
        )
        self.hermesMark = lbl("○  Hermes  —  not selected", NSMakeRect(16, gh - 120, gw - 32, 22), size=13)
        self.claudeMark = lbl("○  Claude  —  not selected", NSMakeRect(16, gh - 150, gw - 32, 22), size=13)
        self.hintLabel = lbl(
            "Click the Terminal window itself.\nNothing is drawn on it — the mark only appears here.",
            NSMakeRect(16, 56, gw - 32, 50),
            size=12,
            secondary=True,
        )
        self.cancelBtn = btn("Cancel", "cancelLink:", NSMakeRect(gw - 100, 14, 84, 32), self)
        content.addSubview_(self.stepLabel)
        content.addSubview_(self.titleLabel)
        content.addSubview_(self.hermesMark)
        content.addSubview_(self.claudeMark)
        content.addSubview_(self.hintLabel)
        content.addSubview_(self.cancelBtn)
        self.window.setContentView_(content)

    @python_method
    def _title_for(self, wid):
        if not wid:
            return ""
        for i, t in list_terminal_windows():
            if i == str(wid):
                return t[:48]
        return f"window {wid}"

    @python_method
    def _render(self):
        if self.phase == "hermes":
            self.stepLabel.setStringValue_("Step 1 of 2")
            self.titleLabel.setStringValue_("Click the HERMES Terminal window")
            self.hintLabel.setStringValue_(
                "Click the Terminal that runs Hermes.\nSelection mark only shows in this popup."
            )
        elif self.phase == "claude":
            self.stepLabel.setStringValue_("Step 2 of 2")
            self.titleLabel.setStringValue_("Click the CLAUDE Terminal window")
            self.hintLabel.setStringValue_(
                "Click a different Terminal for Claude.\nNo scripts will be typed into Claude chat."
            )
        elif self.phase == "wiring":
            self.stepLabel.setStringValue_("Linking…")
            self.titleLabel.setStringValue_("Pairing without touching Claude chat")
            self.hintLabel.setStringValue_("Registering windows. Hermes and Claude keep their own UIs.")
        elif self.phase == "done":
            self.stepLabel.setStringValue_("Done")
            self.titleLabel.setStringValue_("Linked")
            self.hintLabel.setStringValue_("Work stays in each window. Bridge paste+Enter only.")

        if self.hermes_id:
            self.hermesMark.setStringValue_(f"✓  Hermes  —  {self._title_for(self.hermes_id)}")
        else:
            self.hermesMark.setStringValue_("○  Hermes  —  not selected")
        if self.claude_id:
            self.claudeMark.setStringValue_(f"✓  Claude  —  {self._title_for(self.claude_id)}")
        else:
            self.claudeMark.setStringValue_("○  Claude  —  not selected")

    @python_method
    def _install_click_monitor(self):
        self._remove_click_monitor()
        try:
            from AppKit import NSEvent, NSEventMaskLeftMouseDown

            def handler(event):
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    0.12, self, "afterClick:", None, False
                )

            mon = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
                NSEventMaskLeftMouseDown, handler
            )
            self.monitor = mon
            log(f"click monitor mon={mon is not None}")
        except Exception as e:
            log(f"click monitor fail: {e}")
            self.monitor = None

    @python_method
    def _remove_click_monitor(self):
        if self.monitor is not None:
            try:
                from AppKit import NSEvent
                NSEvent.removeMonitor_(self.monitor)
            except Exception:
                pass
            self.monitor = None

    @python_method
    def _arm_timer(self):
        if self.timer:
            try:
                self.timer.invalidate()
            except Exception:
                pass
        # Also poll front window (works even without Accessibility for global monitor)
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.2, self, "tick:", None, True
        )

    @python_method
    def _stop_timer(self):
        if self.timer:
            try:
                self.timer.invalidate()
            except Exception:
                pass
            self.timer = None

    def afterClick_(self, timer):
        self._try_select_front(force=True)

    def tick_(self, timer):
        if self.phase not in ("hermes", "claude"):
            return
        if time.time() - self.started > 60:
            self.phase = None
            self.titleLabel.setStringValue_("Timed out")
            self.hintLabel.setStringValue_("Try Link again and click a Terminal window.")
            self._stop_timer()
            self._remove_click_monitor()
            return
        # ignore first moment so opening popup doesn't grab current front
        if time.time() - self.started < 0.5:
            return
        self._try_select_front(force=False)

    @python_method
    def _try_select_front(self, force):
        wid = _front_terminal_id()
        if not wid:
            return
        if not force and wid == self.last_front:
            return
        # need a change from baseline for first pick unless force from click monitor
        if self.phase == "hermes":
            if wid == self.baseline_id and not force:
                # still allow if user clicked same and force (they re-clicked it)
                if not force:
                    self.last_front = wid
                    return
            if force or wid != self.baseline_id or wid != self.last_front:
                self._accept(wid)
        elif self.phase == "claude":
            if wid == self.hermes_id:
                self.hintLabel.setStringValue_("That’s Hermes. Click the other Terminal for Claude.")
                self.last_front = wid
                return
            if force or wid != self.last_front:
                self._accept(wid)
        self.last_front = wid

    @python_method
    def _accept(self, wid):
        if self.phase == "hermes":
            self.hermes_id = wid
            self.phase = "claude"
            self.started = time.time()
            self.baseline_id = wid
            self.last_front = wid
            log(f"selected HERMES id={wid} (popup mark only)")
            self._render()
        elif self.phase == "claude":
            if wid == self.hermes_id:
                return
            self.claude_id = wid
            self.phase = "wiring"
            log(f"selected CLAUDE id={wid} (popup mark only)")
            self._render()
            self._stop_timer()
            self._remove_click_monitor()
            hid, cid, name, parent = self.hermes_id, self.claude_id, self.pair_name, self.parent

            def work():
                try:
                    # Soft link: no junk in Claude chat; each keeps its UI
                    wire_pair(name, hid, cid)
                finally:
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "finishOk:", name, False
                    )

            threading.Thread(target=work, daemon=True).start()

    def finishOk_(self, name):
        self.phase = "done"
        self._render()
        self.titleLabel.setStringValue_(f"Linked · {name}")
        if self.parent:
            self.parent.refreshUI_(None)
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "showPairTip:", str(name), False
        )
        # Always open stream so you see what Hermes sends even if Claude UI is separate
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "openStreamAfterLink:", str(name), False
        )
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.4, self, "closeGuideTimer:", None, False
        )

    def showPairTip_(self, name):
        show_pair_persist_tip(str(name) if name else "")

    def openStreamAfterLink_(self, name):
        open_claude_stream(str(name) if name else None)

    def closeGuideTimer_(self, timer):
        self.closeGuide()

    def cancelLink_(self, sender):
        self.phase = None
        self._stop_timer()
        self._remove_click_monitor()
        clear_overlays()
        self.closeGuide()

    def closeGuide(self):
        self.phase = None
        self._stop_timer()
        self._remove_click_monitor()
        if self.window:
            self.window.orderOut_(None)

class AppDelegate(NSObject):
    window = None
    statusLabel = None
    listContainer = None
    pair_buttons = None
    guide = None

    def applicationDidFinishLaunching_(self, notification):
        log("applicationDidFinishLaunching Hermes Pong panel")
        try:
            NSProcessInfo.processInfo().setProcessName_("Hermes Pong")
            info = NSBundle.mainBundle().infoDictionary()
            if info is not None:
                info["CFBundleName"] = "Hermes Pong"
                info["CFBundleDisplayName"] = "Hermes Pong"
        except Exception:
            pass

        # Regular so the control window is visible; Dock stays HermesPong main app.
        # Accessory alone sometimes never surfaces the panel window.
        try:
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
        except Exception:
            pass

        if ICON.exists():
            img = NSImage.alloc().initWithContentsOfFile_(str(ICON))
            if img:
                img.setSize_(NSMakeSize(128, 128))
                NSApp.setApplicationIconImage_(img)

        self.pair_buttons = []
        self.guide = GuideController.alloc().init()
        self._build_window()
        self.refreshUI_(None)
        NSApp.activateIgnoringOtherApps_(True)
        if self.window:
            self.window.makeKeyAndOrderFront_(None)
        log("ready")

    @python_method
    def _build_window(self):
        style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, W, H),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Hermes Pong")
        self.window.center()
        # Always above normal apps (Terminal, Claude, etc.)
        self.window.setLevel_(NSStatusWindowLevel + 2)
        self.window.setReleasedWhenClosed_(False)
        try:
            self.window.setCollectionBehavior_(1 << 0)  # can join all spaces-ish; ignore fail
        except Exception:
            pass
        try:
            self.window.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.07, 0.07, 0.08, 1.0)
            )
        except Exception:
            pass

        content = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, W, H))
        y = H - PAD

        y -= 34
        content.addSubview_(
            lbl("Hermes  ↔  Claude", NSMakeRect(PAD, y, W - 2 * PAD, 34), bold=True, size=26)
        )
        y -= 24
        content.addSubview_(
            lbl(
                "Hermes Pong — two terminals, one bridge.",
                NSMakeRect(PAD, y, W - 2 * PAD, 20),
                size=13,
                secondary=True,
            )
        )

        y -= 30
        self.statusLabel = lbl("○ Idle", NSMakeRect(PAD, y, W - 2 * PAD, 20), size=13, secondary=True)
        content.addSubview_(self.statusLabel)

        y -= 120
        illu = ILLU if ILLU.exists() else Path(
            "/Users/dylandemnard/DigitalBrain/Boreal/tools/hermes-claude-app/resources/pair-illustration.png"
        )
        if illu.exists():
            nsimg = NSImage.alloc().initWithContentsOfFile_(str(illu))
            if nsimg:
                iv = NSImageView.alloc().initWithFrame_(NSMakeRect(PAD, y, W - 2 * PAD, 110))
                iv.setImage_(nsimg)
                iv.setImageScaling_(NSImageScaleProportionallyUpOrDown)
                iv.setImageAlignment_(NSImageAlignCenter)
                content.addSubview_(iv)

        y -= 36
        content.addSubview_(lbl("SETUP", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True))

        y -= 44
        content.addSubview_(btn("New pair", "startFresh:", NSMakeRect(PAD, y, W - 2 * PAD, 38), self))
        y -= 36
        content.addSubview_(
            lbl(
                "Opens 2 new Terminals (Hermes + Claude). Claude starts clean.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 32),
                size=12,
                secondary=True,
            )
        )

        y -= 48
        content.addSubview_(
            btn("Link existing terminals", "connectWindows:", NSMakeRect(PAD, y, W - 2 * PAD, 38), self)
        )
        y -= 48
        content.addSubview_(
            lbl(
                "Pick your open Hermes + Claude windows. Keeps Claude model, resume, and chat. Nothing injected into Claude.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 44),
                size=12,
                secondary=True,
            )
        )

        y -= 48
        content.addSubview_(
            btn("Watch Claude stream", "watchStream:", NSMakeRect(PAD, y, W - 2 * PAD, 38), self)
        )
        y -= 36
        content.addSubview_(
            lbl(
                "Live view of what Hermes actually sent (tmux pane + last-sent).",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 32),
                size=12,
                secondary=True,
            )
        )

        y -= 40
        content.addSubview_(
            lbl("ACTIVE PAIRS", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True)
        )

        y -= 200
        self.listContainer = NSView.alloc().initWithFrame_(NSMakeRect(PAD, y, W - 2 * PAD, 190))
        content.addSubview_(self.listContainer)

        half = (W - 2 * PAD - 12) / 2
        content.addSubview_(btn("Refresh", "refreshUI:", NSMakeRect(PAD, 24, half, 36), self))
        content.addSubview_(
            btn("Close Panel", "quitPanel:", NSMakeRect(PAD + half + 12, 24, half, 36), self)
        )

        self.window.setContentView_(content)

    @python_method
    def _rebuild_list(self):
        for sub in list(self.listContainer.subviews()):
            sub.removeFromSuperview()
        self.pair_buttons = []
        pairs = list_pairs()
        if not pairs:
            self.listContainer.addSubview_(
                lbl("No pairs yet — use New pair.", NSMakeRect(0, 150, W - 2 * PAD, 20), size=12, secondary=True)
            )
            return
        y = 150
        for name in pairs:
            row = NSView.alloc().initWithFrame_(NSMakeRect(0, y - 8, W - 2 * PAD, 44))
            row.addSubview_(lbl(f"●  {name}", NSMakeRect(0, 12, 200, 20), bold=True, size=13))
            b1 = btn("Front", "frontPair:", NSMakeRect(210, 6, 70, 30), self)
            b2 = btn("Kill", "killPair:", NSMakeRect(288, 6, 70, 30), self)
            b1.setIdentifier_(name)
            b2.setIdentifier_(name)
            row.addSubview_(b1)
            row.addSubview_(b2)
            self.listContainer.addSubview_(row)
            self.pair_buttons.append((b1, b2, name))
            y -= 48

    def startFresh_(self, sender):
        def work():
            name = start_fresh()
            time.sleep(0.2)
            self.performSelectorOnMainThread_withObject_waitUntilDone_("refreshUI:", None, False)
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "showPairTip:", str(name or ""), False
            )

        threading.Thread(target=work, daemon=True).start()

    def showPairTip_(self, name):
        show_pair_persist_tip(str(name) if name else "")

    def connectWindows_(self, sender):
        # Instant guide on main thread — no 40s notification lag
        log("connectWindows_ → guide")
        if self.guide is None:
            self.guide = GuideController.alloc().init()
        self.guide.startLinkWithParent_(self)

    def watchStream_(self, sender):
        pairs = list_pairs()
        open_claude_stream(pairs[0] if pairs else None)

    def frontPair_(self, sender):
        name = sender.identifier()
        if name:
            bring_to_front(str(name))

    def killPair_(self, sender):
        name = sender.identifier()
        if name:
            kill_pair(str(name))
            self.refreshUI_(None)

    def refreshUI_(self, sender):
        pairs = list_pairs()
        if pairs:
            self.statusLabel.setStringValue_(f"● {len(pairs)} active  ·  {', '.join(pairs)}")
        else:
            self.statusLabel.setStringValue_("○ Idle  ·  no pair running")
        self._rebuild_list()

    def quitPanel_(self, sender):
        if self.guide:
            self.guide.closeGuide()
        clear_overlays()
        if self.window:
            self.window.close()
        NSApp.terminate_(None)

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        return True


def main():
    import sys

    log(f"main enter args={sys.argv}")
    try:
        NSProcessInfo.processInfo().setProcessName_("Hermes Pong")
        info = NSBundle.mainBundle().infoDictionary()
        if info is not None:
            info["CFBundleName"] = "Hermes Pong"
            info["CFBundleDisplayName"] = "Hermes Pong"
    except Exception as e:
        log(f"rename skip: {e}")

    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    app.run()


if __name__ == "__main__":
    main()

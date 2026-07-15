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
)
from Foundation import NSMakeSize, NSProcessInfo, NSBundle

HERMES_BLUE = (0x26 / 255.0, 0x02 / 255.0, 0xF1 / 255.0, 1.0)
CLAUDE_ORANGE = (0xD9 / 255.0, 0x77 / 255.0, 0x56 / 255.0, 1.0)

_OVERLAYS: list = []

LOG = Path.home() / "Library" / "Logs" / "HermesPong.log"
HERE = Path(__file__).resolve().parent
ICON = HERE / "AppIcon-1024.png"
ILLU = HERE / "pair-illustration.png"

W, H = 460, 680
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
    name = name or next_pair_name()
    sh(f"tmux has-session -t {name} 2>/dev/null && tmux kill-session -t {name} || true")
    sh(f"tmux new-session -d -s {name} -n Hermes")
    sh(f"tmux new-window -t {name}:1 -n Claude")
    sh(f"tmux send-keys -t {name}:1 'cd ~ && claude' Enter")
    bring_to_front(name)
    log(f"start_fresh {name}")
    return name


def bring_to_front(name: str):
    sh(
        f'''osascript -e 'tell application "Terminal" to activate' '''
        f''' -e 'tell application "Terminal" to do script "tmux attach -t {name}"' '''
    )


def kill_pair(name: str):
    sh(f"tmux kill-session -t {name} 2>/dev/null || true")
    log(f"killed {name}")


def _mouse_down() -> bool:
    try:
        from Quartz import (
            CGEventSourceButtonState,
            kCGEventSourceStateCombinedSessionState,
            kCGMouseButtonLeft,
        )
        return bool(
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)
        )
    except Exception:
        return False


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


def wire_pair(name: str, w1: str, w2: str):
    sh(f"tmux new-session -d -s {name} -n Hermes 2>/dev/null || true")
    sh(f"tmux new-window -t {name}:1 -n Claude 2>/dev/null || true")
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "tmux attach -t {name}:0" in window id {w1}' '''
    )
    time.sleep(0.6)
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "tmux attach -t {name}:1 || tmux new-window -t {name}:1 -n Claude; tmux attach -t {name}:1" in window id {w2}' '''
    )
    time.sleep(0.4)
    sh(f"tmux send-keys -t {name}:1 'cd ~ && claude' Enter")
    sh('''osascript -e 'tell application "Terminal" to activate' ''')
    log(f"wired {name} w1={w1} w2={w2}")


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
    Pick Terminals by listing them as buttons (by window id).
    No mouse-click detection — always works.
    """

    window = None
    titleLabel = None
    stepLabel = None
    listView = None
    cancelBtn = None
    refreshBtn = None
    phase = None  # hermes | claude | None
    hermes_id = None
    pair_name = None
    parent = None
    win_buttons = None

    GW = 420
    GH = 360

    def startLinkWithParent_(self, parent):
        self.parent = parent
        clear_overlays()
        self.phase = "hermes"
        self.hermes_id = None
        self.pair_name = next_pair_name()
        self.win_buttons = []
        log(f"startLink list-picker pair={self.pair_name}")
        self._ensure_window()
        self._show_step(
            "Step 1 of 2 — HERMES",
            "Pick the Terminal that should be Hermes:",
        )
        self._rebuild_window_list()
        self.window.center()
        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

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
        self.window.setLevel_(NSStatusWindowLevel + 1)
        self.window.setReleasedWhenClosed_(False)
        try:
            self.window.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.10, 0.10, 0.12, 1.0)
            )
        except Exception:
            pass
        content = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, gw, gh))
        self.stepLabel = lbl(
            "Step 1 of 2", NSMakeRect(16, gh - 36, gw - 32, 18), size=11, secondary=True
        )
        self.titleLabel = lbl(
            "Pick HERMES Terminal", NSMakeRect(16, gh - 64, gw - 32, 24), bold=True, size=15
        )
        self.listView = NSView.alloc().initWithFrame_(NSMakeRect(16, 56, gw - 32, gh - 140))
        self.refreshBtn = btn("Refresh list", "refreshList:", NSMakeRect(16, 14, 120, 32), self)
        self.cancelBtn = btn("Cancel", "cancelLink:", NSMakeRect(gw - 100, 14, 84, 32), self)
        content.addSubview_(self.stepLabel)
        content.addSubview_(self.titleLabel)
        content.addSubview_(self.listView)
        content.addSubview_(self.refreshBtn)
        content.addSubview_(self.cancelBtn)
        self.window.setContentView_(content)

    def _show_step(self, step, title):
        if self.stepLabel:
            self.stepLabel.setStringValue_(step)
        if self.titleLabel:
            self.titleLabel.setStringValue_(title)
        log(f"guide step={step} title={title}")

    def refreshList_(self, sender):
        self._rebuild_window_list()

    def _rebuild_window_list(self):
        if self.listView is None:
            return
        for sub in list(self.listView.subviews()):
            sub.removeFromSuperview()
        self.win_buttons = []
        wins = list_terminal_windows()
        if not wins:
            self.listView.addSubview_(
                lbl(
                    "No Terminal windows found. Open two Terminals, then Refresh list.",
                    NSMakeRect(0, 120, self.GW - 32, 60),
                    size=12,
                    secondary=True,
                )
            )
            return
        y = self.GH - 160
        for wid, title in wins:
            if self.phase == "claude" and wid == self.hermes_id:
                label = f"✓ HERMES  {title}"
                row = lbl(label, NSMakeRect(0, y, self.GW - 32, 28), size=11, secondary=True)
                self.listView.addSubview_(row)
            else:
                b = btn(f"→  {title}", "pickWindow:", NSMakeRect(0, y, self.GW - 32, 32), self)
                b.setIdentifier_(wid)
                self.listView.addSubview_(b)
                self.win_buttons.append(b)
            y -= 40
            if y < 0:
                break

    def pickWindow_(self, sender):
        wid = str(sender.identifier()) if sender.identifier() else ""
        log(f"pickWindow id={wid} phase={self.phase}")
        if not wid.isdigit():
            return
        self._accept_window(wid)

    def _accept_window(self, wid: str):
        if self.phase == "hermes":
            self.hermes_id = wid
            osascript(
                "tell application \"Terminal\"\n"
                "  try\n"
                f"    set custom title of window id {wid} to \"● HERMES\"\n"
                f"    set index of window id {wid} to 1\n"
                "    activate\n"
                "  end try\n"
                "end tell\n"
            )
            show_window_overlay("HERMES", HERMES_BLUE)
            self.phase = "claude"
            self._show_step(
                "Step 2 of 2 — CLAUDE",
                "Pick the OTHER Terminal for Claude:",
            )
            self._rebuild_window_list()
            log(f"accepted HERMES id={wid}")
        elif self.phase == "claude":
            if wid == self.hermes_id:
                self._show_step("Same window", "Pick a different Terminal for Claude.")
                return
            osascript(
                "tell application \"Terminal\"\n"
                "  try\n"
                f"    set custom title of window id {wid} to \"● CLAUDE\"\n"
                f"    set index of window id {wid} to 1\n"
                "    activate\n"
                "  end try\n"
                "end tell\n"
            )
            show_window_overlay("CLAUDE", CLAUDE_ORANGE)
            self.phase = "wiring"
            self._show_step("Linking…", f"Wiring “{self.pair_name}”…")
            for sub in list(self.listView.subviews()):
                sub.removeFromSuperview()
            hid, cid, name = self.hermes_id, wid, self.pair_name
            log(f"accepted CLAUDE id={wid}; wiring {name}")

            def work():
                try:
                    wire_pair(name, hid, cid)
                finally:
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "finishOk:", name, False
                    )

            threading.Thread(target=work, daemon=True).start()

    def finishOk_(self, name):
        self._show_step("Linked", f"Pair “{name}” is ready.")
        if self.parent:
            self.parent.refreshUI_(None)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.2, self, "closeGuideTimer:", None, False
        )

    def closeGuideTimer_(self, timer):
        self.closeGuide()
        clear_overlays()

    def cancelLink_(self, sender):
        self.phase = None
        clear_overlays()
        self.closeGuide()

    def closeGuide(self):
        self.phase = None
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

        # Accessory: no second Dock icon. Main HermesPong.app owns Dock + app menu Quit.
        try:
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        except Exception:
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)

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
        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setReleasedWhenClosed_(False)
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
        y -= 24
        content.addSubview_(
            lbl(
                "Creates another Hermes + Claude pair (keeps existing ones).",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 20),
                size=12,
                secondary=True,
            )
        )

        y -= 48
        content.addSubview_(
            btn("Link two open Terminals", "connectWindows:", NSMakeRect(PAD, y, W - 2 * PAD, 38), self)
        )
        y -= 24
        content.addSubview_(
            lbl(
                "Opens a window list — tap each Terminal in the guide.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 20),
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
            start_fresh()
            time.sleep(0.2)
            self.performSelectorOnMainThread_withObject_waitUntilDone_("refreshUI:", None, False)

        threading.Thread(target=work, daemon=True).start()

    def connectWindows_(self, sender):
        # Instant guide on main thread — no 40s notification lag
        log("connectWindows_ → guide")
        if self.guide is None:
            self.guide = GuideController.alloc().init()
        self.guide.startLinkWithParent_(self)

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

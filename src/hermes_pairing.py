#!/usr/bin/env python3
"""
Hermes_Pairing control window — multi-pair list, kill/rejoin, dark UI.
"""

from __future__ import annotations

import os
import re
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
    NSScrollView,
    NSMakeRect,
    NSBackingStoreBuffered,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSFloatingWindowLevel,
    NSFont,
    NSImage,
    NSColor,
    NSApplicationActivationPolicyRegular,
    NSLineBreakByWordWrapping,
    NSBezelStyleRounded,
    NSImageScaleProportionallyUpOrDown,
    NSImageAlignCenter,
)
from Foundation import NSMakeSize

SESSION_PREFIXES = ("hermes-claude", "hermes-pair")
LOG = Path.home() / "Library" / "Logs" / "Hermes_Pairing.log"
HERE = Path(__file__).resolve().parent
ICON = HERE / "AppIcon-1024.png"
ILLU = HERE / "pair-illustration.png"

W, H = 460, 680
PAD = 28


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


def notify(title: str, message: str = ""):
    """Deliver notification with Hermes_Pairing branding when possible."""
    try:
        from Foundation import NSUserNotification, NSUserNotificationCenter
        n = NSUserNotification.alloc().init()
        n.setTitle_(title)
        if message:
            n.setInformativeText_(message[:200])
        # Prefer delivered as this process (Panel.app → Hermes_Pairing icon)
        NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification_(n)
        return
    except Exception as e:
        log(f"NSUserNotification fail: {e}")
    # Fallback: osascript (generic icon)
    safe_t = title.replace('"', "'")
    safe_m = message.replace('"', "'")[:200]
    sh(f'''osascript -e 'display notification "{safe_m}" with title "{safe_t}"' ''')


def list_pairs() -> list[str]:
    """All hermes pairing tmux sessions."""
    out = sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
    names = []
    for s in out.splitlines():
        s = s.strip()
        if not s:
            continue
        if (
            s == "hermes-claude"
            or s.startswith("hermes-claude-")
            or s.startswith("hermes-pair")
        ):
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
    notify("New pair", name)
    log(f"start_fresh created {name}; now={list_pairs()}")
    return name


def bring_to_front(name: str):
    sh(
        f'''osascript -e 'tell application "Terminal" to activate' '''
        f''' -e 'tell application "Terminal" to do script "tmux attach -t {name}"' '''
    )
    sh('''osascript -e 'tell application "System Events" to set frontmost of process "Terminal" to true' ''')


def kill_pair(name: str):
    sh(f"tmux kill-session -t {name} 2>/dev/null || true")
    notify("Killed", name)
    log(f"killed {name}; now={list_pairs()}")


def _front_terminal_id() -> str | None:
    """Return Terminal front window id, or None."""
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
    r = sh(f"osascript -e {repr(script)}").strip()
    return r if r.isdigit() else None


def _window_under_mouse() -> str | None:
    """Best-effort: Terminal window under cursor (needs Accessibility)."""
    script = '''
    tell application "System Events"
        set mousePos to current position of mouse
        set mouseX to item 1 of mousePos
        set mouseY to item 2 of mousePos
        tell process "Terminal"
            repeat with w in windows
                try
                    set pos to position of w
                    set sz to size of w
                    set x to item 1 of pos
                    set y to item 2 of pos
                    set wW to item 1 of sz
                    set wH to item 2 of sz
                    if mouseX ≥ x and mouseX ≤ (x + wW) and mouseY ≥ y and mouseY ≤ (y + wH) then
                        -- map AX window to Terminal id via index is hard; use title match later
                        set t to name of w
                        return t
                    end if
                end try
            end repeat
        end tell
    end tell
    return "NONE"
    '''
    # Prefer Terminal's own id of front window after user clicks (most reliable)
    return None


def pick_window(prompt: str, label: str, exclude_id: str | None = None) -> str | None:
    """
    Click-to-select: click a Terminal window and hold it frontmost ~1s.
    exclude_id avoids re-selecting the first window for the second pick.
    """
    notify("Hermes_Pairing", prompt + " — click it and keep it front for 1s")
    log(f"pick_window start label={label} exclude={exclude_id}")

    deadline = time.time() + 12.0
    last = None
    stable = 0

    while time.time() < deadline:
        wid = _front_terminal_id()
        if wid and wid != exclude_id:
            if wid == last:
                stable += 1
                if stable >= 4:  # ~1s at 0.25s poll
                    # tag window
                    sh(
                        f'''osascript -e 'tell application "Terminal" to try
                        set custom title of window id {wid} to "● {label}"
                    end try' '''
                    )
                    notify(f"{label} selected", f"Window {wid}")
                    log(f"pick_window ok label={label} id={wid}")
                    time.sleep(0.4)
                    return wid
            else:
                last = wid
                stable = 1
        else:
            # waiting for a different front window
            if wid == exclude_id:
                stable = 0
                last = None
        time.sleep(0.25)

    notify("Timed out", f"Click a Terminal for {label} and keep it front")
    log(f"pick_window timeout label={label}")
    return None


def connect_windows():
    name = next_pair_name()
    notify("Link Terminals", "1/2 — click HERMES Terminal, keep it front")
    w1 = pick_window("HERMES Terminal", "HERMES", exclude_id=None)
    if not w1:
        return
    notify("Link Terminals", "2/2 — click CLAUDE Terminal (different window)")
    w2 = pick_window("CLAUDE Terminal", "CLAUDE", exclude_id=w1)
    if not w2:
        return
    if w1 == w2:
        notify("Same window", "Need two different Terminal windows")
        log(f"connect_windows same id {w1}")
        return

    # Create detached session then attach each window as a client view
    sh(f"tmux new-session -d -s {name} -n Hermes 2>/dev/null || true")
    sh(f"tmux new-window -t {name}:1 -n Claude 2>/dev/null || true")
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "tmux attach -t {name}:0" in window id {w1}' '''
    )
    time.sleep(0.8)
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "tmux attach -t {name}:1 || tmux new-window -t {name}:1 -n Claude; tmux attach -t {name}:1" in window id {w2}' '''
    )
    time.sleep(0.5)
    sh(f"tmux send-keys -t {name}:1 'cd ~ && claude' Enter")
    sh('''osascript -e 'tell application "Terminal" to activate' ''')
    notify("Linked", name)
    log(f"connect_windows linked {name} w1={w1} w2={w2} sessions={list_pairs()}")


def lbl(text, frame, bold=False, size=13.0, secondary=False):
    f = NSTextField.labelWithString_(text)
    f.setFont_(
        NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
    )
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
        f.setMaximumNumberOfLines_(3)
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


class AppDelegate(NSObject):
    window = None
    statusLabel = None
    listContainer = None
    pair_buttons = None  # keep refs

    def applicationDidFinishLaunching_(self, notification):
        log("applicationDidFinishLaunching")
        try:
            from AppKit import NSApplicationActivationPolicyAccessory
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        except Exception:
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
        if ICON.exists():
            img = NSImage.alloc().initWithContentsOfFile_(str(ICON))
            if img:
                img.setSize_(NSMakeSize(128, 128))
                NSApp.setApplicationIconImage_(img)
        self.pair_buttons = []
        self._build_window()
        self.refreshUI_(None)
        NSApp.activateIgnoringOtherApps_(True)
        if self.window:
            self.window.makeKeyAndOrderFront_(None)
        log("ready")

    def _build_window(self):
        style = (
            NSWindowStyleMaskTitled
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable
        )
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, W, H),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Hermes_Pairing")
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
                "Two terminals. One bridge. Multiple pairs OK.",
                NSMakeRect(PAD, y, W - 2 * PAD, 20),
                size=13,
                secondary=True,
            )
        )

        y -= 30
        self.statusLabel = lbl(
            "○ Idle",
            NSMakeRect(PAD, y, W - 2 * PAD, 20),
            size=13,
            secondary=True,
        )
        content.addSubview_(self.statusLabel)

        y -= 120
        illu = ILLU if ILLU.exists() else Path(
            "/Users/dylandemnard/DigitalBrain/Boreal/tools/hermes-claude-app/resources/pair-illustration.png"
        )
        if illu.exists():
            nsimg = NSImage.alloc().initWithContentsOfFile_(str(illu))
            if nsimg:
                iv = NSImageView.alloc().initWithFrame_(
                    NSMakeRect(PAD, y, W - 2 * PAD, 110)
                )
                iv.setImage_(nsimg)
                iv.setImageScaling_(NSImageScaleProportionallyUpOrDown)
                iv.setImageAlignment_(NSImageAlignCenter)
                content.addSubview_(iv)

        y -= 36
        content.addSubview_(
            lbl("SETUP", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True)
        )

        y -= 44
        content.addSubview_(
            btn("New pair", "startFresh:", NSMakeRect(PAD, y, W - 2 * PAD, 38), self)
        )
        y -= 24
        content.addSubview_(
            lbl(
                "Creates another Hermes + Claude pair (does not replace existing ones).",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 20),
                size=12,
                secondary=True,
            )
        )

        y -= 48
        content.addSubview_(
            btn(
                "Link two open Terminals",
                "connectWindows:",
                NSMakeRect(PAD, y, W - 2 * PAD, 38),
                self,
            )
        )
        y -= 24
        content.addSubview_(
            lbl(
                "Wire two Terminal windows you already opened into a new pair.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 20),
                size=12,
                secondary=True,
            )
        )

        y -= 40
        content.addSubview_(
            lbl("ACTIVE PAIRS", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True)
        )

        # dynamic list area
        y -= 200
        self.listContainer = NSView.alloc().initWithFrame_(
            NSMakeRect(PAD, y, W - 2 * PAD, 190)
        )
        content.addSubview_(self.listContainer)

        # footer
        half = (W - 2 * PAD - 12) / 2
        content.addSubview_(
            btn("Refresh", "refreshUI:", NSMakeRect(PAD, 24, half, 36), self)
        )
        content.addSubview_(
            btn("Close Panel", "quitPanel:", NSMakeRect(PAD + half + 12, 24, half, 36), self)
        )

        self.window.setContentView_(content)

    def _rebuild_list(self):
        # clear
        for sub in list(self.listContainer.subviews()):
            sub.removeFromSuperview()
        self.pair_buttons = []

        pairs = list_pairs()
        if not pairs:
            self.listContainer.addSubview_(
                lbl(
                    "No pairs yet — use New pair.",
                    NSMakeRect(0, 150, W - 2 * PAD, 20),
                    size=12,
                    secondary=True,
                )
            )
            return

        y = 150
        for name in pairs:
            row = NSView.alloc().initWithFrame_(NSMakeRect(0, y - 8, W - 2 * PAD, 44))
            row.addSubview_(
                lbl(f"●  {name}", NSMakeRect(0, 12, 200, 20), bold=True, size=13)
            )
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
            time.sleep(0.3)
            self.refreshUI_(None)

        threading.Thread(target=work, daemon=True).start()

    def connectWindows_(self, sender):
        def work():
            connect_windows()
            time.sleep(0.3)
            self.refreshUI_(None)

        threading.Thread(target=work, daemon=True).start()

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
        # close window only; menu bar Swift app keeps running
        if self.window:
            self.window.close()
        NSApp.terminate_(None)

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        return True


def main():
    import sys
    log(f"main enter args={sys.argv}")

    # Appear as Hermes_Pairing in the menu bar (not "Python") when possible
    try:
        from Foundation import NSProcessInfo, NSBundle
        NSProcessInfo.processInfo().setProcessName_("Hermes_Pairing")
        info = NSBundle.mainBundle().infoDictionary()
        if info is not None:
            info["CFBundleName"] = "Hermes_Pairing"
            info["CFBundleDisplayName"] = "Hermes_Pairing"
    except Exception as e:
        log(f"rename skip: {e}")

    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    # Accessory: no second Dock icon (main Hermes_Pairing app owns the Dock)
    try:
        from AppKit import NSApplicationActivationPolicyAccessory
        app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    except Exception:
        app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    app.run()


if __name__ == "__main__":
    main()

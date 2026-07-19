# Follow-up: port the control panel to Swift — ✅ DONE (v1.3)

**Status:** shipped 2026-07-17. The panel is now native Swift inside
`src/MenuBarApp.swift` (`PanelController` + `LinkGuideController` +
`Pairing`/`PairState` helpers). The nested `Panel.app`, its bash launcher, and
the entire Python/PyObjC runtime dependency are gone from the bundle.

## What changed

- Control panel window, pair list, New pair, Link existing (click-to-select
  guide), Front/Kill, per-pair autonomy alert (Every/Done/Full), and the
  pair-persist tip are all Swift/AppKit in the main app process.
- State contracts (`pairs.json`, `active-pair.json`, `settings.json`,
  `relay.pid`, `last-claude.txt` placeholder) are unchanged — verified by
  driving the UI and diffing writes, and by `pong-gate.py` reading
  Swift-written state (`BRIDGE_ON session=… mode=window autonomy=full`).
- The bundle now contains exactly one executable (the universal Mach-O) plus
  three stdlib-only Python CLIs as resources (`claude-delegate.py`,
  `claude-window-relay.py`, `pong-ledger.py`). The notarization
  script-executable risk (old B1 contingency) no longer exists.
- `setup.sh` no longer creates PyObjC venvs; `build-app.sh` no longer
  requires `venv/`.

## Superseded

`src/hermes_pairing.py` was removed in v1.3.1 (Swift panel is the only UI). It was
bundled or launched. Safe to delete after one release of soak time.

## Remaining runtime requirements (by design)

tmux, Hermes CLI, Claude Code CLI, Terminal.app — the things being bridged.
The window relay (`claude-window-relay.py`, window-mode links only) uses any
stdlib `python3`; no PyObjC.

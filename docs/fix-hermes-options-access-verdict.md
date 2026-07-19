# Verdict: APPROVE

## Summary

Claude implemented approach **A** (two-line Hermes hub). Hub height is **64** with matching `est` math. Line 1 is swatch + wider name + Front / Hide / Kill; line 2 is a left-aligned **Options** control (x=8, w=116) plus a discoverability hint — well inside `boxW ≈ 404`, so the old clip (Options ending ~380) is gone. `TeamOptionsSheetController.show` activates the app, centers, `makeKeyAndOrderFront`, then **`orderFrontRegardless`**, with `.floating` level so the sheet sits above the panel. Diff is small and scoped to `MenuBarApp.swift`. Build/install claimed green (not re-run here).

## Checks table

| Check | Result | Evidence |
|-------|--------|----------|
| Two-line hub `hermesH=64` | **PASS** | ~2672–2674; `est += 64 + …` ~2663 |
| Options not on cramped line 1 | **PASS** | Options ~2701–2702 at y=4; Front/Hide/Kill at y=33 |
| Options fully visible (no H-scroll need) | **PASS** | x=8 w=116 → ends 124 ≪ boxW~404 |
| Hint text for discoverability | **PASS** | “brief · project root · save team · windows” ~2703–2704 |
| Name still renames | **PASS** | `hermesNamePressed` on name button unchanged |
| Sheet fronting | **PASS** | activate + center + makeKeyAndOrderFront + orderFrontRegardless ~4034–4037; level `.floating` ~4050 |
| `teamOptionsPressed` still wired | **PASS** | `#selector(teamOptionsPressed(_:))` |
| Sheet features not stripped | **PASS** | No removal of Windows / Save team / project_root / team_brief in this diff |
| Activity Sent also tightened | **PASS** | Reply/Sent shifted left slightly (~2766–2769) |
| Diff mainly MenuBarApp.swift | **PASS** | 27-line change |
| build + install | **SKIP** | Claimed by Claude; layout is compile-safe |

### Layout math (default panel)

`boxW ≈ 460 − 2×28 = 404`

| Control | Frame | Right edge |
|---------|--------|------------|
| Kill (line 1) | x340 w46 | **386** (~18pt margin) |
| Options (line 2) | x8 w116 | **124** (safe) |
| Hint (line 2) | x132 w≈264 | **~396** (safe) |

## Blocking issues

None.

## Non-blocking nits

1. **Options is prominent, not full-width** — task allowed “full-width-ish or left-aligned prominent”; 116pt + hint meets accessibility intent.
2. **Line 1 Kill ends ~386** — tighter than Options was, but still inside boxW; if a vertical scroller steals width on some macOS versions, Kill is the first at risk, not Options.
3. **Did not re-smoke install/pkill** — trust claim; if Dylan still sees old UI, force-kill leftover HermesPong process once more.

## Acceptance mapping

| Acceptance | Status |
|------------|--------|
| Options fully visible without horizontal scroll | **PASS** |
| Click opens Team options frontmost | **PASS** (code path) |
| build-app / install | Claimed; not re-verified |
| Diff mainly MenuBarApp.swift | **PASS** |

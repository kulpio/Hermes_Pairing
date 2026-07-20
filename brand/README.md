# Pong — Brand Asset Package

Traced from the original mark (the "flash"). Two endpoints = the rally: **cyan top** (orchestrator), **magenta bottom** (agent).

## Colors
| Token | Hex | Use |
|---|---|---|
| Cyan | `#35d6ff` | top dot on dark |
| Cyan (light bg) | `#12b6e6` | top dot on white — brighter cyan washes out |
| Magenta | `#ff53c8` | bottom dot |
| Glyph on dark | `#e9f0f4` / `#f2f4f6` | flash body, dark UI |
| Glyph on light | `#333a40` | flash body, white bg |
| Inactive grey | `#9aa7ae` | empty / disabled state |
| Tile bg | `#0f151b` | app-icon / favicon squircle |

Type: **Space Grotesk** 700 (wordmark) · **IBM Plex Mono** 500 (eyebrow). Geometry: path `M34.6 35.5 L67 25.6 L53.3 48.5 L61.4 61.6 L29 71.5 L42.5 48.5 Z` in a 96×96 box; top dot (74,15), bottom dot (22,82), r 6.2 (grows at small sizes).

## Contents

### `brand/logo/` — master SVGs (scalable, use these first)
- `pong-mark-color.svg` — primary, dark UI (white flash, cyan/magenta dots)
- `pong-mark-color-glow.svg` — glowing dots (matches 3D node neon)
- `pong-mark-mono-white.svg` — all white, no color (1-color print, watermark)
- `pong-mark-grey.svg` — all dark-grey, white bg (1-color on light)
- `pong-mark-light-color.svg` — grey flash + colored dots, white bg
- `pong-mark-light-glow.svg` — grey flash + glowing colored dots, white bg
- `pong-wordmark-dark.svg` / `pong-wordmark-light.svg` — full lockup (mark + "Pong" + ORCHESTRATION eyebrow)

### `brand/favicon/` — web
- `favicon.svg` (squircle tile, colored) — modern browsers
- `favicon-16/32/48.png`, `favicon-180.png`, `favicon-512.png`, `apple-touch-icon-180.png`
```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" sizes="32x32" href="/favicon-32.png">
<link rel="apple-touch-icon" href="/apple-touch-icon-180.png">
```

### `brand/app-icon/`
- `pong-appicon-1024.png` — macOS/dock master (squircle tile). Drop into an `.iconset` / Assets.xcassets AppIcon.

### `brand/macos-menubar/` — status-bar icon
**`template/`** — `pongTemplate.png` (18pt) + `pongTemplate-2x.png` (36pt). *Rename the 2x to `pongTemplate@2x.png` on disk* (the `@` couldn't be written here). These are **template images** (pure black + alpha); macOS auto-tints for light/dark menu bars:
```swift
let img = NSImage(named: "pongTemplate")!   // both files, @2x auto-picked
img.isTemplate = true                        // system handles color
statusItem.button?.image = img
```
Use the template when you want the icon to follow the system (monochrome, always legible).

**`state/`** — colored, **non-template** icons that encode team status (white glyph reads on the dark menu bar). Sizes 18/36/44/64 + SVG:
| State | File | Meaning | Look |
|---|---|---|---|
| **Active** | `pong-active-*` | agents are working | glowing cyan/magenta dots |
| **Idle** | `pong-idle-*` | teams available, nothing running | flat cyan/magenta dots |
| **Empty** | `pong-empty-*` | no agents & no teams | grey, no color, no glow |
```swift
// set isTemplate = false for these — they carry their own color
func statusIcon(for s: TeamState) -> NSImage {
    let name = s == .active ? "pong-active-36" : s == .idle ? "pong-idle-36" : "pong-empty-36"
    let i = NSImage(named: name)!; i.isTemplate = false; return i
}
```
Swap the button image whenever team state changes. For an animated "working" pulse, breathe the dot glow (or cross-fade active↔idle) rather than swapping frames.

## Notes
- SVGs are the source of truth — regenerate PNGs at any size from them.
- On light backgrounds always use the `#12b6e6` cyan, never `#35d6ff`.
- The wordmark SVGs reference Space Grotesk / IBM Plex Mono by name; embed or outline the text if the viewer won't have the fonts.

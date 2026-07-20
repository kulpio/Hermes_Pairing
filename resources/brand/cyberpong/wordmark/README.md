# CyberPong — Wordmark (4a)

Wordmark only (no flash mark). Type: **Chakra Petch 700**, all caps, letter-spacing 0.14em. Two-tone: **CYBER** cyan / **PONG** magenta.

## Files
- `cyberpong-wordmark-dark.png` — neon version, white letters + cyan/magenta glow, **transparent bg** → place on dark UI. 3048×720.
- `cyberpong-wordmark-light.png` — colored letters (cyan `#0a9fce` / magenta `#e0359f`) + soft glow, **transparent bg** → place on white. 3048×720.
- `cyberpong-wordmark-dark.svg` / `-light.svg` — vector, flat two-tone (no glow). Scalable for print/large use.

## Notes
- The **PNGs carry the neon glow** (raster) — use them for the authentic 4a look. The **SVGs are flat two-tone** vectors for crisp scaling; the glow is a raster effect and isn't in the SVG.
- SVGs load Chakra Petch via Google Fonts `@import` — they render correctly in a browser. For fully self-contained files (print, offline), convert the text to outlines in your vector editor.
- Dark PNG letters are white — invisible on white; that's expected, it's built for dark backgrounds.

# Remaining work — Pong / HermesPong

**Canonical tree:** `/Users/dylandemnard/Personal/Projects/HermesPong`

## Done recently
- [x] Solid bodies (D1 transparency), glass ~10% see-through
- [x] Human: matte solid + **light behind** (not glowing body)
- [x] Team isolation on flow edges + FlowGraph seat-id guard
- [x] Flow packets = balls, no arrows
- [x] GPU: MSAA off, HDR/bloom off, idle `isPlaying=false`, render-loop pulse
- [x] Beachball: listPairs/snapshot/window recovery **off main thread**; poll 4s; menu 0.5s
- [x] Seat-sig skip full layoutSeats on poll

## P0 still open
1. Isolation E2E + CI `test_routing_isolation.py`
2. Confirm no beachball after 10s continuous orbit + tab clicks
3. Triangle/human face size (D3)

## P1
4. Toolbar chrome tokens (D5)
5. TRACKING KPI tiles
6. Single-team default view
7. Magenta timeline beads
8. YOU “HUMAN · OPERATOR” label

## P2
9. Cron UX polish
10. Visual regression vs design HTML
11. Bridge transport: tmux_paste pane registration (failed once today)


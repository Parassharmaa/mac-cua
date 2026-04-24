# Status

Background computer-use implementation — current state.

## Eval

    make eval     # builds + runs .build/release/cua-mcp eval

Most recent run: **14 pass · 0 fail · 2 skip**. Reproducible across
three consecutive runs. The two skips are external config, not
implementation gaps:

| skip                        | cause                                                            |
|-----------------------------|------------------------------------------------------------------|
| `slack_click_bg`            | Slack not running. Launch Slack to exercise this case.           |
| `chrome_closed_loop_click`  | Chrome → View → Developer → "Allow JavaScript from Apple Events" |

## What lands in the current binary

| feature                                                | status |
|--------------------------------------------------------|--------|
| Per-pid trusted event post via SkyLight bridge         | ✓      |
| Keyboard auth envelope (Chromium-gated)                | ✓      |
| Primer click `(-1, -1)` before Chromium pixel clicks   | ✓      |
| Window-local hit-test stamp (`CGEventSetWindowLocation`) | ✓    |
| AX enablement re-assert per snapshot (Chromium)        | ✓      |
| AX layer 2 — AXFocused/AXMain around AX actions        | ✓      |
| Reactive focus-steal preventer (NSWorkspace observer)  | ✓      |
| 3 s post-action suppression window                     | ✓      |
| AXESynthesizedIgnoreEventSourceID tagging              | ✓      |
| Figma-style 4-point cursor path                        | ✓      |
| Bezier arc motion with heading rotation                | ✓      |
| Idle heading NW (upper-left), matches OS cursor tilt   | ✓      |
| Click pulse + bloom halo                               | ✓      |
| Cursor on by default (`CUA_HIDE_CURSOR=1` to disable)  | ✓      |
| Tray popover with permission flow + cursor demo        | ✓      |
| SF Symbol menubar icon, adapts to light/dark           | ✓      |
| In-process Swift eval (no subprocess focus flicker)    | ✓      |
| Closed-loop action verification (Calc / TextEdit / Chrome) | ✓  |
| swift-format config + `make format`/`make lint`        | ✓      |

## What was removed

- Python test harness (`harness/*.py`, `broker.py`, etc.) — replaced by
  `.build/release/cua-mcp eval`.
- Polling `FocusGuard` from the hot path — reactive preventer now
  handles the steal-catch. The struct stays in the source for
  reference but is no longer wired into `BackgroundFocus`.

## Contracts verified by the eval

For every tool call against a non-frontmost target:

- **Frontmost unchanged**: `before != target && after == target` is the
  fail condition. Every case reports `before=iTerm2 after=iTerm2 stole=false`.
- **Cursor unmoved**: CGEvent-based position readback before/after
  shows identical coords for click and type.
- **Action landed**: closed-loop asserts for each destructive action:
  - `bg_calc_click` — `pre='0'` → `clean='1'` after clicking "1".
  - `bg_textedit_type_ascii` — `val='hello_bg'` after `type_text`.
  - `bg_textedit_type_cjk` — `val='日本語'`.
  - `chrome_tree_fresh` — second AX snapshot not smaller than first.

## Known limitations

- `chrome_closed_loop_click` needs the Chrome developer flag to run.
- Canvas apps (Blender GHOST, Unity, games) filter synthetic per-pid
  input entirely. Not tested; would require a brief frontmost
  activation to interact with.
- Chromium web-content right-click is coerced to left-click by the
  renderer filter on the per-pid path. AX-addressable right-click via
  element index (`perform_secondary_action("ShowMenu")`) works.

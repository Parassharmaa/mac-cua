# mac-cua-mcp harness

Side-by-side comparator harness: every test spawns both brokers as child
MCP processes and asserts identical behavior:
- `sky` — OpenAI Codex's bundled Sky CUA plugin via `sky_cua.py` broker
- `mac` — this repo's native Swift `cua-mcp` binary

## Layout

    harness/
      broker.py              shared MCP stdio subprocess client
      ax_util.py             AppleScript + tree-parsing helpers
      core_tools.py          9 core-tool functional tests
      test_error_contract.py 4 error-path contract checks
      test_press_key_vocab.py xdotool-style key vocab (25 specs)
      test_perf.py           get_app_state latency bench
      test_input_latency.py  tool-call → AX-visible-effect latency
      test_stability.py      100× get_app_state hammer — no leaks / zero errors
      run_all.py             runs every suite and prints scoreboard

## Run everything

    python3 -u harness/run_all.py

Total runtime ~4 minutes. Exit code 0 iff every suite passed.

## Results (last run)

    ✓  core tools (9)           64.8s   9/9 passed
    ✓  error contract (4)        4.5s   4/4 matched
    ✓  press_key vocab (25)    145.0s   25/25 accepted
    ✓  perf bench (4 apps)      18.9s   4 apps profiled

### perf bench: get_app_state latency (min of 3 samples)

    app         sky    mac
    Calculator  228ms   20ms   (mac 11× faster)
    TextEdit    120ms    5ms   (mac 26× faster)
    Finder      652ms   90ms   (mac  7× faster)
    Notes       980ms  1.7s    (sky  1.7× faster, 909-note sidebar)

### input latency: broker call → AX-visible effect (avg of 5 samples)

    op               sky     mac
    type_text 'X'    755ms   160ms   (mac 4.7× faster)
    press_key 'z'    882ms   195ms   (mac 4.5× faster)

Sky has ~600ms baseline overhead from its app-server RPC chain.

### stability: 100 back-to-back get_app_state on Calculator

    sky: 100/100 ok in 25.1s  (251ms/call)
    mac: 100/100 ok in  1.9s  ( 19ms/call)   mac 13× faster under load

Zero errors from either broker — no session leaks, no intermittent
failures, steady latency across the run.

## What each test covers

**core_tools.py** — one live-app scenario per tool:
- `list_apps` both return the same running-apps set
- `get_app_state` TextEdit tree shape valid in both
- `scroll` AXScrollDownByPage on TextEdit (scrollbar value moves)
- `press_key` 25 + 75 = 100 in Calculator (verified via tree readback)
- `click` 6 + 7 = 13 via element-index AXPress chain
- `type_text` appends marker to TextEdit (verified via AX value read)
- `set_value` sets TextEdit text area value directly
- `perform_secondary_action` AXRaise call accepted
- `drag` phased mouse-event sequence accepted

**test_error_contract.py** — error messages agree:
| Case | Expected substring (regex) |
| --- | --- |
| get_app_state on missing app | `not ?found` |
| click on stale element_index | `invalid element|no longer valid` |
| set_value on immutable element | `not settable` |
| scroll with bad direction | `scroll direction` |

**test_press_key_vocab.py** — 25 xdotool-style key specs:

    Return  Tab  BackSpace  Escape  Delete
    Left  Right  Up  Down  Home  End  Page_Up  Page_Down
    plus  minus  period
    KP_0  KP_5  KP_9
    F1  F5
    cmd+a  shift+Tab  alt+Return  cmd+shift+z

Each with fresh get_app_state prime (Sky invalidates its session on app
state changes, so re-priming between keys is mandatory).

**test_perf.py** — opens 4 apps, warms each broker, then times 3
back-to-back `get_app_state` calls per app per broker. Reports min latency.

## Known divergences (by design)

- **mac-cua doesn't enforce the get_app_state-first contract.** Sky
  rejects action tools if the target app hasn't been primed in the
  current session ("Computer Use is not active for X"). mac-cua will
  just execute them. Harness tests always prime explicitly.
- **mac-cua produces slightly more verbose tree output** (896 lines on
  Notes vs Sky's 168). Same nodes, more descriptors per line.
- **mac-cua routes synthetic input via `CGEventPostToPid`** for focus-
  agnostic delivery to native AppKit apps. Chrome/WebKit scroll still
  requires brief focus.

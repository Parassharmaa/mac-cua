# mac-cua-mcp

A native macOS Computer Use MCP server written in Swift, behavior-equivalent
to OpenAI Codex's bundled Sky CUA plugin — but faster, standalone, and
without the Codex app-server dependency.

Exposes 9 Computer Use tools over MCP stdio:

    list_apps                  get_app_state
    click                      press_key
    type_text                  set_value
    scroll                     drag
    perform_secondary_action

Each tool's behavior and error contract matches Sky's (verified by the
comparator harness). The stable interface lets any MCP client drive macOS
accessibility — Claude Code, Codex itself, or any custom agent.

## Why

Codex's Sky CUA plugin is bundled inside Codex.app and tightly coupled to
`codex app-server`. That means:
- Every CUA tool call routes: your MCP client → `codex app-server` → `SkyComputerUseClient` → native service → AX APIs. ~600ms baseline RPC overhead per call.
- Sky's CGEvent symbols are resolved via `dlsym` at runtime — no static
  imports — so reasoning about its behavior requires reverse-engineering
  the binary.
- There's no way to use Computer Use without Codex installed + the app-server
  chain running.

This project peels off the Computer Use layer into a small standalone
binary that uses the same AX + CGEvent APIs directly, targeting the same
contract Sky exposes.

## Quick start

    # Build
    swift build -c release

    # Or build + bundle as a .app with TCC-required entitlements
    make app sign

    # Register with Claude Code (user scope)
    claude mcp add --scope user mac-cua -- /absolute/path/to/.build/release/cua-mcp

Grant Accessibility + Screen Recording in System Settings → Privacy & Security
on first use. Same permissions Sky needs.

## Performance vs Codex Sky CUA

Measured on the same Mac, same apps, same calls:

    get_app_state latency (min of 3 samples)
    app         sky      mac       speedup
    ─────────────────────────────────────
    Calculator  228ms     20ms     11×
    TextEdit    120ms      5ms     26×
    Finder      652ms     90ms      7×
    Notes       980ms   1700ms     (sky faster, 909-row sidebar)

    input latency (broker call → AX-visible effect, avg of 5)
    op              sky      mac       speedup
    ─────────────────────────────────────────
    type_text 'X'   755ms   160ms      4.7×
    press_key 'z'   882ms   195ms      4.5×

Sky's ~600ms baseline is the Codex app-server RPC chain. mac-cua goes
directly from JSON-RPC stdin → `CGEventPostToPid` for input, batched
`AXUIElementCopyMultipleAttributeValues` for tree reads.

## Architecture

    Sources/CuaMcp/
      main.swift            entry point + CLI subcommands (probe-state, tools, serve)
      MCPServer.swift       JSON-RPC stdio dispatch, 9 tool schemas
      AXTree.swift          accessibility tree walker + serializer
      ElementCache.swift    per-turn element_index → AXUIElement map
      VirtualCursor.swift   NSPanel overlay that animates between actions
      Permissions.swift     AX + Screen Recording TCC checks
      KeyParser.swift       xdotool-style key spec → CGKeyCode + modifiers
      Tools/
        ListApps.swift
        GetAppState.swift
        Input.swift         press_key, type_text, click, drag, scroll, set_value, etc.

All input tools route through `CGEventPostToPid(pid)` for focus-agnostic
delivery to native AppKit apps. Webview scrolling (Chrome, Safari) still
requires brief focus or Allow-JavaScript-from-Apple-Events — same
limitation Sky has.

## Harness

A side-by-side comparator harness lives in `harness/`. Every test spawns
both brokers as MCP subprocesses and asserts identical behavior.

    python3 -u harness/run_all.py

    ✓  core tools (9)              9/9  functional parity
    ✓  error contract (4)          4/4  error messages match
    ✓  press_key vocab (25)        25/25 xdotool-style keys accepted
    ✓  perf bench (4 apps)         get_app_state latency
    ✓  input latency (2 ops)       call → observable-effect latency

See `harness/HARNESS.md` for the test catalog and known intentional
divergences from Sky.

## Reverse-engineering notes

`NOTES.md` documents what was learned reverse-engineering the Sky binary:
class graph (`ComputerUseAppController`, `ComputerUseCursor`, `SkyComputerUseIPCServer`),
input APIs Sky imports (`AX*`, `CGEvent*` via dlsym), the tool contract
(`get_app_state`-before-action, per-turn element indices), and the exact
error strings it emits.

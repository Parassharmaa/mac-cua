# mac-cua-mcp

Native macOS Computer Use MCP server. Drives Mac apps in the background
without stealing focus, moving the cursor, following the target across
Spaces, or reordering windows in the z-stack.

## Tools

Exposes nine tools over MCP stdio:

    list_apps        get_app_state    click
    press_key        type_text        set_value
    scroll           drag             perform_secondary_action

Element-indexed actions dispatch through the accessibility tree.
Pixel-coordinate actions route through a per-pid SkyLight event path
that remains trusted by Chromium/Electron renderer filters.

## Quick start

    # Build
    swift build -c release

    # Or build + bundle as a .app with TCC-required entitlements
    make app sign

    # Register with Claude Code (user scope)
    claude mcp add --scope user mac-cua -- /absolute/path/to/.build/release/cua-mcp

Grant Accessibility + Screen Recording in System Settings → Privacy &
Security on first use.

## Background CU guarantees

For any tool call against a target app other than the user's frontmost:

- Real cursor stays where the user left it.
- Frontmost app never changes — if the target self-activates in
  response to our event, a reactive preventer restores the prior
  frontmost on the same runloop turn.
- Target window's z-order is preserved.
- User's active Space is not followed.

The tool call returns as soon as the action lands; the focus-steal
preventer remains armed for 3 s so late self-activations
(document-open animations, renderer round-trips) also land inside the
suppression window.

## Virtual cursor

A soft violet pointer overlays the screen during every action, arcing
along a Bezier path to the click target, rotating its tip toward motion,
and pulsing on click. Fades when idle. On by default — set
`CUA_HIDE_CURSOR=1` to run without it.

## Eval

`make eval` runs an in-process Swift eval of 16 contract cases:

- Calculator click with display readback.
- TextEdit type (ASCII, CJK) with AX value readback.
- Cursor position invariant across click and type.
- Frontmost delta per tool (before/after).
- Z-order + minimized-refuse invariants.
- Chrome / Slack / VS Code AX dispatch while backgrounded.
- Chrome closed-loop pixel click with `document.title` verification
  (requires Chrome → View → Developer → Allow JavaScript from Apple Events).

## Architecture

    Sources/CuaMcp/
      main.swift                  entry — CLI subcommands + MCP stdio server
      MCPServer.swift             JSON-RPC dispatch + 9 tool schemas
      AXTree.swift                AX walker + Markdown-outline serializer
      ElementCache.swift          per-turn element_index → AXUIElement map
      SkyLightBridge.swift        private SkyLight SPIs for trusted event post
      SystemFocusStealPreventer.swift  reactive NSWorkspace observer
      AXEnablement.swift              AX enablement + BackgroundFocus helper
      AXEventTag.swift            AXESynthesizedIgnoreEventSourceID tagging
      VirtualCursor.swift         NSPanel overlay, Bezier motion, click pulse
      Permissions.swift           AX + Screen Recording TCC checks
      KeyParser.swift             xdotool-style key spec → CGKeyCode + modifiers
      EvalRunner.swift            in-process eval harness
      Tools/
        ListApps.swift
        GetAppState.swift
        Input.swift               press_key, type_text, click, drag, scroll, set_value, etc.

Input tools route mouse and keyboard events through a per-pid SkyLight
path that marks them as trusted user gestures, so Chromium's renderer
filter accepts the event rather than dropping it at the IPC boundary.
Keyboard events to Chromium-family apps additionally carry an
authentication envelope required by the renderer trust filter on
macOS 14+.

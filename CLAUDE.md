# CLAUDE.md

Conventions and context for agents editing this repo.

## What this is

Native macOS Computer Use MCP server in Swift. Drives Mac apps in the
background — no focus steal, no cursor motion, no z-order change, no
Space follow. Runs as a stdio MCP server or as a menubar .app.

## Build + test

    swift build -c release        # Fast inner loop
    make eval                     # 20-case in-process eval (18 pass/2 skip baseline)
    make format && make lint      # swift-format tidy
    make app sign                 # Build + sign the .app bundle

## Source layout

    Sources/CuaMcp/
      main.swift                    CLI dispatch + MCP stdio server entry
      MCPServer.swift               JSON-RPC dispatch + tool schemas
      AXTree.swift                  AX walker + Markdown-outline serializer
      ElementCache.swift            per-turn element_index → AXUIElement map
      SkyLightBridge.swift          private SkyLight SPIs for trusted event post
      SystemFocusStealPreventer.swift  reactive NSWorkspace observer
      AXEnablement.swift            AX enablement + BackgroundFocus + AXFocusSuppression
      AXEventTag.swift              AXESynthesizedIgnoreEventSourceID tagging
      VirtualCursor.swift           NSPanel overlay, Bezier motion, click ring
      Permissions.swift             AX + Screen Recording TCC checks
      KeyParser.swift               xdotool-style key spec → CGKeyCode + modifiers
      EvalRunner.swift              in-process eval harness
      AppUI.swift                   menubar popover UI
      DebugCommands.swift           `probe-scroll` helper
      Screenshot.swift              get_app_state PNG capture
      Tools/
        ListApps.swift
        GetAppState.swift
        Input.swift                 press_key, type_text, click, drag, scroll, set_value, ...

## Invariants

Every tool call against a non-frontmost target must preserve:

- user's frontmost app
- target window z-order
- user's active Space
- real cursor position

The eval enforces these with `measureNoSteal` + `cursorPoint` before/after
checks. If you add a new tool or reshape an existing one, add an eval
case before merging.

## Focus-suppression stack (3 layers)

1. **AX enablement** — `AXEnablement.installIfNeeded(pid:)` writes
   `AXManualAccessibility` + `AXEnhancedUserInterface`. Re-asserted per
   snapshot for Chromium-family pids (they reset the flag); cached for
   native AppKit apps.
2. **Synthetic AX focus** — `AXFocusSuppression.withSuppression(element:)`
   wraps AX action dispatches. Writes `AXFocused=true` on window +
   element, `AXMain=true` on window, restores prior values on exit.
   Skipped for minimized windows (Chrome deminiaturizes on AXFocused write).
3. **Reactive preventer** — `SystemFocusStealPreventer.beginSuppression`.
   `NSWorkspace.didActivateApplicationNotification` observer; on target
   activation, force-demote via `.activateIgnoringOtherApps`. Stays armed
   3s past tool return for late activations.

All three are composed by `BackgroundFocus.activate(pid:)`. Call it
whenever you dispatch to a target pid. Defer `.restore()` for the
teardown.

## Event post path

Mouse + keyboard + scroll CGEvents route through
`SkyLightBridge.postToPid` which uses private `SLEventPostToPid`. For
Chromium-family targets, keyboard events attach an
`SLSEventAuthenticationMessage` envelope (required by macOS 14+
renderer trust filter). Mouse events skip the envelope — it forks
onto a direct-mach path Chromium doesn't subscribe to.

Chromium pixel clicks are preceded by a primer click at `(-1, -1)` to
satisfy the renderer's user-activation gate.

Every event is tagged with `AXESynthesizedIgnoreEventSourceID` via
`AXEventTag.applyIgnore` so the window server skips the "bring target
frontmost" side effect.

## Cursor overlay

`VirtualCursor.shared.animate(to:)` moves a violet 4-point pointer along
a Bezier arc with spring overshoot. Tip rotates to motion direction.
Idle heading is NW. `pulse()` fires a bloom pop + expanding click ring.
Overlay auto-hides 2s after last activity.

Enabled by default. `CUA_HIDE_CURSOR=1` disables.

## Tree + element cache

`ElementCache.shared.replace(root:)` is called by `get_app_state` tool
handler after each snapshot. `clickElement` / `setValue` /
`performSecondaryAction` look up AXUIElements by `element_index`.
Indices are only valid until the next snapshot — throw "element ID no
longer valid" on miss, caller must re-snapshot.

## Style

- 4-space indent, 100-col soft line limit. `.swift-format` enforces.
- Comments explain WHY, not WHAT.
- Tools return `[[String: Any]]` content arrays directly — no codable
  wrapping.

## When adding a new tool

1. Add method in `Tools/Input.swift` (or a new file under `Tools/`).
2. Wrap with `BackgroundFocus.activate(pid:)` if it dispatches events.
3. Wrap AX actions with `AXFocusSuppression.withSuppression(element:)`.
4. Add `Tool` entry in `MCPServer.swift` `ToolRegistry.all`.
5. Add an eval case in `EvalRunner.swift` covering:
   - the contract (does the action observably land?)
   - the invariant (`measureNoSteal`).

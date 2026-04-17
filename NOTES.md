# Reverse-engineering notes on OpenAI's Sky CUA plugin

These are my working notes on Codex's bundled Computer Use (CUA) plugin,
extracted from the two binaries:

```
/Applications/Codex.app/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
/Applications/Codex.app/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient
```

Methods used: `strings`, `nm`, `otool -oV` (ObjC runtime), `swift-demangle`.

## Architecture (observed)

```
Codex.app (Electron UI)
    │
    ▼
codex app-server (native, JSON-RPC broker; launches plugin MCP servers)
    │
    ▼
SkyComputerUseClient mcp          ← exposes tools over MCP stdio
    │  (IPC / cross-process)
    ▼
SkyComputerUseService             ← holds TCC grants, runs AppKit cursor overlay,
                                     reads AX tree, posts synthetic events
```

The service is the privileged side (owns TCC grants, AppKit UI, AX calls). The
client is the MCP-facing stdio process. Codex app-server starts the client;
the client talks to the service via IPC (`ComputerUseIPCServer`).

## Classes discovered in SkyComputerUseService

- `ComputerUseAppController` — main state machine for "acting on an app".
  Observed ivars: `_isActive`, `_lastWindow`, `_currentlyOpenedMenu`,
  `_currentlyFocusedMenuBarItem`, `chatID`, `bundleIdentifier`,
  `runningApplication`, `virtualCursor`, `terminationObserver`, `orderingObserver`,
  `focusEnforcer`, `visibleRect`, `scalingFactor`, `scaledScreenSize`,
  `cursorPositionInScaledCoordinates`, `lastAXTree`, `skyshotImageFiles`,
  `_windows`, `signposter`, `axEnablementAssertion`.
- `ComputerUseCursor` — the virtual cursor overlay. Ivars: `delegate`,
  `targetWindowID`, `isMoving`, `shouldFadeOut`, `window`.
- `ComputerUseCursor.Window` — subclass of `NSWindow` that renders the cursor.
- `ComputerUseCursor.Style`, `SoftwareCursorStyle`, `FogCursorStyle` — two style
  variants; Fog is animated physics-style (velocity, angle).
- `FogCursorViewModel` — ivars `_velocityX`, `_velocityY`, `_isPressed`,
  `_activityState`, `_isAttached`, `_angle`. SwiftUI model.
- `ComputerUseCursor.AppMonitor` — tracks focused-app changes.
- `ComputerUseAppInstance` / `ComputerUseAppInstanceManager` — per-app sessions.
- `RefetchableSkyshotAXTree` / `RefetchableUIElement` — wraps AX refs so they
  can be re-resolved when stale ("The element ID is no longer valid…").
- `SkyshotClassifier` — something that classifies screenshots (likely for
  context hints).
- `SystemSelectionClient` — tracks system-wide text selection.
- `ComputerUseUserInteractionMonitor` — pauses the session if the user takes
  over (`onAppInterrupted`, debounce duration).
- `ComputerUseURLBlocklistCache` — disallowed-URL tracking. Error:
  "Computer Use stopped due to encountering a disallowed URL: …"
- `CodexAppServerJSONRPCConnection` / `JSONRPCLineBuffer` — stdio framing to
  Codex app-server. Newline-delimited JSON.
- `ComputerUseIPCServer` — IPC surface to SkyComputerUseClient. Methods:
  `ensureApplicationHasPermissions`, `onAppUsed`, `onCodexTurnEnded`.

## Tool contract (baked into the plugin)

From binary strings:

> "Begin by calling `get_app_state` every turn you want to use Computer Use to
> get the latest state before acting. Codex will automatically stop the session
> after each assistant turn, so this step is required before interacting with
> apps in a new assistant turn."

> "The available tools are list_apps, get_app_state, click, perform_secondary_action,
> scroll, drag, type_text, press_key, and set_value."

> "Re-query the latest state with `get_app_state` before sending more actions."

> "The element ID is no longer valid. Try to get the on-screen content again
> and see if that resolves the issue."

Per-turn element indices are the contract.

## Error catalog (verbatim)

- `Computer use actions are not allowed for system security process: …`
- `Cannot set a value for an element that is not settable`
- `Mouse action not supported for menu items`
- `Failed to click menu item`
- `Running application not found: …`
- `AX tree unexpectedly missing.`
- `Missing scroll amount` / `Missing scroll direction`
- `Invalid duration` / `Missing text to type`
- `Computer Use stopped due to encountering a disallowed URL: …`
- `The user changed '…'. Re-query the latest state with get_app_state before
  sending more actions.`
- `The user is still interacting with '…'` (wait-N-seconds and retry pattern)

## press_key key name vocabulary (xdotool-style, from strings)

Full set of special names accepted:

```
BackSpace, Linefeed, Return, Escape, Delete, Scroll_Lock, Sys_Req,
Page_Up, Page_Down, Select, Execute, Insert, Cancel, Mode_switch,
script_switch, Num_Lock,
KP_Delete, KP_Enter, KP_Equal, KP_Multiply, KP_Add, KP_Subtract,
KP_Decimal, KP_Divide, KP_Space, KP_Tab, KP_Home, KP_Left, KP_Right,
KP_Down, KP_Prior, KP_Page_Up, KP_Next, KP_Page_Down, KP_End, KP_Begin,
KP_Insert, KP_Separator,
Shift_L, Shift_R, Control_L, Control_R, Meta_L, Meta_R, Super_L,
Super_R, Caps_Lock, Shift_Lock, Hyper_L, Hyper_R, command, Command
```

Plus symbol names: `exclam`, `quotedbl`, `numbersign`, `dollar`, `percent`,
`ampersand`, `apostrophe`, `parenleft`, `parenright`, `asterisk`, `period`,
`semicolon`, `greater`, `question`, `bracketleft`, `backslash`, `bracketright`,
`asciicircum`, `underscore`, `braceleft`, `braceright`, `asciitilde`.

Combination syntax: `super+c`, `cmd+shift+p`, `alt+Return`, etc.

Typing path for individual chars uses CGEventKeyboardSetUnicodeString —
binary contains "Unable to get current keyboard layout" / "Could not find
key code for character: %C" so there is a keyboard-layout lookup path that
falls through to Unicode injection when the layout can't resolve a char.

## Cursor overlay behavior

- Single `ComputerUseCursor.Window` — an `NSWindow` subclass; elevated
  window level (`useOverlayWindowLevel`).
- Ivars track `targetWindowID`, `isMoving`, `shouldFadeOut`.
- Two styles: `SoftwareCursorStyle` (likely just the cursor image) and
  `FogCursorStyle` (SwiftUI-driven with velocity/angle — the "fog trail"
  effect seen on screen).
- Motion methods surface through:
  - `cursorMotionProgressAnimation`
  - `cursorMotionNextInteractionTimingHandler`
  - `cursorMotionCompletionHandler`
  - `cursorMotionDidSatisfyNextInteractionTiming`
  - `currentInterpolatedOrigin`
- Shape: move from current to target, signal "satisfied next interaction
  timing" (meaning enough of the animation has played that the click can
  fire while the tail finishes), then invoke completion handler.

Good-enough v1: easeInOut cubic, 250-400ms, fire click at ~80% complete.

## get_app_state output shape (ground-truth samples from using the live broker)

For Notes (focused-window root), the emitted text is:

```
App=com.apple.Notes (pid 42956)
Window: "Poems", App: Notes.
	0 standard window Poems – 102 notes, Secondary Actions: Raise
		1 split group
			2 scroll area
				3 outline Folders
					...
	142 menu bar
		143 Notes
		144 File
```

Key invariants:
- Element 0 is the focused window (not the app).
- Menu bar appears as a sibling of the window, with its own numbering
  continuing from after the window's subtree.
- Indentation = tree depth.
- Modifiers `(settable, string)`, `(selectable)`, `(selected)`, `(disabled)`
  inline in parens.
- Inline text: `<Role> <Title>, Description: <AXDescription>, Value: <AXValue>,
  Help: <AXHelp>, ID: <AXIdentifier>`.
- `Secondary Actions:` trails after the element line, comma-separated,
  AX- prefix stripped ("AXPress" → "Press", "AXShowMenu" → "ShowMenu").

Role labels use `AXRoleDescription` when available (e.g. "standard window",
"pop up button") and fall back to lowercased stripped role ("AXGroup" →
"group").

## Permissions (TCC)

Three relevant TCC categories:

| Category | Check | Prompt | Info.plist key |
|---|---|---|---|
| Accessibility | `AXIsProcessTrustedWithOptions(…prompt:false)` | same, prompt:true | `NSAccessibilityUsageDescription` |
| Screen Recording | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` | `NSScreenCaptureUsageDescription` |
| Automation | `AEDeterminePermissionToAutomateTarget` | per-target prompt | `NSAppleEventsUsageDescription` |

TCC identifies the responsible process by bundle ID + code signature DR.
For stable grants: sign with a stable identity (Apple Developer ID, or at
minimum a self-signed stable cert), keep bundle ID constant across rebuilds.

## Research artefacts in this folder

- `service-strings.txt`, `client-strings.txt` — `strings -n 6` dumps.
- `service-symbols-demangled.txt`, `client-symbols-demangled.txt` —
  `nm | swift-demangle` output.
- `objc-service.txt` — `otool -oV` (ObjC runtime class/method/ivar tables).

## Implementation plan for this repo

1. **Swift Package** — stdlib-only executable + `.app` wrapper for TCC.
2. **v1 tool surface**: `list_apps`, `get_app_state`, `press_key`, `type_text`,
   `click`. Subsequent: `scroll`, `drag`, `perform_secondary_action`,
   `set_value`.
3. **Element-index cache**: reset on every `get_app_state`, lookup on click
   by index. Throw "element ID no longer valid" on miss.
4. **Virtual cursor overlay**: NSPanel at `.statusBar` level, hosts a tiny
   NSImageView of `NSCursor.arrow.image`. Animate position via implicit
   CoreAnimation (`animator().setFrameOrigin(…)`) with a 250ms ease-in-out.
5. **App bundle + ad-hoc sign** via a Makefile: `swift build -c release`,
   stage into `cua-mcp.app/Contents/MacOS/`, drop an `Info.plist` with the
   TCC usage descriptions, `codesign --sign -`.

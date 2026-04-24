# Background Computer-Use Plan

Make `cua-mcp` drive macOS apps in the background without stealing focus,
moving the cursor, or reordering windows. Measured by the in-process
Swift eval (`make eval`).

## Invariants

For every tool call against a target app other than the user's frontmost:

- Real cursor position unmoved.
- Frontmost app unchanged (no steal).
- Target window's z-order preserved.
- User's active Space not altered.

## Architecture

### Event routing

Synthetic clicks, keystrokes, and scroll wheel events post through a
private SkyLight SPI bridge (`SkyLightBridge.swift`) that attaches trust
metadata so renderer-IPC filters in Chromium/Electron apps accept the
event as authentic. Native AppKit apps use the same path. Public
`CGEvent.postToPid` is the fallback when private SPIs don't resolve.

Keyboard events targeting Chromium-family apps additionally carry an
authentication envelope required by the renderer filter on macOS 14+.
Mouse events skip the envelope — it forks delivery onto a path Chromium's
window event handler doesn't subscribe to.

### Focus suppression

Three-layer stack applied before any event dispatch to a non-frontmost
target:

1. **AX enablement** (`AXEnablement`): writes `AXManualAccessibility` +
   `AXEnhancedUserInterface` on the target root so Chromium/Electron
   build their full AX tree.
2. **Reactive preventer** (`SystemFocusStealPreventer`): watches
   `NSWorkspace.didActivateApplicationNotification` and, if the target
   self-activates in response to our event, synchronously restores the
   user's previous frontmost on the same runloop turn.
3. **Post-action window**: the preventer stays armed for 3 s past tool
   return so late self-activations (document-open animations, renderer
   round-trips) also land inside the suppression window.

Event source-ID tagging (`AXEventTag`) marks synthesized events as
"ignore" input so the window server skips the usual "bring target to
front" side effect.

### Primer click

Before pixel clicks into Chromium-family web content, a discarded
off-screen click at `(-1, -1)` ticks the renderer's user-activation
gate so the real click lands as a trusted continuation. Unlocks
`window.open`, fullscreen, video play/pause.

### Window-local hit-test stamp

Mouse events attach a window-local coordinate via `CGEventSetWindowLocation`
so the window server hit-tests directly instead of reprojecting from
screen space. Matters when the target window is occluded or on a different
Space.

### Virtual cursor overlay

Soft violet 4-point pointer drawn on a floating panel. Animates along
Bezier arcs, rotates its tip toward the motion direction, pulses on
click, and fades when idle. On by default — set `CUA_HIDE_CURSOR=1`
for invisible mode.

## Eval

`make eval` runs `.build/release/cua-mcp eval` — 16 in-process cases
covering:

- Click + type + scroll on Calculator, TextEdit, Chrome, Slack, VS Code.
- Closed-loop verification (Calculator display readback, TextEdit
  value readback, Chrome `document.title` readback via AppleScript).
- Cursor position invariant across click and type.
- Frontmost delta per tool (before/after check).
- Minimized window refusal.
- AX tree freshness under backgrounded re-reads.

Target: 16/16 on a machine with all test apps running + Chrome
"Allow JavaScript from Apple Events" enabled.

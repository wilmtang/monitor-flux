# Media-Key Custom Bindings Plan

## Purpose

Let users assign brightness/volume media-key combinations to actions, instead of only
showing the app's built-in media-key bindings.

## Current Model

MonitorFlux currently has two separate shortcut mechanisms:

- **Carbon custom hotkeys** in `HotKeyCenter.swift`: normal keyboard combos like
  `Control+Option+]`, registered with `RegisterEventHotKey`. These work globally and do
  not need Accessibility permission.
- **Media keys** in `KeyboardControlService.swift`: brightness/volume keys arrive as
  `NSSystemDefined` / HID events through a `CGEventTap`. This path needs Accessibility
  permission because MonitorFlux intercepts and may swallow system input.

Do not try to force media keys through `RegisterEventHotKey`; that API is for normal
virtual-key combos, not brightness/volume media keys.

## Goal

Support both shortcut types as first-class user bindings:

- Normal keyboard combos remain Carbon-backed.
- Brightness/volume media-key combos are recorded, stored, displayed, and routed through
  the existing event-tap path.

## Implementation Plan

1. Replace `AppPreferences.hotkeys: [String: GlobalShortcut]` with a binding enum:

   ```swift
   enum ShortcutBinding: Codable, Equatable, Sendable {
       case keyboard(GlobalShortcut)
       case media(MediaKeyShortcut)
   }
   ```

   Preserve backward compatibility: old JSON values shaped like `GlobalShortcut` should
   decode as `.keyboard(...)`.

2. Make `MediaKeyShortcut` persistent:

   ```swift
   struct MediaKeyShortcut: Codable, Equatable, Sendable {
       var keyCode: Int
       var control: Bool
       var shift: Bool
   }
   ```

   Start with Control and Shift only, because the current media-key behavior already uses
   those modifiers.

3. Update `ShortcutRecorder`:

   - Normal `keyDown` with at least one modifier records `.keyboard(GlobalShortcut(...))`.
   - Managed media-key `systemDefined` events record `.media(MediaKeyShortcut(...))`.
   - Escape cancels.
   - Bare non-media keys remain ignored.
   - Display media keys as key caps, e.g. `Brightness ↑`, `Control Brightness ↓`,
     `Shift Brightness ↑`, `Volume ↓`.

4. Split registration by binding type:

   - `.keyboard` bindings go through `HotKeyCenter.update(...)`.
   - `.media` bindings do not go through Carbon.
   - Store media bindings in a lookup table owned by `KeyboardControlService` or
     `AppStore`.

5. Route media-key events through user bindings first:

   - Decode incoming media key into `MediaKeyShortcut`.
   - If it matches a user-assigned `.media(...)`, run that `HotKeyAction`.
   - Otherwise fall back to the built-in mapping:
     - brightness keys -> brightness
     - Control + brightness -> contrast
     - Shift + brightness -> warmth
     - volume keys -> volume

6. Update Settings copy and state:

   - Normal Carbon shortcuts should still say they work without Accessibility.
   - Media-key bindings should say they require keyboard control and Accessibility.
   - If media bindings exist but keyboard control is disabled, show a clear warning instead
     of a Carbon-style conflict.

7. Keep conflict handling separate:

   - Carbon conflicts are detected when `RegisterEventHotKey` fails.
   - Media-key bindings do not have the same conflict model; they fail when Accessibility is
     missing or the media-key tap is off.

8. Tests to add:

   - Old `GlobalShortcut` JSON decodes as `.keyboard`.
   - New `.media` bindings round-trip through `Codable`.
   - `ShortcutRecorder` parses synthetic media-key `data1` into `.media`.
   - Media binding lookup prefers user assignment over built-in mapping.
   - Carbon registration ignores `.media` bindings.
   - Existing normal custom shortcuts still register and route through `HotKeyCenter`.

9. Manual verification:

   ```sh
   swift build
   swift test
   ./script/smoke_test.sh
   ```

   Then test live with Accessibility granted:

   - Record `Shift + Brightness Down` for "Color warmer".
   - Record `Volume Up` for a non-volume action to prove remapping works.
   - Disable keyboard control and verify the UI warns that media bindings will not fire.
   - Verify normal custom shortcuts still fire without Accessibility.

## Non-Goals

- Do not remove the built-in media-key defaults.
- Do not route media keys through Carbon.
- Do not require Accessibility for normal Carbon keyboard shortcuts.
- Do not auto-enable hardware-writing behavior during tests; keep using safe mode for UI
  verification.

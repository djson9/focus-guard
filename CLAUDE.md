# FocusGuard

A macOS menu bar app that prevents other applications from stealing window focus.

## Build & Run

```bash
make build    # compile
make run      # kill old + rebuild + launch
make install  # install to /usr/local/bin
```

Or manually:
```bash
swiftc -o FocusGuard FocusGuard.swift -framework Cocoa -framework Carbon
./FocusGuard
```

Shell alias `focus-guard` is defined in `~/.zshrc`.

## CLI Commands

FocusGuard accepts CLI flags that send commands to the running daemon via `DistributedNotificationCenter`:

```bash
FocusGuard                        # Start daemon (no args)
FocusGuard --guard-frontmost      # Guard the current frontmost app
FocusGuard --guard <bundle-id>    # Guard a specific app by bundle ID
FocusGuard --stop                 # Stop guarding
FocusGuard --toggle               # Toggle guarding on/off
FocusGuard --status               # Print current guard status
FocusGuard --log                  # Tail the log file
FocusGuard --help                 # Show help
```

## Architecture

Single-file Swift app (`FocusGuard.swift`) with no dependencies. Compiles with `swiftc` — no Xcode project needed.

### Key Components

- **HotkeyManager** — Registers global keyboard shortcuts via Carbon `RegisterEventHotKey`. Singleton. Properly cleans up both hotkey and event handler on re-registration.
- **HotkeyRecorderView** — Custom NSView that captures key combos when clicked. Used in the Settings window.
- **PulseOverlay** — Flashes a blue border around all screens when a focus steal is blocked. Windows are **pre-created at startup** and reused by toggling `alphaValue` — this avoids an AppKit use-after-free crash that occurs when `NSWindow` objects are created in the same run loop context as `NSRunningApplication.activate()`.
- **StateManager** — Writes runtime state to `~/.config/focus-guard/` as dot files:
  - `.state` — guarding status, last blocked app, PID, timestamp
  - `.active-application` — bundle ID and name of guarded app
  - `.settings` — hotkey configuration
  - `.log` — timestamped log with crash signals
- **SettingsWindowController** — Preferences window with hotkey recorder and suggested default (⌘⇧F).
- **FocusGuard** — Core class. Listens to `NSWorkspace.didActivateApplicationNotification`, detects focus theft, returns focus to the guarded app immediately (no delay). Also listens for CLI commands via `DistributedNotificationCenter`.

### Focus Return Mechanism

Uses `NSRunningApplication.activate()` (macOS 14+) or `.activate(options: .activateIgnoringOtherApps)` (older). Focus is returned **synchronously in the notification callback** with zero delay to minimize flicker. The visual flash is deferred to the next run loop iteration to avoid the AppKit crash.

### Known AppKit Crash

Creating `NSWindow` objects and calling `orderFrontRegardless()` in the same run loop iteration as `NSRunningApplication.activate()` causes a use-after-free (`SIGSEGV` at `0x20`) during the run loop's autorelease pool drain. The fix is to pre-create overlay windows at startup and only modify `alphaValue` during focus events. The flash is also deferred via `DispatchQueue.main.async` to run in a separate run loop iteration.

### Instance Guard

Uses a PID file at `/tmp/focus-guard.pid` with liveness check (`kill(pid, 0)`). Auto-cleans stale PID files from dead processes.

## Development Workflow

When iterating, use `make run` or:
```bash
pkill -x FocusGuard; sleep 0.5; rm -f /tmp/focus-guard.pid
swiftc -o FocusGuard FocusGuard.swift -framework Cocoa -framework Carbon
./FocusGuard &
```

To test focus stealing programmatically:
```bash
FocusGuard --guard com.mitchellh.ghostty
osascript -e 'tell application "Finder" to activate'
```

The user actively uses FocusGuard during development — keep it running as much as possible between rebuilds.

## Settings

- Hotkey defaults to **none** on first launch
- User configures via Settings window (menu bar > Settings... or ⌘,)
- Suggested default shown in Settings: ⌘⇧F
- Stored in UserDefaults and mirrored to `~/.config/focus-guard/.settings`

## Known Limitations

- Requires Accessibility permissions for reliable operation
- Brief flicker on focus steal (~1 frame; no `willActivate` notification exists in macOS)
- Full-screen apps cause space-jumping when focus is returned
- Not App Store compatible (needs Accessibility entitlements)

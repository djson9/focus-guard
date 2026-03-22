import Cocoa
import Carbon

// MARK: - Private CGS API for window level manipulation

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetWindowLevel")
func CGSSetWindowLevel(_ cid: CGSConnectionID, _ wid: UInt32, _ level: Int32) -> CGError

@_silgen_name("CGSGetWindowLevel")
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: UInt32, _ level: inout Int32) -> CGError

// MARK: - Window Pinner

class WindowPinner {
    static let shared = WindowPinner()
    private let cid = CGSMainConnectionID()
    private var pinnedWindows: [(windowID: UInt32, originalLevel: Int32)] = []

    /// Pin all windows of an app to floating level
    func pin(pid: pid_t) {
        unpin() // restore any previously pinned windows

        let windowIDs = getWindowIDs(for: pid)
        let floatingLevel = Int32(CGWindowLevelForKey(.floatingWindow))

        for wid in windowIDs {
            var originalLevel: Int32 = 0
            let getErr = CGSGetWindowLevel(cid, wid, &originalLevel)
            if getErr != .success {
                fgLog("WindowPinner: failed to get level for window \(wid): \(getErr.rawValue)")
                continue
            }

            let setErr = CGSSetWindowLevel(cid, wid, floatingLevel)
            if setErr == .success {
                pinnedWindows.append((windowID: wid, originalLevel: originalLevel))
                fgLog("WindowPinner: pinned window \(wid) (was level \(originalLevel), now \(floatingLevel))")
            } else {
                fgLog("WindowPinner: failed to set level for window \(wid): \(setErr.rawValue)")
            }
        }

        if pinnedWindows.isEmpty {
            fgLog("WindowPinner: no windows pinned for pid \(pid)")
        }
    }

    /// Restore all pinned windows to their original level
    func unpin() {
        for entry in pinnedWindows {
            let err = CGSSetWindowLevel(cid, entry.windowID, entry.originalLevel)
            if err == .success {
                fgLog("WindowPinner: unpinned window \(entry.windowID) back to level \(entry.originalLevel)")
            }
        }
        pinnedWindows.removeAll()
    }

    private func getWindowIDs(for pid: pid_t) -> [UInt32] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 // only normal-level windows
            else { return nil }
            return windowID
        }
    }
}

// MARK: - Global Hotkey Manager

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    private static let signatureRaw: UInt32 = {
        let chars: [UInt8] = [0x46, 0x47, 0x52, 0x44] // "FGRD"
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }()

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            HotkeyManager.shared.handler?()
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signatureRaw, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}

// MARK: - Hotkey Recorder View

class HotkeyRecorderView: NSView {
    var onHotkeyRecorded: ((UInt32, UInt32, String) -> Void)?
    private var isRecording = false
    private var displayString: String = ""
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, currentDisplay: String) {
        self.displayString = currentDisplay.isEmpty ? "Click to record" : currentDisplay
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()

        NSColor.separatorColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        if isRecording { NSColor.controlAccentColor.setStroke() }
        path.stroke()

        let text = isRecording ? "Press shortcut..." : displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        needsDisplay = true
        window?.makeFirstResponder(self)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard isRecording else { return }
        isRecording = false

        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }

        let carbonMods = carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        let display = modifierString(event.modifierFlags) + (keyNameMap[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")

        displayString = display
        needsDisplay = true
        onHotkeyRecorded?(keyCode, carbonMods, display)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}

let keyNameMap: [Int: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
    38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
    47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
    118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
]

// MARK: - Pulse Overlay

class PulseOverlay {
    static let shared = PulseOverlay()
    private var windows: [NSWindow] = []
    private var fadeTimer: Timer?
    private var initialized = false

    /// Pre-create overlay windows so flash() never allocates during focus events
    func setup() {
        guard !initialized else { return }
        initialized = true
        rebuildWindows()

        // Rebuild when screens change (monitor plugged/unplugged)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        for screen in NSScreen.screens {
            let w = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            w.contentView = PulseBorderView(frame: screen.frame)
            w.alphaValue = 0
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func flash() {
        guard initialized else { return }

        fadeTimer?.invalidate()

        // Show at full opacity
        for w in windows {
            w.alphaValue = 1
        }

        // Fade out
        let steps = 8
        let interval = 0.4 / Double(steps)
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [self] timer in
            step += 1
            let alpha = CGFloat(1.0 - Double(step) / Double(steps))
            for w in self.windows { w.alphaValue = alpha }
            if step >= steps {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }
}

class PulseBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let thickness: CGFloat = 4
        let color = NSColor.systemBlue.withAlphaComponent(0.8)
        color.setStroke()

        let path = NSBezierPath(rect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2))
        path.lineWidth = thickness
        path.stroke()
    }
}

// MARK: - State Files

class StateManager {
    static let shared = StateManager()
    private let dir: String

    init() {
        dir = NSHomeDirectory() + "/.config/focus-guard"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func writeState(isGuarding: Bool, lastStolenBy: String?) {
        var lines = ["guarding=\(isGuarding)"]
        if let stolen = lastStolenBy {
            lines.append("last_blocked=\(stolen)")
        }
        lines.append("pid=\(ProcessInfo.processInfo.processIdentifier)")
        lines.append("updated_at=\(ISO8601DateFormatter().string(from: Date()))")
        try? lines.joined(separator: "\n").write(toFile: dir + "/.state", atomically: true, encoding: .utf8)
    }

    func writeActiveApplication(bundleID: String?, name: String?) {
        if let bundleID = bundleID, let name = name {
            let lines = [
                "bundle_id=\(bundleID)",
                "name=\(name)",
                "guarded_since=\(ISO8601DateFormatter().string(from: Date()))"
            ]
            try? lines.joined(separator: "\n").write(toFile: dir + "/.active-application", atomically: true, encoding: .utf8)
        } else {
            try? "".write(toFile: dir + "/.active-application", atomically: true, encoding: .utf8)
        }
    }

    func writeSettings(hotkeyDisplay: String, hotkeyKeyCode: Int, hotkeyModifiers: Int) {
        let lines = [
            "hotkey_display=\(hotkeyDisplay.isEmpty ? "none" : hotkeyDisplay)",
            "hotkey_key_code=\(hotkeyKeyCode)",
            "hotkey_modifiers=\(hotkeyModifiers)"
        ]
        try? lines.joined(separator: "\n").write(toFile: dir + "/.settings", atomically: true, encoding: .utf8)
    }

    func clearOnExit() {
        try? "guarding=false\npid=\nupdated_at=\(ISO8601DateFormatter().string(from: Date()))".write(toFile: dir + "/.state", atomically: true, encoding: .utf8)
        try? "".write(toFile: dir + "/.active-application", atomically: true, encoding: .utf8)
    }
}

// MARK: - Settings Window

class SettingsWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "FocusGuard Settings"
        w.center()
        w.isReleasedWhenClosed = false

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Label
        let label = NSTextField(labelWithString: "Toggle Hotkey:")
        label.frame = NSRect(x: 20, y: 100, width: 120, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        contentView.addSubview(label)

        // Hotkey recorder
        let currentDisplay = UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? ""
        let recorder = HotkeyRecorderView(
            frame: NSRect(x: 150, y: 95, width: 200, height: 30),
            currentDisplay: currentDisplay
        )
        recorder.onHotkeyRecorded = { keyCode, modifiers, display in
            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
            UserDefaults.standard.set(display, forKey: "hotkeyDisplay")
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
        contentView.addSubview(recorder)

        // Hint
        let hint = NSTextField(labelWithString: "Press the hotkey to toggle guarding the frontmost app.")
        hint.frame = NSRect(x: 20, y: 60, width: 340, height: 20)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        contentView.addSubview(hint)

        // Suggested default
        let defaultBtn = NSButton(title: "Use ⌘⇧F", target: self, action: #selector(resetDefault))
        defaultBtn.frame = NSRect(x: 150, y: 30, width: 100, height: 28)
        defaultBtn.bezelStyle = .rounded
        contentView.addSubview(defaultBtn)

        let suggestLabel = NSTextField(labelWithString: "Suggested:")
        suggestLabel.frame = NSRect(x: 80, y: 34, width: 70, height: 20)
        suggestLabel.font = .systemFont(ofSize: 11)
        suggestLabel.textColor = .secondaryLabelColor
        contentView.addSubview(suggestLabel)

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func resetDefault() {
        let keyCode = kVK_ANSI_F  // F key
        let modifiers = UInt32(cmdKey) | UInt32(shiftKey)
        UserDefaults.standard.set(keyCode, forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
        UserDefaults.standard.set("⇧⌘F", forKey: "hotkeyDisplay")
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)

        // Re-show to refresh recorder display
        window?.close()
        window = nil
        show()
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
    static let fgCommand = Notification.Name("com.focusguard.command")
}

// MARK: - FocusGuard

class FocusGuard: NSObject {
    private var protectedBundleID: String?
    private var protectedApp: NSRunningApplication?
    private var isGuarding = false
    private var statusItem: NSStatusItem?
    private var lastStolenBy: String?
    private let settingsController = SettingsWindowController()

    override init() {
        super.init()
        setupStatusItem()
        setupNotifications()
        registerSavedHotkey()
        syncStateFiles()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeyChanged,
            object: nil
        )

        // Listen for CLI commands from other instances
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCommand(_:)),
            name: .fgCommand,
            object: nil
        )
    }

    @objc private func handleCommand(_ notification: Notification) {
        guard let cmd = notification.userInfo?["cmd"] as? String else { return }
        fgLog("Received command: \(cmd)")

        switch cmd {
        case "guard-frontmost":
            guardFrontmost()
        case "stop":
            stopGuarding()
        case "toggle":
            toggleGuard()
        case "status":
            let state = isGuarding ? "guarding \(protectedApp?.localizedName ?? protectedBundleID ?? "?")" : "idle"
            fgLog("Status: \(state)")
        default:
            if cmd.hasPrefix("guard:") {
                let bundleID = String(cmd.dropFirst(6))
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                    startGuarding(app: app)
                } else {
                    fgLog("App not found: \(bundleID)")
                }
            } else {
                fgLog("Unknown command: \(cmd)")
            }
        }
    }

    static func sendCommand(_ cmd: String) {
        DistributedNotificationCenter.default().postNotificationName(
            .fgCommand,
            object: nil,
            userInfo: ["cmd": cmd],
            deliverImmediately: true
        )
    }

    // MARK: - Hotkey

    private func registerSavedHotkey() {
        let keyCode = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        let modifiers = UserDefaults.standard.integer(forKey: "hotkeyModifiers")

        if keyCode == 0 && modifiers == 0 {
            // No hotkey configured
            HotkeyManager.shared.unregister()
            print("No hotkey configured. Set one in Settings.")
        } else {
            HotkeyManager.shared.register(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) { [weak self] in
                self?.toggleGuard()
            }
            let display = UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "custom"
            print("Hotkey registered: \(display)")
        }
    }

    private func syncStateFiles() {
        StateManager.shared.writeState(isGuarding: isGuarding, lastStolenBy: lastStolenBy)
        StateManager.shared.writeActiveApplication(bundleID: protectedBundleID, name: protectedApp?.localizedName)
        StateManager.shared.writeSettings(
            hotkeyDisplay: UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "",
            hotkeyKeyCode: UserDefaults.standard.integer(forKey: "hotkeyKeyCode"),
            hotkeyModifiers: UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        )
    }

    @objc private func hotkeySettingsChanged() {
        registerSavedHotkey()
        updateMenu()
        syncStateFiles()
    }

    func toggleGuard() {
        if isGuarding {
            stopGuarding()
        } else {
            guardFrontmost()
        }
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🛡 FocusGuard"
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let hotkeyDisplay = UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? ""

        if isGuarding, let name = protectedApp?.localizedName {
            let guardingItem = NSMenuItem(title: "Guarding: \(name)", action: nil, keyEquivalent: "")
            guardingItem.isEnabled = false
            menu.addItem(guardingItem)

            if let stolenBy = lastStolenBy {
                let lastItem = NSMenuItem(title: "Last blocked: \(stolenBy)", action: nil, keyEquivalent: "")
                lastItem.isEnabled = false
                menu.addItem(lastItem)
            }

            menu.addItem(NSMenuItem.separator())
            let stopTitle = hotkeyDisplay.isEmpty ? "Stop Guarding" : "Stop Guarding (\(hotkeyDisplay))"
            menu.addItem(NSMenuItem(title: stopTitle, action: #selector(stopGuarding), keyEquivalent: ""))
        } else {
            let hint = hotkeyDisplay.isEmpty ? "Not guarding — set hotkey in Settings" : "Not guarding — \(hotkeyDisplay) to guard frontmost"
            let infoItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
        }

        menu.addItem(NSMenuItem.separator())

        // List running GUI apps to pick from
        let pickItem = NSMenuItem(title: "Guard App...", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(NSMenuItem(title: "Guard Frontmost App", action: #selector(guardFrontmost), keyEquivalent: ""))
        submenu.addItem(NSMenuItem.separator())

        // Snapshot app info as strings to avoid retaining NSRunningApplication objects
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let name = app.localizedName, let bid = app.bundleIdentifier else { return nil }
                return (name: name, bundleID: bid)
            }
            .sorted { $0.name < $1.name }

        for app in apps {
            let item = NSMenuItem(title: app.name, action: #selector(selectAppByBundleID(_:)), keyEquivalent: "")
            item.representedObject = app.bundleID as NSString
            item.target = self
            submenu.addItem(item)
        }

        pickItem.submenu = submenu
        menu.addItem(pickItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            if item.action != nil && item.target == nil {
                item.target = self
            }
        }

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func guardFrontmost() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            print("No suitable frontmost app found.")
            return
        }
        startGuarding(app: frontApp)
    }

    @objc private func selectAppByBundleID(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return }
        startGuarding(app: app)
    }

    @objc private func stopGuarding() {
        WindowPinner.shared.unpin()
        isGuarding = false
        protectedApp = nil
        protectedBundleID = nil
        lastStolenBy = nil
        statusItem?.button?.title = "🛡 FocusGuard"
        fgLog("Stopped guarding.")
        updateMenu()
        syncStateFiles()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startGuarding(app: NSRunningApplication) {
        protectedApp = app
        protectedBundleID = app.bundleIdentifier
        isGuarding = true
        lastStolenBy = nil
        statusItem?.button?.title = "🛡 \(app.localizedName ?? "App")"
        fgLog("Now guarding: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "?"))")
        WindowPinner.shared.pin(pid: app.processIdentifier)
        updateMenu()
        syncStateFiles()
    }

    // MARK: - Focus Monitoring

    private func setupNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard isGuarding,
              let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let activatedBundleID = activatedApp.bundleIdentifier,
              let protectedBundleID = protectedBundleID else {
            return
        }

        if activatedBundleID == protectedBundleID { return }
        if activatedBundleID == Bundle.main.bundleIdentifier { return }

        let thiefName = activatedApp.localizedName ?? activatedBundleID
        fgLog("Blocked: \(thiefName)")
        lastStolenBy = thiefName

        // Return focus immediately — no delay minimizes visual flicker
        guard let target = protectedApp, !target.isTerminated else {
            fgLog("Protected app gone, stopping guard")
            stopGuarding()
            return
        }

        if #available(macOS 14.0, *) {
            target.activate()
        } else {
            target.activate(options: .activateIgnoringOtherApps)
        }
        syncStateFiles()

        // Flash deferred to avoid AppKit autorelease crash (window creation
        // in the same run loop iteration as activate() causes use-after-free)
        DispatchQueue.main.async {
            PulseOverlay.shared.flash()
        }
    }
}

// MARK: - Logging

func fgLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)"
    print(line)

    let logDir = NSHomeDirectory() + "/.config/focus-guard"
    let logPath = logDir + "/.log"
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Signal Handling

func crashLogDirect(_ message: String) {
    let logPath = NSHomeDirectory() + "/.config/focus-guard/.log"
    let line = "[CRASH] \(message)\n"
    if let fd = fopen(logPath, "a") {
        fputs(line, fd)
        fclose(fd)
    }
}

signal(SIGSEGV) { sig in
    crashLogDirect("Caught SIGSEGV (signal \(sig))")
    signal(sig, SIG_DFL)
    raise(sig)
}

signal(SIGBUS) { sig in
    crashLogDirect("Caught SIGBUS (signal \(sig))")
    signal(sig, SIG_DFL)
    raise(sig)
}

signal(SIGABRT) { sig in
    crashLogDirect("Caught SIGABRT (signal \(sig))")
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - CLI

func printUsage() {
    print("""
    FocusGuard — prevent apps from stealing window focus

    Usage: FocusGuard [command]

    Commands (sent to running instance):
      --guard-frontmost    Guard the current frontmost app
      --guard <bundle-id>  Guard a specific app by bundle ID
      --stop               Stop guarding
      --toggle             Toggle guarding on/off
      --status             Print current guard status
      --log                Tail the log file
      --help               Show this help

    If no command is given, starts the FocusGuard daemon.
    """)
}

// MARK: - App Setup

let args = CommandLine.arguments.dropFirst() // drop executable path
let pidPath = "/tmp/focus-guard.pid"

func isInstanceRunning() -> Bool {
    guard let existingPID = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = Int32(existingPID),
          kill(pid, 0) == 0 else {
        return false
    }
    return true
}

// Handle CLI commands — send to running instance and exit
if let first = args.first, first.hasPrefix("--") {
    let cmd = String(first.dropFirst(2))

    switch cmd {
    case "help":
        printUsage()
        exit(0)
    case "log":
        let logPath = NSHomeDirectory() + "/.config/focus-guard/.log"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-f", logPath]
        task.standardOutput = FileHandle.standardOutput
        try? task.run()
        task.waitUntilExit()
        exit(0)
    case "status":
        if isInstanceRunning() {
            FocusGuard.sendCommand("status")
            // Read state file for immediate output
            if let state = try? String(contentsOfFile: NSHomeDirectory() + "/.config/focus-guard/.state", encoding: .utf8) {
                print(state)
            }
        } else {
            print("FocusGuard is not running.")
        }
        exit(0)
    case "guard-frontmost":
        guard isInstanceRunning() else { print("FocusGuard is not running. Start it first."); exit(1) }
        FocusGuard.sendCommand("guard-frontmost")
        print("Sent: guard-frontmost")
        exit(0)
    case "guard":
        guard let bundleID = args.dropFirst().first else { print("Usage: FocusGuard --guard <bundle-id>"); exit(1) }
        guard isInstanceRunning() else { print("FocusGuard is not running. Start it first."); exit(1) }
        FocusGuard.sendCommand("guard:\(bundleID)")
        print("Sent: guard \(bundleID)")
        exit(0)
    case "stop":
        guard isInstanceRunning() else { print("FocusGuard is not running."); exit(0) }
        FocusGuard.sendCommand("stop")
        print("Sent: stop")
        exit(0)
    case "toggle":
        guard isInstanceRunning() else { print("FocusGuard is not running. Start it first."); exit(1) }
        FocusGuard.sendCommand("toggle")
        print("Sent: toggle")
        exit(0)
    default:
        print("Unknown command: --\(cmd)")
        printUsage()
        exit(1)
    }
}

// Daemon mode — start the app
fgLog("FocusGuard starting (pid \(ProcessInfo.processInfo.processIdentifier))...")

if let existingPID = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
   let pid = Int32(existingPID) {
    if kill(pid, 0) == 0 {
        fgLog("Already running (pid \(pid)). Exiting.")
        exit(0)
    } else {
        fgLog("Stale PID file found (pid \(pid), not running). Cleaning up.")
        try? FileManager.default.removeItem(atPath: pidPath)
    }
}

do {
    try "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidPath, atomically: true, encoding: .utf8)
    fgLog("PID file written.")
} catch {
    fgLog("ERROR: Failed to write PID file: \(error)")
}

// Clean up on exit
atexit {
    unlink(pidPath)
    StateManager.shared.clearOnExit()
    fgLog("FocusGuard exiting.")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let guard_ = FocusGuard()
objc_setAssociatedObject(app, "focusGuard", guard_, .OBJC_ASSOCIATION_RETAIN)

// Pre-create overlay windows at startup (not during focus events)
PulseOverlay.shared.setup()

fgLog("FocusGuard ready.")
app.run()

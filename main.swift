// ScreenFocus — when the mouse crosses onto another display, focus the
// frontmost window on that display. Lives in the menu bar.

import Cocoa
import ApplicationServices
import ServiceManagement

/// Frame of an Accessibility window element, in top-left-origin global
/// coordinates — the same space CGWindowList and CGDisplayBounds use.
func axFrame(_ el: AXUIElement) -> CGRect? {
    var posV: CFTypeRef?
    var sizeV: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
          let posV, let sizeV,
          CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID()
    else { return nil }
    let pos = posV as! AXValue
    let size = sizeV as! AXValue
    guard AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    guard AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var watchdogTimer: Timer?
    private var activity: NSObjectProtocol?
    private var lastDisplay: CGDirectDisplayID?
    private let myPID = ProcessInfo.processInfo.processIdentifier

    /// Never block the run loop for long on a wedged app's AX server.
    private let axTimeout: Float = 0.25

    // Diagnostics, surfaced in the menu so a silent failure is never silent again.
    private var ticks = 0
    private var crossings = 0
    private var focused = 0
    private var lastNote = "nothing yet"
    private var lastTickAt = Date()

    private var enabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "display.2", accessibilityDescription: "ScreenFocus") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "⇄"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Ask for Accessibility permission (needed to raise other apps' windows).
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSLog("ScreenFocus: launched · Accessibility %@", trusted ? "granted" : "NOT granted")

        lastDisplay = displayUnderCursor()

        // Keep macOS from App-Napping us; a napped app stops reacting.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Watching which display the mouse is on")

        startPolling()

        // A display being added, removed or rearranged invalidates which display
        // the cursor is over; resync so the next move isn't read as a crossing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastDisplay = self.displayUnderCursor()
            self.note("display layout changed")
        }

        // Timers can be left unscheduled across a sleep/wake cycle; rebuild.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.startPolling()
            self.lastDisplay = self.displayUnderCursor()
            self.note("woke from sleep")
        }
    }

    /// Poll the cursor 20x/sec. Unlike an event monitor this can't silently stop
    /// delivering, and the per-tick work is two cheap CoreGraphics queries.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        lastTickAt = Date()

        guard watchdogTimer == nil else { return }
        let watchdog = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastTickAt) > 2 else { return }
            self.note("poll timer stalled — restarted")
            self.startPolling()
        }
        watchdog.tolerance = 5
        RunLoop.main.add(watchdog, forMode: .common)
        watchdogTimer = watchdog
    }

    // MARK: Core logic
    //
    // Everything below stays in CoreGraphics' global top-left-origin coordinate
    // space: the cursor, the display bounds and the window bounds all come from
    // CG. There is no NSScreen involved, so there is no cached screen list to go
    // stale and no bottom-left/top-left flip to get wrong.

    private func displayUnderCursor() -> CGDirectDisplayID? {
        guard let p = CGEvent(source: nil)?.location else { return nil }
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// Record a diagnostic for the menu and mirror it to the unified log, so the
    /// app can be diagnosed with `log stream --process ScreenFocus` as well.
    private func note(_ message: String) {
        lastNote = message
        NSLog("ScreenFocus: %@", message)
    }

    private func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return 0 }
        return Int(count)
    }

    private func tick() {
        lastTickAt = Date()
        ticks += 1

        guard enabled, let id = displayUnderCursor(), id != lastDisplay else { return }
        lastDisplay = id
        crossings += 1

        // Dragging something across (e.g. a window)? Only track the display.
        guard NSEvent.pressedMouseButtons == 0 else {
            note("crossed while dragging — ignored")
            return
        }

        guard AXIsProcessTrusted() else {
            note("no Accessibility permission — re-grant it in System Settings")
            return
        }

        guard let target = topWindow(on: id) else {
            note("no window found on display \(id)")
            return
        }
        focus(pid: target.pid, window: target.window)
        focused += 1
    }

    /// Frontmost real window whose centre lies on `display`.
    ///
    /// Candidates come from CGWindowList (front-to-back), but a CG window is not
    /// necessarily a real window — browsers in particular publish thin toolbar and
    /// overlay layers that sit in front of their actual window. Each candidate is
    /// therefore resolved against the owning app's Accessibility window list, and
    /// the first one that resolves wins. Anything that isn't a genuine window has
    /// no AX counterpart and is skipped automatically.
    private func topWindow(on display: CGDirectDisplayID) -> (pid: pid_t, window: AXUIElement)? {
        let bounds = CGDisplayBounds(display)
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var probed = 0
        for w in list {
            guard probed < 8 else { break }
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width > 80, rect.height > 80,
                  bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
            else { continue }

            probed += 1
            if let el = axWindow(pid: pid, matching: rect) {
                note("focused \(w[kCGWindowOwnerName as String] as? String ?? "window") on display \(display)")
                return (pid, el)
            }
        }
        return nil
    }

    /// The app's AX window whose frame best fits `frame`, if one fits closely.
    private func axWindow(pid: pid_t, matching frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        var best: (el: AXUIElement, error: CGFloat)?
        for el in windows {
            guard let f = axFrame(el) else { continue }
            let error = abs(f.minX - frame.minX) + abs(f.minY - frame.minY)
                      + abs(f.width - frame.width) + abs(f.height - frame.height)
            if best == nil || error < best!.error { best = (el, error) }
        }
        guard let best, best.error <= 8 else { return nil }
        return best.el
    }

    private func focus(pid: pid_t, window: AXUIElement) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        AXUIElementSetMessagingTimeout(window, axTimeout)

        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])

        // Some apps re-order their windows on activation; raise once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        if AXIsProcessTrusted() {
            addInfo("Accessibility: granted", to: menu)
        } else {
            let ax = NSMenuItem(title: "Grant Accessibility Access…",
                                action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        addInfo("Displays: \(activeDisplayCount()) · crossings: \(crossings) · focused: \(focused)",
                to: menu)
        addInfo("Last: \(lastNote)", to: menu)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenFocus",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        lastDisplay = displayUnderCursor()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
            NSLog("ScreenFocus: login item error: \(error)")
        }
    }

    @objc private func openAXSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()

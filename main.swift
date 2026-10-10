// ScreenFocus — when the mouse crosses onto another display, focus the
// frontmost window on that display. Lives in the menu bar.

import Cocoa
import ApplicationServices
import ServiceManagement

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Frame of an Accessibility window element, in top-left-origin global coordinates.
func axFrame(_ el: AXUIElement) -> CGRect? {
    var posV: CFTypeRef?
    var sizeV: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
          let posV, let sizeV else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(posV as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Any?
    private var lastScreen: CGDirectDisplayID?
    private let myPID = ProcessInfo.processInfo.processIdentifier

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
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
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        lastScreen = screenUnderMouse()?.displayID

        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.handle(event)
        }

        // Monitor plugged/unplugged or rearranged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastScreen = self?.screenUnderMouse()?.displayID
        }
    }

    // MARK: Core logic

    private func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    private func handle(_ event: NSEvent) {
        guard enabled,
              let screen = screenUnderMouse(),
              let id = screen.displayID,
              id != lastScreen else { return }
        lastScreen = id

        // Dragging something across (e.g. a window)? Only track the screen.
        guard event.type == .mouseMoved, NSEvent.pressedMouseButtons == 0 else { return }

        if let w = topWindow(on: screen) {
            focus(pid: w.pid, frame: w.frame)
        }
    }

    /// Frontmost normal window whose centre lies on `screen`.
    private func topWindow(on screen: NSScreen) -> (pid: pid_t, frame: CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Convert the screen frame (bottom-left origin) to CG coords (top-left origin).
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY,
                            width: f.width, height: f.height)

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // The list is ordered front-to-back.
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width > 50, rect.height > 50,
                  target.contains(CGPoint(x: rect.midX, y: rect.midY))
            else { continue }
            return (pid, rect)
        }
        return nil
    }

    private func focus(pid: pid_t, frame: CGRect) {
        let app = AXUIElementCreateApplication(pid)

        // Find the matching AX window by position and size.
        var window: AXUIElement?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            window = windows.first { el in
                guard let f = axFrame(el) else { return false }
                return abs(f.minX - frame.minX) < 2 && abs(f.minY - frame.minY) < 2 &&
                       abs(f.width - frame.width) < 2 && abs(f.height - frame.height) < 2
            }
        }

        if let window {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])

        // Some apps re-order their windows on activation; raise once more.
        if let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
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

        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let ax = NSMenuItem(title: "Grant Accessibility Access…",
                                action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenFocus",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        lastScreen = screenUnderMouse()?.displayID
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

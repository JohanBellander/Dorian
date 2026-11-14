// Dorian: one Dock icon per Chrome profile.
//
// Opened directly, Dorian shows its setup window. Opened by a launcher through
// dorian://switch?profile=<name>, it presses that profile in Chrome's Profiles
// menu and quits again (unless the setup window is open).

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: SetupModel?
    private var pendingSwitches = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        let events = NSAppleEventManager.shared()
        events.setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                               forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        events.setEventHandler(self, andSelector: #selector(handleOpen(_:reply:)),
                               forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
        NSApp.mainMenu = mainMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { pendingSwitches == 0 }

    @objc private func handleOpen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        showWindow()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: text), components.host == "switch",
              let profile = components.queryItems?.first(where: { $0.name == "profile" })?.value, !profile.isEmpty
        else {
            log("ERROR: ignored URL \(event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? "?")")
            quitIfIdle()
            return
        }
        guard AXIsProcessTrusted() else {
            log("Not trusted for Accessibility; showing setup")
            showWindow()
            return
        }
        pendingSwitches += 1
        Task {
            do {
                try await Chrome.switchTo(profile)
            } catch {
                log("ERROR: \(error.localizedDescription)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn't switch to \(profile)"
                alert.informativeText = "\(error.localizedDescription)\n\nDetails: ~/Library/Logs/Dorian.log"
                alert.runModal()
            }
            pendingSwitches -= 1
            quitIfIdle()
        }
    }

    private func quitIfIdle() {
        if pendingSwitches == 0 && window?.isVisible != true { NSApp.terminate(nil) }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let model = SetupModel()
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            window.title = "Dorian"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.model = model
            self.window = window
        }
        model?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        // Ordering the window front during launch can leave it behind the
        // previously active app; repeat once the run loop has turned.
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Dorian", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(editItem)
        return menu
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

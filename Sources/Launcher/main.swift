// Dock launcher stub. Dorian copies this binary into each "Chrome - <Profile>.app".
// It hands the profile to Dorian through the URL scheme and exits; it never uses
// Accessibility itself, so launchers need no permission of their own.

import AppKit

let info = Bundle.main.infoDictionary ?? [:]
let profile = info["DorianProfile"] as? String ?? ""
let scheme = info["DorianURLScheme"] as? String ?? "dorian"

var components = URLComponents()
components.scheme = scheme
components.host = "switch"
components.queryItems = [URLQueryItem(name: "profile", value: profile)]

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// This launcher is the active app right after the Dock click, so it can pass
// activation on to Chrome. Dorian then only has to press the menu item.
if let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
    if #available(macOS 14.0, *) { app.yieldActivation(to: chrome) }
    chrome.activate()
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
var finished = false
NSWorkspace.shared.open(components.url!, configuration: configuration) { _, error in
    DispatchQueue.main.async {
        if let error {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Dorian isn't installed"
            alert.informativeText = "This Dock icon needs Dorian.app to switch Chrome profiles.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        finished = true
    }
}
let deadline = Date().addingTimeInterval(10)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

// Chrome's Profiles menu through the Accessibility API: finding it, listing the
// profiles in it and pressing one.

import AppKit
import ApplicationServices

struct DorianError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Dorian.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum Chrome {
    static let bundleID = "com.google.Chrome"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    struct ProfilesMenu {
        let title: String
        let profiles: [(name: String, element: AXUIElement)]
    }

    /// Chrome's Profiles menu, found by its shape (`looksLikeProfilesMenu`), which
    /// works in every UI language. The `ProfilesMenuTitle` default overrides it if
    /// a Chrome version changes the menu.
    static func profilesMenu(of app: NSRunningApplication) -> ProfilesMenu? {
        let override = UserDefaults.standard.string(forKey: "ProfilesMenuTitle")
        for (menuTitle, items) in menus(of: app) {
            let titles = items.map(title)
            let matches = override.map { menuTitle == $0 } ?? looksLikeProfilesMenu(titles)
            guard matches, let firstSeparator = titles.firstIndex(of: "") ?? (override != nil ? titles.count : nil)
            else { continue }
            return ProfilesMenu(title: menuTitle,
                                profiles: (0..<firstSeparator).map { (titles[$0], items[$0]) })
        }
        return nil
    }

    /// Profile names, then ["", "Edit…", "", "Add Profile…"], or just ["", "Edit…"]
    /// when a policy disables adding profiles. No other Chrome menu has this shape.
    static func looksLikeProfilesMenu(_ t: [String]) -> Bool {
        guard let firstSeparator = t.firstIndex(of: ""), firstSeparator > 0 else { return false }
        let tail = Array(t[firstSeparator...])
        let isCommand = { (s: String) in s.hasSuffix("…") }
        switch tail.count {
        case 2: return isCommand(tail[1])
        case 4: return isCommand(tail[1]) && tail[2] == "" && isCommand(tail[3])
        default: return false
        }
    }

    /// Top-level menus as (title, items), skipping the Apple menu.
    static func menus(of app: NSRunningApplication) -> [(String, [AXUIElement])] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return [] }
        return children(bar).dropFirst().map { item in
            (title(item), children(item).first.map(children) ?? [])
        }
    }

    /// The running Chrome, launching it first if needed and waiting until its
    /// Profiles menu exists.
    static func runningOrLaunch(timeout: Double = 20) async throws -> NSRunningApplication {
        if let app = running, app.isFinishedLaunching { return app }
        if running == nil {
            guard let url = appURL else { throw DorianError("Google Chrome (\(bundleID)) is not installed.") }
            log("Chrome not running; launching \(url.path)")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = running, app.isFinishedLaunching, profilesMenu(of: app) != nil { return app }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DorianError("Chrome did not finish launching within \(Int(timeout)) seconds.")
    }

    /// Presses `profile` in the Profiles menu: Chrome then brings that profile's
    /// last active window to the front, or opens one if it has none.
    static func switchTo(_ profile: String) async throws {
        let app = try await runningOrLaunch()
        var menu = profilesMenu(of: app)
        // Right after launch Chrome may still be filling the menu.
        for _ in 0..<50 where menu?.profiles.contains(where: { $0.name == profile }) != true {
            try await Task.sleep(nanoseconds: 100_000_000)
            menu = profilesMenu(of: app)
        }
        guard let menu else {
            throw DorianError("""
                Couldn't find Chrome's Profiles menu. Menus: \(menus(of: app).map(\.0).joined(separator: ", ")). \
                If Chrome changed it, run: defaults write \(Bundle.main.bundleIdentifier ?? "Dorian") \
                ProfilesMenuTitle "<menu title>"
                """)
        }
        guard let item = menu.profiles.first(where: { $0.name == profile })?.element else {
            throw DorianError("""
                Chrome has no profile named "\(profile)" (found: \(menu.profiles.map(\.name).joined(separator: ", "))). \
                Open Dorian to update your Dock icons.
                """)
        }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        app.activate()
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else {
            throw DorianError("Pressing \"\(profile)\" in Chrome's \"\(menu.title)\" menu failed (AXError \(result.rawValue)).")
        }
        app.activate()
        log("Switched to \"\(profile)\"")
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func title(_ element: AXUIElement) -> String { attribute(element, kAXTitleAttribute) ?? "" }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }
}

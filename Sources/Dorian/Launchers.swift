// Creating and removing the per-profile Dock launchers in ~/Applications.
// A launcher is Dorian's bundled stub binary plus an Info.plist and an icon,
// signed ad-hoc: it needs no permissions, so its signature can change freely.

import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum Launchers {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    static let customIcons = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dorian/Icons")
    static var idPrefix: String { (Bundle.main.bundleIdentifier ?? "dorian") + ".launcher." }

    /// Installed Dorian launchers by profile name. Only bundles with Dorian's ID
    /// prefix count, so other apps in ~/Applications are never touched.
    static func installed() -> [String: URL] {
        let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for url in apps where url.pathExtension == "app" {
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  (info["CFBundleIdentifier"] as? String)?.hasPrefix(idPrefix) == true,
                  let profile = info["DorianProfile"] as? String else { continue }
            result[profile] = url
        }
        return result
    }

    /// Readable ASCII slug plus a hash of the exact name, so different names
    /// ("A/B" and "A-B", "Work" and "Work!") never share a bundle ID or icon file.
    static func key(_ name: String) -> String {
        let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        var hash: UInt32 = 2_166_136_261 // FNV-1a: stable across runs, unlike Hasher
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return (slug.isEmpty ? "profile" : slug) + "-" + String(format: "%08x", hash)
    }

    static func appURL(for profile: String) -> URL {
        let safe = profile.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("Chrome - \(safe).app")
    }

    static func customIconURL(for profile: String) -> URL {
        customIcons.appendingPathComponent("\(key(profile)).png")
    }

    static func overlayPictureURL(for profile: String) -> URL {
        customIcons.appendingPathComponent("\(key(profile))-overlay.png")
    }

    static func create(profile: String, icon: NSImage) throws -> URL {
        let target = appURL(for: profile)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), !installed().values.map(\.path).contains(target.path) {
            throw DorianError("\(target.lastPathComponent) already exists in ~/Applications and wasn't made by Dorian. Rename or remove it first.")
        }
        guard let stub = Bundle.main.url(forResource: "launcher", withExtension: nil) else {
            throw DorianError("The launcher stub is missing from Dorian.app; rebuild Dorian.")
        }

        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        let app = staging.appendingPathComponent(target.lastPathComponent)
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: stub, to: contents.appendingPathComponent("MacOS/launcher"))

        let bundleID = idPrefix + key(profile)
        let info: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Chrome - \(profile)",
            "CFBundleDisplayName": "Chrome - \(profile)",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true,
            "DorianProfile": profile,
            "DorianURLScheme": "dorian",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try writeICNS(icon, to: contents.appendingPathComponent("Resources/AppIcon.icns"))

        // The icon is in place before signing, so the signature covers it.
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, app.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.moveItem(at: app, to: target)
        LSRegisterURL(target as CFURL, true)
        log("Created \(target.path)")
        return target
    }

    static func remove(_ url: URL) throws {
        guard installed().values.map(\.path).contains(url.path) else { throw DorianError("\(url.path) is not a Dorian launcher.") }
        try FileManager.default.removeItem(at: url)
        log("Removed \(url.path)")
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DorianError("\(tool) \(arguments.first ?? "") failed: \(text)")
        }
    }

    private static func writeICNS(_ image: NSImage, to url: URL) throws {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString,
                                                                sizes.count, nil) else {
            throw DorianError("Can't write icon file.")
        }
        for px in sizes {
            guard let cg = Icons.bitmap(image, px: px) else { continue }
            CGImageDestinationAddImage(destination, cg, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw DorianError("Can't write icon file.") }
    }
}

@MainActor
enum Icons {
    static let colors: [NSColor] = [0x1E88E5, 0xE53935, 0x43A047, 0xFB8C00, 0x8E24AA, 0x00897B, 0x6D4C41, 0x3949AB]
        .map { NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255,
                       blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }

    /// One distinct badge letter per profile: the first letter of the name, else
    /// of a later word ("Alex (example.com)" → E next to "Alex" → A), else any
    /// unused letter of the name.
    static func letters(for names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
            let candidates = words.compactMap { $0.first.map(String.init) } + name.uppercased().filter(\.isLetter).map(String.init)
            let letter = candidates.first { !used.contains($0) } ?? candidates.first ?? "?"
            used.insert(letter)
            return letter
        }
    }

    static var chromeIcon: NSImage {
        if let url = Chrome.appURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    enum Overlay { case letter(String, NSColor), picture(NSImage) }

    /// Apple's icon grid on a 1024 canvas. The Dock shows an icon full size only
    /// when nothing is drawn outside this rounded square; otherwise macOS shrinks
    /// it into a gray box.
    private static let gridOrigin = 100.0, gridSide = 824.0, gridRadius = 185.0

    /// A launcher icon: `base` (Chrome's icon from the user's own install, or the
    /// user's image clipped to the grid) with an optional round overlay placed by
    /// `style`, always inside the grid.
    static func compose(base: NSImage, clipBase: Bool, overlay: Overlay?, style: OverlayStyle) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            let k = rect.width / 1024
            let grid = NSRect(x: gridOrigin * k, y: gridOrigin * k, width: gridSide * k, height: gridSide * k)
            NSGraphicsContext.saveGraphicsState()
            if clipBase { NSBezierPath(roundedRect: grid, xRadius: gridRadius * k, yRadius: gridRadius * k).addClip() }
            fill(rect, with: base)
            NSGraphicsContext.restoreGraphicsState()
            guard let overlay else { return true }

            let badge = overlayRect(style, in: rect), d = badge.width
            let inner = badge.insetBy(dx: d * 0.07, dy: d * 0.07)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            switch overlay {
            case .letter(let letter, let color):
                color.setFill()
                NSBezierPath(ovalIn: inner).fill()
                let text = NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: d * 0.58, weight: .heavy),
                    .foregroundColor: NSColor.white,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
            case .picture(let picture):
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: inner).addClip()
                fill(inner, with: picture)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// The overlay's circle on an icon drawn in `canvas`, placed by `style` and
    /// always inside the grid's rounded square.
    static func overlayRect(_ style: OverlayStyle, in canvas: NSRect) -> NSRect {
        let k = canvas.width / 1024
        let grid = NSRect(x: canvas.minX + gridOrigin * k, y: canvas.minY + gridOrigin * k,
                          width: gridSide * k, height: gridSide * k)
        let d = style.size * grid.width, b = d / 2, r = gridRadius * k, margin = 16 * k
        // How far from the grid's edges a circle of radius b sits when it
        // touches the rounded corner (or both edges, once b reaches the radius).
        let inset = (b >= r ? b : r - (r - b) / 2.squareRoot()) + margin
        let x: CGFloat, y: CGFloat
        switch style.position {
        case .center: (x, y) = (grid.midX, grid.midY)
        case .topLeft: (x, y) = (grid.minX + inset, grid.maxY - inset)
        case .topRight: (x, y) = (grid.maxX - inset, grid.maxY - inset)
        case .bottomLeft: (x, y) = (grid.minX + inset, grid.minY + inset)
        case .bottomRight: (x, y) = (grid.maxX - inset, grid.minY + inset)
        }
        return NSRect(x: x - b, y: y - b, width: d, height: d)
    }

    /// Draws `image` to cover `rect`, keeping its aspect ratio (the caller clips).
    private static func fill(_ rect: NSRect, with image: NSImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    static func bitmap(_ image: NSImage, px: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Where the overlay sits on every launcher icon, and how big it is.
struct OverlayStyle: Equatable {
    enum Position: String, CaseIterable, Identifiable {
        case topLeft, topRight, center, bottomLeft, bottomRight
        var id: String { rawValue }
        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .center: "Center"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    var position: Position
    /// Diameter as a fraction of the icon's rounded square.
    var size: Double

    static let sizes = 0.2...0.7

    static var saved: OverlayStyle {
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: "OverlaySize") as? Double ?? 0.42
        return OverlayStyle(position: defaults.string(forKey: "OverlayPosition").flatMap(Position.init) ?? .bottomRight,
                            size: min(max(size, sizes.lowerBound), sizes.upperBound))
    }

    func save() {
        UserDefaults.standard.set(position.rawValue, forKey: "OverlayPosition")
        UserDefaults.standard.set(size, forKey: "OverlaySize")
    }
}

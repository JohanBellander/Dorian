// The setup window: Accessibility status, the profiles found in Chrome, and one
// button that creates, refreshes and removes the Dock launchers.

import AppKit
import ApplicationServices
import SwiftUI

/// What a profile's icon shows on top of Chrome's icon (or its own background).
enum OverlayKind: String { case letter, picture, none }

@MainActor
final class SetupModel: ObservableObject {
    struct Row: Identifiable {
        var id: String { name }
        let name: String
        let inChrome: Bool
        let installed: URL?
        let icon: NSImage
        let hasCustomIcon: Bool
        let overlay: OverlayKind
        /// Why this profile can't get a launcher (a name clash), if it can't.
        let problem: String?
    }

    @Published var trusted = AXIsProcessTrusted()
    @Published var chromeRunning = Chrome.running != nil
    /// Empty unless the Profiles menu was read successfully just now, so a failed
    /// read can never make installed launchers look stale and get them removed.
    @Published var rows: [Row] = []
    @Published var status: String?
    @Published var working = false
    @Published var showingOverlay = false
    private var timer: Timer?

    /// Profiles the user switched off. Everything else in Chrome is on, so new
    /// profiles get an icon on the next update and a switched-off one stays off.
    private static let deselectedKey = "DeselectedProfiles"
    @Published private var deselected = Set(UserDefaults.standard.stringArray(forKey: deselectedKey) ?? [])

    /// Overlay per profile; profiles not listed get a letter.
    private static let overlaysKey = "Overlays"
    private var overlays = UserDefaults.standard.dictionary(forKey: overlaysKey) as? [String: String] ?? [:]

    /// Position and size of the overlay on every icon.
    @Published var style = OverlayStyle.saved {
        didSet { style.save(); refresh() }
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func isSelected(_ row: Row) -> Bool { row.inChrome && row.problem == nil && !deselected.contains(row.name) }

    func setSelected(_ row: Row, _ on: Bool) {
        if on { deselected.remove(row.name) } else { deselected.insert(row.name) }
        UserDefaults.standard.set(deselected.sorted(), forKey: Self.deselectedKey)
    }

    /// Profiles in Chrome's menu order, plus launchers whose profile is gone.
    func refresh() {
        trusted = AXIsProcessTrusted()
        let chrome = Chrome.running
        chromeRunning = chrome != nil
        guard trusted, let menu = chrome.flatMap(Chrome.profilesMenu) else {
            rows = []
            return
        }
        let names = menu.profiles.map(\.name)
        let installed = Launchers.installed()
        let letters = Icons.letters(for: names)
        let paths = names.map { Launchers.appURL(for: $0).path }
        var rows = names.enumerated().map { i, name in
            let clash = names.indices.contains { $0 != i && (names[$0] == name || paths[$0] == paths[i]) }
            let custom = NSImage(contentsOf: Launchers.customIconURL(for: name))
            var kind = overlays[name].flatMap(OverlayKind.init) ?? .letter
            let picture = kind == .picture ? NSImage(contentsOf: Launchers.overlayPictureURL(for: name)) : nil
            if kind == .picture && picture == nil { kind = .letter }
            let overlay: Icons.Overlay? = switch kind {
            case .letter: .letter(letters[i], Icons.colors[i % Icons.colors.count])
            case .picture: picture.map(Icons.Overlay.picture)
            case .none: nil
            }
            return Row(name: name, inChrome: true, installed: installed[name],
                       icon: Icons.compose(base: custom ?? Icons.chromeIcon, clipBase: custom != nil,
                                           overlay: overlay, style: style),
                       hasCustomIcon: custom != nil, overlay: kind,
                       problem: clash ? "Another profile has the same or a too similar name; rename one in Chrome" : nil)
        }
        for (name, url) in installed.sorted(by: { $0.key < $1.key }) where !names.contains(name) {
            rows.append(Row(name: name, inChrome: false, installed: url,
                            icon: NSWorkspace.shared.icon(forFile: url.path), hasCustomIcon: false, overlay: .none,
                            problem: nil))
        }
        self.rows = rows
    }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func startChrome() {
        Task {
            do { _ = try await Chrome.runningOrLaunch() } catch { status = error.localizedDescription }
            refresh()
        }
    }

    func chooseIcon(for row: Row) {
        if pickImage("Choose a background image for \(row.name)", saveTo: Launchers.customIconURL(for: row.name)) {
            setSelected(row, true)
            status = "Background set. Click Update Dock Icons to apply it."
        }
        refresh()
    }

    func resetIcon(for row: Row) {
        try? FileManager.default.removeItem(at: Launchers.customIconURL(for: row.name))
        status = "Chrome icon restored. Click Update Dock Icons to apply it."
        refresh()
    }

    func chooseOverlayPicture(for row: Row) {
        if pickImage("Choose a picture for \(row.name)", saveTo: Launchers.overlayPictureURL(for: row.name)) {
            setOverlay(row, .picture)
        }
    }

    func setOverlay(_ row: Row, _ kind: OverlayKind) {
        overlays[row.name] = kind.rawValue
        UserDefaults.standard.set(overlays, forKey: Self.overlaysKey)
        status = "Overlay changed. Click Update Dock Icons to apply it."
        refresh()
    }

    /// Asks for an image and stores it as a 1024 px PNG. False if cancelled or unreadable.
    private func pickImage(_ message: String, saveTo target: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            guard let image = NSImage(contentsOf: url), let cg = Icons.bitmap(image, px: 1024),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw DorianError("\(url.lastPathComponent) can't be read as an image.")
            }
            try FileManager.default.createDirectory(at: Launchers.customIcons, withIntermediateDirectories: true)
            try png.write(to: target)
            return true
        } catch {
            status = "Couldn't use that image: \(error.localizedDescription)"
            return false
        }
    }

    var hasInstalled: Bool { rows.contains { $0.installed != nil } }

    /// Creates or refreshes the selected launchers and removes the unselected ones.
    func apply() {
        working = true
        defer { working = false; refresh() }
        var created: [URL] = [], removed = 0, errors: [String] = []
        let actionable = rows.filter { $0.problem == nil }
        // Removals first: a renamed profile ("A/B" → "A-B") can map to the same
        // app path, and must not have its new launcher removed as the stale one.
        for row in actionable where !isSelected(row) {
            guard let url = row.installed else { continue }
            do {
                try Launchers.remove(url)
                removed += 1
            } catch {
                log("ERROR: \(error.localizedDescription)")
                errors.append(error.localizedDescription)
            }
        }
        for row in actionable where isSelected(row) {
            do {
                created.append(try Launchers.create(profile: row.name, icon: row.icon))
            } catch {
                log("ERROR: \(error.localizedDescription)")
                errors.append(error.localizedDescription)
            }
        }
        var lines: [String] = []
        if !created.isEmpty {
            lines.append("\(created.count) Dock icon\(created.count == 1 ? "" : "s") ready. Drag them from Finder to the Dock.")
        }
        if removed > 0 { lines.append("\(removed) removed.") }
        status = (lines + errors).joined(separator: "\n")
        if !created.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(created) }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dorian").font(.title2.bold())
                    Text("One Dock icon per Chrome profile. Clicking it brings that profile's window to the front.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.trusted {
                notice("Dorian needs Accessibility access to press Chrome's Profiles menu.",
                       detail: "Turn Dorian on in the list that opens. Don't add it with “+”: that entry won't work.",
                       button: "Grant Access…", action: model.requestAccess)
            } else if !model.chromeRunning {
                notice("Start Chrome to see its profiles.", detail: nil, button: "Start Chrome", action: model.startChrome)
            } else if model.rows.isEmpty {
                notice("No profiles found in Chrome's Profiles menu.", detail: "See ~/Library/Logs/Dorian.log.",
                       button: nil, action: {})
            }

            if !model.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(get: { model.isSelected(row) }, set: { model.setSelected(row, $0) }))
                                .labelsHidden()
                                .disabled(!row.inChrome || row.problem != nil)
                            Image(nsImage: row.icon).resizable().frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                Text(caption(row)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.inChrome {
                                Menu("Icon") {
                                    Section("Overlay") {
                                        choice("Letter", row.overlay == .letter) { model.setOverlay(row, .letter) }
                                        choice("Picture…", row.overlay == .picture) { model.chooseOverlayPicture(for: row) }
                                        choice("None", row.overlay == .none) { model.setOverlay(row, .none) }
                                    }
                                    Section("Background") {
                                        choice("Chrome Icon", !row.hasCustomIcon) { model.resetIcon(for: row) }
                                        choice("Image…", row.hasCustomIcon) { model.chooseIcon(for: row) }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                        .padding(.vertical, 6)
                        if row.id != model.rows.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }

            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(Launchers.directory) }
                Button("Overlay…") { model.showingOverlay = true }
                    .disabled(model.rows.isEmpty)
                Spacer()
                Button(model.hasInstalled ? "Update Dock Icons" : "Create Dock Icons") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.rows.isEmpty || model.working)
            }
        }
        .padding(20)
        .frame(width: 480)
        .sheet(isPresented: $model.showingOverlay) { OverlaySettings(model: model) }
    }

    private func choice(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func caption(_ row: SetupModel.Row) -> String {
        if !row.inChrome { return "No longer in Chrome; will be removed" }
        if let problem = row.problem { return problem }
        return row.installed != nil ? "In ~/Applications" : "New"
    }

    private func notice(_ text: String, detail: String?, button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let button { Button(button, action: action) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
    }
}

/// Position and size of the overlay, with a live preview of the icons.
struct OverlaySettings: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Overlay").font(.headline)
            HStack(spacing: 12) {
                ForEach(model.rows.filter(\.inChrome).prefix(4)) { row in
                    Image(nsImage: row.icon).resizable().frame(width: 72, height: 72)
                }
            }
            .frame(maxWidth: .infinity)
            Picker("Position", selection: $model.style.position) {
                ForEach(OverlayStyle.Position.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Size")
                Slider(value: $model.style.size, in: OverlayStyle.sizes)
            }
            Text("Applies to every Dock icon. Click Update Dock Icons afterwards.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { model.showingOverlay = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

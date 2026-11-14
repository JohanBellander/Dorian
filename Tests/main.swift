// Unit checks for the parts that can break quietly: recognising Chrome's
// Profiles menu, launcher naming, badge letters and overlay placement.
// Run with ./test.sh; exits non-zero on the first failing group.

import AppKit

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

MainActor.assumeIsolated {
    // Profiles menu: names, then "", "Edit…", "", "Add Profile…" (or only "", "Edit…" under a policy).
    check(Chrome.looksLikeProfilesMenu(["Alex", "Work", "", "Edit…", "", "Add Profile…"]), "standard Profiles menu")
    check(Chrome.looksLikeProfilesMenu(["Alex", "", "Edit…"]), "Profiles menu without Add Profile")
    check(!Chrome.looksLikeProfilesMenu(["", "Edit…", "", "Add Profile…"]), "menu without profile names")
    check(!Chrome.looksLikeProfilesMenu(["New Tab", "New Window", "", "Close Window", "", "Print…", "Share"]),
          "File-like menu")
    check(!Chrome.looksLikeProfilesMenu(["Alex", "", "Edit", "", "Add Profile"]), "items without an ellipsis")
    check(!Chrome.looksLikeProfilesMenu(["Alex", "Work"]), "menu without separators")

    // Launcher keys: readable, stable, and different for names that slug alike.
    check(Launchers.key("Work") == Launchers.key("Work"), "key is stable")
    check(Launchers.key("A/B") != Launchers.key("A-B"), "A/B and A-B get different keys")
    check(Launchers.key("Work") != Launchers.key("Work!"), "Work and Work! get different keys")
    check(Launchers.key("Alex (example.com)").hasPrefix("alex-example-com-"), "readable slug")
    check(Launchers.key("Åsa").hasPrefix("sa-"), "non-ASCII letters drop out of the slug")
    check(Launchers.key("???").hasPrefix("profile-"), "empty slug falls back to profile")
    check(Launchers.key("Work").range(of: #"^[a-z0-9-]+-[0-9a-f]{8}$"#, options: .regularExpression) != nil,
          "key format is slug-hash")
    check(Launchers.appURL(for: "A/B:C").lastPathComponent == "Chrome - A-B-C.app", "app name replaces / and :")

    // Badge letters are distinct where the names allow it.
    check(Icons.letters(for: ["Alex", "Alex (example.com)"]) == ["A", "E"], "second Alex gets E")
    check(Icons.letters(for: ["Work", "Wendy"]) == ["W", "E"], "falls back to a later letter")
    check(Icons.letters(for: ["Bo", "Bo"]) == ["B", "O"], "same name still gets distinct letters")

    // Overlays stay inside Apple's rounded square (824 px at 100,100, radius 185 on a 1024 canvas).
    func insideGrid(_ p: CGPoint) -> Bool {
        let lo = 100.0, hi = 924.0, r = 185.0
        guard p.x >= lo - 0.5, p.x <= hi + 0.5, p.y >= lo - 0.5, p.y <= hi + 0.5 else { return false }
        let cx = min(max(p.x, lo + r), hi - r), cy = min(max(p.y, lo + r), hi - r)
        return hypot(p.x - cx, p.y - cy) <= r + 0.5
    }
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    for position in OverlayStyle.Position.allCases {
        for size in stride(from: OverlayStyle.sizes.lowerBound, through: OverlayStyle.sizes.upperBound, by: 0.05) {
            let rect = Icons.overlayRect(OverlayStyle(position: position, size: size), in: canvas)
            check(abs(rect.width - size * 824) < 0.01, "\(position) \(size): diameter")
            let edge = (0..<72).map { i -> CGPoint in
                let a = Double(i) * .pi / 36
                return CGPoint(x: rect.midX + cos(a) * rect.width / 2, y: rect.midY + sin(a) * rect.width / 2)
            }
            check(edge.allSatisfy(insideGrid), "\(position) \(size): circle inside the grid")
        }
    }
    let corner = Icons.overlayRect(OverlayStyle(position: .bottomRight, size: 0.42), in: canvas)
    check(corner.midX > 512 && corner.midY < 512, "bottom right is bottom right")
    let center = Icons.overlayRect(OverlayStyle(position: .center, size: 0.42), in: canvas)
    check(center.midX == 512 && center.midY == 512, "center is centered")
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All checks passed")

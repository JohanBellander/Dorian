# Dorian

A small native macOS utility that gives every Google Chrome profile its own Dock icon. Clicking one brings that
profile's existing window to the front, and opens a window only if the profile has none. It drives Chrome's
**Profiles** menu through the Accessibility API, so Chrome stays a single normal install (sync and updates keep
working). Intended for open-source release (MIT); built from source on the user's Mac.

## Stack
- Swift (AppKit + SwiftUI), compiled with `swiftc` from `build.sh`. No Xcode project, no third-party packages.
- macOS 13+, Apple Silicon (arm64) only.

## Design
- **Dorian.app** (main app) holds the only Accessibility approval. Opened directly it shows a small window: the
  profiles found in Chrome's Profiles menu, an icon preview per profile, and "Create Dock icons".
- **Launchers** (`~/Applications/Chrome - <Profile>.app`) are tiny stub apps the main app creates by copying its
  bundled stub, writing an Info.plist and icon, and signing with `/usr/bin/codesign`. A launcher asks the main app
  to switch (URL scheme) and exits; it never needs Accessibility itself.
- Profiles are discovered from the AX Profiles menu, not Chrome's `Local State` file: macOS blocks reading other
  apps' data without a separate permission. The menu is found by content, so any UI language works.
- Errors go to `~/Library/Logs/Dorian.log` and are shown in a dialog; never fail silently.

## Layout
- `Sources/Dorian/` main app: `main.swift` (app delegate, `dorian://switch` URL handling), `Chrome.swift` (AX:
  find the Profiles menu, launch Chrome, press a profile; logging), `Launchers.swift` (create/remove launchers,
  icons), `SetupView.swift` (SwiftUI setup window).
- `Sources/Launcher/main.swift` launcher stub, bundled as `Dorian.app/Contents/Resources/launcher`.
- `Resources/AppIcon.svg` app icon source; `Sources/Tools/iconset.swift` renders it to an iconset at build time.
- `build.sh` compiles both, writes Info.plist, signs, installs to `~/Applications`.

## Commands
- Build and install: `./build.sh` (env: `DORIAN_BUNDLE_ID`, `SIGN_IDENTITY`, `DEST`)
- Verify signatures: `codesign --verify --deep --strict ~/Applications/Dorian.app`
- No automated tests yet. Verify by hand: open Dorian, create launchers, `open` a launcher and read
  `~/Library/Logs/Dorian.log`. Count Chrome windows (CGWindowList) to prove no new window was opened.

## Conventions
- Keep it small: no settings that can be detected. The only user choice is an optional custom icon per profile.
- Put the icon in a bundle before signing it; any later change breaks the signature.
- Never hardcode a personal profile name or user path in committed code or docs.
- Apple Silicon only: macOS 27 warns that Intel code won't open in the next release.
- Each rebuild with an ad-hoc signature resets Dorian's Accessibility approval, and only a person can approve it
  again. Batch code changes into one build before asking for a test.

## Ways to hurt yourself
- **Accessibility "+" trap:** adding an app with "+" in System Settings creates a record keyed by *path*, but macOS
  checks running apps by *bundle ID*, so the switch shows on and the app is still untrusted. Approve by launching
  the app (macOS lists it, switched off) and switching that entry on. Restart System Settings if it isn't listed.
- **Ad-hoc signatures:** an ad-hoc approval matches only the exact build. Keep builds reproducible (no timestamps
  in Info.plist) and clear stale approvals with `tccutil reset Accessibility <bundle id>` when the signature changes.
- **Agent shells can't use AX:** the agent's own process isn't trusted, so `AXUIElement` reads fail there. Test AX
  through the built, approved app launched with `open`, and read the log.
- **Sandboxed agent shells** can't see other apps (`NSRunningApplication` returns nothing); run such checks unsandboxed.
- Chrome is often managed on work Macs; don't assume you may quit it. Ask first.
- **No SwiftUI macros:** the Command Line Tools lack the macro plugins, so `@State` and `@Environment` don't
  compile. Keep view state in `SetupModel` (`@Published`).
- **Icon grid:** anything drawn outside the 824 px rounded square (on a 1024 canvas) makes macOS 26+ shrink the
  icon into a gray box in the Dock. `Icons.compose` keeps overlays inside it.
- Chrome's data folder (`Local State`, profile pictures) is unreadable for other apps, so profile info comes only
  from the AX menu.

## Review
Process: global skill `pr-crosscheck`. Tier triggers beyond the defaults:
- T2: anything that deletes files (launcher cleanup), calls `tccutil`, or changes signing.
Invariants a reviewer must check:
- Cleanup only ever removes launchers Dorian created (identified by bundle ID prefix), never other apps.
- Launchers never call Accessibility APIs; only the main app does.
Failure looks like: a click that opens a new window instead of focusing the existing one, or a silent no-op.
At most 3 minor findings per review.

## Agent setup
This repo is worked on by Claude Code, Codex and Muse Code; keep them in sync.
- Rules: this file. `CLAUDE.md` only imports it — edit here.
- Skills: `.agents/skills/<name>/SKILL.md` is the source; `.claude/skills/` is a generated copy. After editing a skill run `node .agents/sync-skills.mjs` (`--check` to verify).
- Muse Code reads this file and `.agents/skills` directly once the workspace is trusted; nothing Muse-specific is committed.
- Permissions: `.claude/settings.json` `permissions.allow` and `.codex/rules/project.rules` list the same commands. Change both together.
- Handoff between agents: before stopping mid-task, write `.agent/handoff.md` (gitignored): goal, done, next, how to verify.

# Dorian

One Dock icon per Google Chrome profile. Click one and that profile's existing window comes to the front; Chrome
opens a window only if the profile has none.

Chrome has no built-in way to do this. `open -na "Google Chrome" --args --profile-directory=…` always opens a new
window, and separate `--user-data-dir` copies break sync and updates. Chrome's own **Profiles** menu does the right
thing, so Dorian presses it for you through the macOS Accessibility API. Chrome stays your normal, single install.

Not affiliated with Google. Requires an Apple Silicon Mac with macOS 13 or later.

## Install

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/JohanBellander/Dorian.git
cd Dorian
./build.sh
```

This builds `Dorian.app` and installs it in `~/Applications`.

## Set up

1. Open **Dorian** from `~/Applications`.
2. Click **Grant Access…** and switch Dorian on under System Settings → Privacy & Security → Accessibility.
   Dorian is the only app that needs this; the Dock icons don't.
3. With Chrome running, Dorian lists your profiles. Pick the ones you want and click **Create Dock Icons**.
4. Drag the new `Chrome - <Profile>` apps from the Finder window that opens to your Dock.

Dorian ships no Google artwork: each Dock icon is drawn from the Chrome icon of your own Chrome install, with a
round overlay. Per profile, **Icon** chooses the overlay (a coloured letter, a picture you pick, or none) and the
background (Chrome's icon, or an image you pick). **Overlay…** sets the overlay's position and size for all icons.
Click **Update Dock Icons** to apply changes. Icons stay inside Apple's icon grid, so the Dock shows them full size.
(Dorian can't use Chrome's own profile pictures: macOS doesn't let other apps read Chrome's data.)

When you add, rename or remove profiles in Chrome,
open Dorian again and click **Update Dock Icons**: new profiles get an icon, and icons for profiles that no
longer exist are removed. Profiles you switch off stay off. Dorian only ever removes apps it created, and only
after it has read Chrome's Profiles menu, so nothing is removed while Chrome is closed. Two profiles whose names
differ only in `/` or `:` would share an app name; Dorian marks them and asks you to rename one in Chrome.

Dorian works with Chrome in any language: it recognises the Profiles menu by its layout, not its title.

## How it works

- A Dock icon is a tiny app that opens `dorian://switch?profile=<name>` and quits.
- Dorian starts (or launches Chrome first if needed), presses that profile in Chrome's Profiles menu, and quits
  again. Chrome then brings that profile's last active window to the front.
- Errors are shown in a dialog and written to `~/Library/Logs/Dorian.log`.

## Accessibility approval: two traps

- **Don't add Dorian with "+"** in the Accessibility list. That creates an entry by file path, but macOS checks
  Dorian by bundle ID, so the switch shows "on" and Dorian still isn't allowed. Use **Grant Access…** instead. If
  you already used "+": remove the entry with "–", quit and reopen System Settings, and click **Grant Access…**.
- **Rebuilding resets the approval** unless you sign with a certificate. Without one, `build.sh` signs ad-hoc, and
  macOS ties the approval to that exact build. Rebuilding without changes keeps it. After a change, `build.sh`
  clears the old approval and asks you to grant access again.

To keep the approval across rebuilds, sign with a certificate. With a free Apple ID in Xcode → Settings → Accounts
you get an "Apple Development" certificate, which `build.sh` finds on its own. Any other code-signing identity
works too: `SIGN_IDENTITY="My Cert" ./build.sh`.

## Options

| Variable | Default | Meaning |
| --- | --- | --- |
| `DORIAN_BUNDLE_ID` | `io.github.johanbellander.dorian` | Bundle ID of Dorian; Dock icons use `<id>.launcher.<profile>` |
| `SIGN_IDENTITY` | first "Apple Development" identity, else ad-hoc | Code-signing identity |
| `DEST` | `~/Applications` | Where `Dorian.app` is installed |

If a future Chrome version changes its Profiles menu so Dorian no longer finds it, you can name the menu yourself:
`defaults write io.github.johanbellander.dorian ProfilesMenuTitle "Profiles"`.

## App icon

The app icon lives in `Resources/AppIcon.svg` (a 1024 × 1024 canvas with the rounded square at Apple's 824 px grid, so
the Dock shows it full size). `build.sh` renders it into `AppIcon.icns`; edit the SVG and rebuild to change it.

## License

MIT

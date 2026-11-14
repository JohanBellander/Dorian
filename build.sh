#!/usr/bin/env bash
# Builds Dorian.app (Apple Silicon) and installs it to ~/Applications.
#
# Environment (all optional):
#   DORIAN_BUNDLE_ID  bundle ID (default io.github.johanbellander.dorian)
#   SIGN_IDENTITY     codesign identity; default: first "Apple Development"
#                     identity, else ad-hoc ("-")
#   DEST              install folder (default ~/Applications)
set -euo pipefail

cd "$(dirname "$0")"

VERSION="0.1.0"
BUNDLE_ID="${DORIAN_BUNDLE_ID:-io.github.johanbellander.dorian}"
DEST="${DEST:-$HOME/Applications}"
BUILD="build"
APP="$BUILD/Dorian.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DEST"

# Apple Silicon only: macOS warns that Intel code won't open after macOS 27.
compile() { # <output> <sources...>
  local out="$1"; shift
  swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$out" "$@"
}

echo "Compiling..."
compile "$APP/Contents/MacOS/Dorian" Sources/Dorian/*.swift
compile "$APP/Contents/Resources/launcher" Sources/Launcher/main.swift
compile "$BUILD/iconset" Sources/Tools/iconset.swift

# App icon from the SVG source, added before signing so the signature covers it.
"$BUILD/iconset" Resources/AppIcon.svg "$BUILD/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"

plist="$APP/Contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleExecutable -string Dorian "$plist"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
plutil -insert CFBundleName -string Dorian "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
plutil -insert CFBundleIconFile -string AppIcon "$plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$plist"
# Fixed build number: an unchanged rebuild then has the same signature, so an
# ad-hoc build keeps its Accessibility approval.
plutil -insert CFBundleVersion -string "$VERSION" "$plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$plist"
plutil -insert LSUIElement -bool true "$plist"
plutil -insert NSPrincipalClass -string NSApplication "$plist"
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"Dorian switch","CFBundleURLSchemes":["dorian"]}]' "$plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $([[ "$IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$IDENTITY")"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/launcher"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "codesign --verify: OK"

cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
installed="$DEST/Dorian.app"
old_hash=""
old_adhoc=0
if [[ -e "$installed" ]]; then
  old_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$installed/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$old_id" != "$BUNDLE_ID" ]]; then
    echo "ERROR: $installed exists but isn't this Dorian (bundle ID '${old_id:-none}')." >&2
    echo "Move it away or set DEST, then run build.sh again." >&2
    exit 1
  fi
  old_hash="$(cdhash "$installed")"
  codesign -dv "$installed" 2>&1 | grep -q '^Signature=adhoc' && old_adhoc=1
fi
new_hash="$(cdhash "$APP")"

rm -rf "$installed"
mv "$APP" "$DEST/"
"$LSREGISTER" -f "$installed"
echo "Installed $installed"

if [[ -n "$old_hash" && "$old_hash" != "$new_hash" && ( "$IDENTITY" == "-" || "$old_adhoc" == 1 ) ]]; then
  # An ad-hoc approval belongs to that exact build. Clear it, so System
  # Settings doesn't show a switch that is on but no longer applies. A
  # certificate-signed build keeps its approval across rebuilds.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo
  echo "Open Dorian and click \"Grant Access…\" to approve Accessibility."
  echo "(The signature changed, so any earlier approval was reset.)"
fi
if [[ "$old_hash" != "$new_hash" ]] && pgrep -qf "^$installed/Contents/MacOS/Dorian"; then
  echo
  echo "Dorian is running the previous build. Quit it (⌘Q) and open it again."
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo
  echo "Note: ad-hoc signature. Rebuilds that change the code need a new"
  echo "Accessibility approval. A signing certificate avoids that (see README)."
fi

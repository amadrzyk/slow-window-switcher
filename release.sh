#!/bin/bash
# Builds a universal, notarized SlowWindowSwitcher.app and publishes it as a GitHub release.
# The release version comes from CFBundleShortVersionString in Info.plist.
# Usage: NOTARY_PROFILE=<profile> ./release.sh
# Create the profile one time with: xcrun notarytool store-credentials <profile>
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alexander Madrzyk (66JVQA84J3)}"
PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
OUT=build/release
APP=$OUT/SlowWindowSwitcher.app
ZIP=$OUT/SlowWindowSwitcher-$VERSION.zip

# The release must match a commit on GitHub.
git diff --quiet HEAD || { echo "Commit your changes first."; exit 1; }

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos14" main.swift -o "$OUT/SlowWindowSwitcher-$arch"
done
lipo -create "$OUT/SlowWindowSwitcher-arm64" "$OUT/SlowWindowSwitcher-x86_64" -output "$APP/Contents/MacOS/SlowWindowSwitcher"
# Notarization needs the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
# Zip the app again, so the download includes the notarization ticket.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --verify-tag --title "v$VERSION" --generate-notes

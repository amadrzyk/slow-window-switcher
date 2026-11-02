#!/bin/bash
# Builds SlowWindowSwitcher.app, replaces the copy in /Applications, and restarts it.
# The build signs with a stable certificate, so the Screen Recording permission stays across builds.
# Set SIGN_IDENTITY to use a different code signing identity.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alexander Madrzyk (66JVQA84J3)}"
BUILD=build/SlowWindowSwitcher.app
APP=/Applications/SlowWindowSwitcher.app

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS"
cp Info.plist "$BUILD/Contents/"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" main.swift -o "$BUILD/Contents/MacOS/SlowWindowSwitcher"
# A local build does not need a timestamp from Apple's server.
codesign --force --timestamp=none --sign "$IDENTITY" "$BUILD"

pkill -x SlowWindowSwitcher || true
while pgrep -x SlowWindowSwitcher >/dev/null; do sleep 0.1; done
rm -rf "$APP"
mv "$BUILD" "$APP"
open "$APP"
echo "Installed $APP"

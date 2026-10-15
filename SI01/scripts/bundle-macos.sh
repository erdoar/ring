#!/bin/sh
# Run this on the Mac. It builds the binary and wraps it so the system will grant the input device.
# The app and its folder are both named "Ring <version>", from CFBundleShortVersionString.
set -e
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
NAME="Ring $VERSION"
OUT="build/$NAME"
APP="$OUT/$NAME.app"
swift build -c release --arch arm64
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SI01 "$APP/Contents/MacOS/SI01"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"

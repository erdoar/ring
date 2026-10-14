#!/bin/sh
# Run this on the Mac. It builds the binary and wraps it so the system will grant the input device.
set -e
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
mkdir -p SI-01.app/Contents/MacOS
cp .build/release/SI01 SI-01.app/Contents/MacOS/SI01
cp Support/Info.plist SI-01.app/Contents/Info.plist
codesign --force --sign - SI-01.app
echo "SI-01.app"

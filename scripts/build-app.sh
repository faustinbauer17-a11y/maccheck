#!/bin/bash
# Builds MacCheck.app on a Mac (Apple Silicon) — no Xcode project, no paid Developer account.
#
#   ./scripts/build-app.sh            # release build → dist/MacCheck.app (ad-hoc signed)
#   ./scripts/build-app.sh --zip      # also dist/MacCheck.zip for copying to another Mac
#
# Requirements: macOS 14+, Xcode or the Command Line Tools (Swift 5.9+).
# Ad-hoc signing ("-") gives the app a valid signature without a Developer ID. It is NOT notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2; exit 1
fi

swift build -c release --product MacCheck --arch arm64
BIN="$(swift build -c release --product MacCheck --arch arm64 --show-bin-path)/MacCheck"

APP="dist/MacCheck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacCheck"
cp packaging/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign with the hardened runtime. No entitlements are needed: MacCheck is read-only.
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
  (cd dist && ditto -c -k --keepParent MacCheck.app MacCheck.zip)
  echo "Zipped dist/MacCheck.zip"
fi

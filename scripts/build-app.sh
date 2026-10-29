#!/bin/bash
# Builds a universal "Next Departures.app" (Apple silicon and Intel) into ./build and signs it
# with the sandbox entitlements, plus the next-departures command line tool next to it.
#
#   scripts/build-app.sh            ad-hoc signature, for running on this Mac
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

identity="${SIGN_IDENTITY:--}"
app="build/Next Departures.app"

# Each architecture is built on its own and then combined, which works with just the
# Command Line Tools. Building both in one step needs Xcode.
binaries=()
tools=()
for arch in arm64 x86_64; do
	triple="$arch-apple-macosx14.0"
	swift build -c release --product NextDepartures --triple "$triple"
	swift build -c release --product next-departures --triple "$triple"
	bin="$(swift build -c release --triple "$triple" --show-bin-path)"
	binaries+=("$bin/NextDepartures")
	tools+=("$bin/next-departures")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/NextDepartures"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
	cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

# An ad-hoc signature's identity changes with every build, so macOS would treat each update as a
# different app reaching into the last one's sandbox data. Naming the bundle ID as the designated
# requirement keeps updates recognized as the same app. Next Departures asks macOS for no
# permissions, so there's nothing another program could borrow by claiming the same ID. A
# Developer ID signature has its own requirement.
requirement=()
if [[ "$identity" == "-" ]]; then
	requirement=(--requirements '=designated => identifier "com.stanczykwyatt.NextDepartures"')
fi

codesign --force --options runtime --timestamp=none \
	--entitlements Resources/NextDepartures.entitlements \
	${requirement[@]+"${requirement[@]}"} \
	--sign "$identity" "$app"
codesign --verify --strict "$app"

# The command line tool runs as you, in your terminal, so it isn't sandboxed. It uses the same
# fetcher as the app: https only, to the feed you name, and nowhere else.
lipo -create "${tools[@]}" -output build/next-departures
codesign --force --options runtime --timestamp=none --identifier com.stanczykwyatt.next-departures \
	--sign "$identity" build/next-departures
codesign --verify --strict build/next-departures

echo "Built $app and build/next-departures"

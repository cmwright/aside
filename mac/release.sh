#!/usr/bin/env bash
# Builds a Release Aside.app signed with Developer ID, notarizes it, staples the ticket,
# and zips it for distribution outside the App Store. Needs Signing.xcconfig filled in,
# a "Developer ID Application" certificate in the login keychain, and a notarytool
# keychain profile (see README "Signing and releasing").
set -euo pipefail
cd "$(dirname "$0")"

export DVT_PLUG_INS_TO_IGNORE="${DVT_PLUG_INS_TO_IGNORE:-com.apple.dt.IDESimulatorFoundation}"

if [ ! -f Signing.xcconfig ]; then
  echo "Signing.xcconfig is missing. Copy Signing.xcconfig.example and fill in DEVELOPMENT_TEAM." >&2
  exit 1
fi
value() { sed -n "s/^$1 *= *//p" Signing.xcconfig | tail -n 1; }
TEAM="$(value DEVELOPMENT_TEAM)"
PROFILE="$(value NOTARY_PROFILE)"
IDENTITY="$(value RELEASE_SIGN_IDENTITY)"
if [ -z "$TEAM" ]; then
  echo "DEVELOPMENT_TEAM is empty in Signing.xcconfig." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "No \"$IDENTITY\" certificate in the keychain. Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
fi

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
"$XCODEGEN" generate

DERIVED="$PWD/build"
xcodebuild \
  -project Aside.xcodeproj \
  -scheme Aside \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=YES \
  build

APP="$DERIVED/Build/Products/Release/Aside.app"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
ZIP="$DERIVED/Aside-$VERSION.zip"

echo "== Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" | grep -q audio-input || { echo "audio-input entitlement missing" >&2; exit 1; }

echo "== Notarizing (this waits for Apple, usually a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "== Stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== Gatekeeper check"
spctl -a -vv -t exec "$APP"

echo ""
echo "Release: $ZIP"

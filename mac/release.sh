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

echo "== Re-signing Sparkle's nested components with Developer ID"
# Xcode signs Sparkle.framework itself but leaves Updater.app, Autoupdate and the XPC
# services with Sparkle's signature, which notarization rejects. Sign innermost first,
# keeping Sparkle's own entitlements (the Downloader XPC is sandboxed on purpose).
SIGN_ID="$(security find-identity -v -p codesigning | sed -n "s/.*\"\($IDENTITY[^\"]*\)\".*/\1/p" | head -n 1)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for item in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE"; do
    [ -e "$item" ] || continue
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$SIGN_ID" "$item"
  done
  # The app's own seal covers the framework, so it must be re-signed last.
  codesign --force --options runtime --timestamp --entitlements Aside.entitlements --sign "$SIGN_ID" "$APP"
fi

echo "== Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
for item in "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/Autoupdate"; do
  # Capture first: with pipefail, `grep -q` closing the pipe early makes codesign fail.
  details="$(codesign -dvv "$item" 2>&1 || true)"
  case "$details" in
    *"Authority=Developer ID Application"*) ;;
    *) echo "$item is not Developer ID signed" >&2; exit 1 ;;
  esac
done
codesign -d --entitlements - "$APP" | grep -q audio-input || { echo "audio-input entitlement missing" >&2; exit 1; }

echo "== Notarizing (this waits for Apple, usually a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
NOTARY_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)"
SUBMISSION_ID="$(printf '%s' "$NOTARY_OUT" | sed -n 's/^ *id: //p' | head -n 1)"
if ! printf '%s' "$NOTARY_OUT" | grep -q "status: Accepted"; then
  echo "Notarization was not accepted. Details:" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

echo "== Stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== Gatekeeper check"
spctl -a -vv -t exec "$APP"

echo "== Appcast (Sparkle)"
# generate_appcast signs the zip with the EdDSA private key in this machine's keychain
# (created once with Sparkle's generate_keys; the public half is SUPublicEDKey in
# project.yml) and writes appcast.xml next to it. Only the current zip is kept in the
# folder: every entry gets the same download prefix, so an older zip would be listed
# under the wrong release tag, and deltas are off because the .delta files are never
# uploaded (Sparkle falls back to the full zip on a 404, but noisily).
RELEASES="$DERIVED/releases"
mkdir -p "$RELEASES"
rm -f "$RELEASES"/*.zip "$RELEASES"/*.delta "$RELEASES"/appcast.xml
cp "$ZIP" "$RELEASES/"
GENERATE_APPCAST="$(find "$DERIVED/SourcePackages/artifacts" -type f -name generate_appcast | head -n 1)"
"$GENERATE_APPCAST" \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/cmwright/aside/releases/download/v$VERSION/" \
  --link "https://github.com/cmwright/aside/releases" \
  "$RELEASES"

echo ""
echo "Release: $RELEASES/Aside-$VERSION.zip"
echo "Appcast: $RELEASES/appcast.xml"
echo "Publish with: ./publish.sh $VERSION"

#!/usr/bin/env bash
# Generates the iOS Xcode project and compiles both targets for a generic iOS device
# without signing: the quick verification that the app and the keyboard extension build.
#
# To actually put it on a phone, open ios/Aside.xcodeproj in Xcode, pick your iPhone and
# press Run — see README.md.
set -euo pipefail

cd "$(dirname "$0")"

# Same reason as mac/build.sh: this machine's /Library/Developer/PrivateFrameworks is
# older than Xcode 26.6, so xcodebuild refuses to start because it cannot dlopen the
# simulator plug-in. We only ever build for a device destination, so skip loading it.
export DVT_PLUG_INS_TO_IGNORE="${DVT_PLUG_INS_TO_IGNORE:-com.apple.dt.IDESimulatorFoundation}"

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
if [ ! -x "$XCODEGEN" ]; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [ ! -f Signing.xcconfig ]; then
  cp Signing.xcconfig.example Signing.xcconfig
  echo "Created Signing.xcconfig from the example. Put your DEVELOPMENT_TEAM in it before installing on a phone."
fi

"$XCODEGEN" generate

DERIVED="$PWD/build"

xcodebuild \
  -project Aside.xcodeproj \
  -scheme Aside \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/Aside.app"
EXT="$APP/PlugIns/AsideKeyboard.appex"
for path in "$APP" "$EXT"; do
  if [ ! -d "$path" ]; then
    echo "Build finished but $path is missing." >&2
    exit 1
  fi
done

echo ""
echo "Built: $APP"
echo "       $EXT"

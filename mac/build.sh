#!/usr/bin/env bash
# Generates the Xcode project and builds an ad-hoc-signed Debug Aside.app.
# Prints the path of the built .app on the last line.
set -euo pipefail

cd "$(dirname "$0")"

# This machine's /Library/Developer/PrivateFrameworks is older than Xcode 26.6, so
# xcodebuild refuses to start because the iOS-simulator plug-in cannot be dlopen'd.
# Aside is macOS-only and never needs that plug-in, so skip loading it. On a
# machine where `xcodebuild -runFirstLaunch` has been run this line changes nothing.
export DVT_PLUG_INS_TO_IGNORE="${DVT_PLUG_INS_TO_IGNORE:-com.apple.dt.IDESimulatorFoundation}"

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
if [ ! -x "$XCODEGEN" ]; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

"$XCODEGEN" generate

DERIVED="$PWD/build"

xcodebuild \
  -project Aside.xcodeproj \
  -scheme Aside \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED/Build/Products/Debug/Aside.app"
if [ ! -d "$APP" ]; then
  echo "Build finished but $APP is missing." >&2
  exit 1
fi

echo ""
echo "Built: $APP"

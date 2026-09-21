#!/usr/bin/env bash
# Local release verification; does not launch, install, publish or upload either app.
set -euo pipefail
cd "$(dirname "$0")/.."
export DVT_PLUG_INS_TO_IGNORE="${DVT_PLUG_INS_TO_IGNORE:-com.apple.dt.IDESimulatorFoundation}"

(
  cd mac
  if [ ! -f Signing.xcconfig ]; then cp Signing.xcconfig.example Signing.xcconfig; fi
  xcodegen generate
  xcodebuild -project Aside.xcodeproj -scheme Aside -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/verification \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
)
bash ios/build.sh
(
  cd worker
  npm test -- --no-cache
  npm run typecheck
)

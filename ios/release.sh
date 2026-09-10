#!/usr/bin/env bash
# Builds a Release archive of the iPhone app and uploads it to App Store Connect, where it
# appears under TestFlight after processing. Signing is automatic (Xcode's account and the
# team in Signing.xcconfig). The App Store Connect app record for
# com.codywright.aside.ios must already exist; bump MARKETING_VERSION and
# CURRENT_PROJECT_VERSION in project.yml first — App Store Connect rejects a build number
# it has already seen.
#
#   ./release.sh            # archive + upload
#   ./release.sh --no-upload  # archive only, to build/Aside.xcarchive
set -euo pipefail
cd "$(dirname "$0")"

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
"$XCODEGEN" generate >/dev/null

TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Signing.xcconfig | tr -d '[:space:]')"
if [ -z "$TEAM_ID" ]; then
  echo "DEVELOPMENT_TEAM is not set in Signing.xcconfig." >&2
  exit 1
fi

ARCHIVE="$PWD/build/Aside.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project Aside.xcodeproj -scheme Aside -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive | grep -E "error:|warning: .*(Privacy|Icon)|ARCHIVE" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed." >&2; exit 1; }

if [ "${1:-}" = "--no-upload" ]; then
  echo "Archive at $ARCHIVE"
  exit 0
fi

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

rm -rf build/export
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates | grep -E "error|EXPORT|Upload" || true
echo "Uploaded. It shows up in App Store Connect → TestFlight after processing (10–30 minutes)."

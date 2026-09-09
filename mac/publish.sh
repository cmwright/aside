#!/usr/bin/env bash
# Publishes a notarized build as a GitHub Release: the zip plus appcast.xml, which is
# what installed copies poll (SUFeedURL points at releases/latest/download/appcast.xml).
# The repository must be public for Sparkle to fetch those assets.
# Usage: ./publish.sh 0.2.0 ["release notes"]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?version, e.g. 0.2.0}"
NOTES="${2:-Aside $VERSION}"
RELEASES="$PWD/build/releases"
ZIP="$RELEASES/Aside-$VERSION.zip"
APPCAST="$RELEASES/appcast.xml"
[ -f "$ZIP" ] || { echo "Missing $ZIP. Run ./release.sh first." >&2; exit 1; }
[ -f "$APPCAST" ] || { echo "Missing $APPCAST. Run ./release.sh first." >&2; exit 1; }

# A stale GITHUB_TOKEN in the environment shadows the keyring login; use the keyring.
GH="env -u GITHUB_TOKEN gh"
if $GH release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION exists; replacing its assets."
  $GH release upload "v$VERSION" "$ZIP" "$APPCAST" --clobber
else
  $GH release create "v$VERSION" "$ZIP" "$APPCAST" --title "Aside $VERSION" --notes "$NOTES"
fi
echo "Published: $($GH release view "v$VERSION" --json url -q .url)"

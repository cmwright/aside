#!/usr/bin/env bash
# Builds, then launches the app. It lives in the menu bar; there is no Dock icon.
set -euo pipefail

cd "$(dirname "$0")"

APP="$(./build.sh | tail -n 1 | sed 's/^Built: //')"
if [ ! -d "$APP" ]; then
  echo "Could not find the built app." >&2
  exit 1
fi

pkill -f "VoiceToText.app/Contents/MacOS/VoiceToText" 2>/dev/null || true
open "$APP"
echo "Launched $APP — look for the microphone icon in the menu bar."

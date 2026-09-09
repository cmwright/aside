#!/usr/bin/env bash
# Smoke test for the voice-to-text Worker.
#
#   Terminal 1:  cd worker && npx wrangler dev
#   Terminal 2:  cd worker && ./scripts/smoke.sh
#
# It generates test/fixtures/hello.wav on first run (macOS `say` piped through
# `afconvert` into the 16 kHz mono 16-bit little-endian PCM WAV the contract
# asks for), checks GET /health, then POSTs the fixture to
# /v1/audio/transcriptions and prints the JSON response.
#
# Env:
#   BACKEND_URL    default http://localhost:8787
#   BACKEND_TOKEN  sent as `Authorization: Bearer ...` when set
#   CLEANUP        none | light | medium (default medium)
#   SAY_TEXT       what the fixture says (only used when generating it)

set -euo pipefail

BASE_URL="${BACKEND_URL:-http://localhost:8787}"
CLEANUP="${CLEANUP:-medium}"
SAY_TEXT="${SAY_TEXT:-Um, hello there, this is a test of hyper comply dictation, you know, and it should come out clean.}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker_dir="$(dirname "$script_dir")"
fixture="$worker_dir/test/fixtures/hello.wav"

# Dictionary in the exact shape the contract documents.
DICTIONARY='[{"term":"hyper comply","replacement":"HyperComply"},{"term":"Kubernetes"}]'

if [[ ! -f "$fixture" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "No fixture at $fixture and \`say\`/\`afconvert\` are macOS-only." >&2
    exit 1
  fi
  echo "Generating $fixture with say + afconvert..."
  mkdir -p "$(dirname "$fixture")"
  tmp_wav="$(mktemp -t voicetotext).wav"
  trap 'rm -f "$tmp_wav"' EXIT
  # `say` writes a 22.05 kHz 16-bit WAV (AIFF would need big-endian samples);
  # afconvert then resamples it to the 16 kHz mono LEI16 WAV the contract asks for.
  say -o "$tmp_wav" --file-format=WAVE --data-format=LEI16@22050 "$SAY_TEXT"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp_wav" "$fixture"
fi

echo "Fixture: $fixture ($(wc -c < "$fixture" | tr -d ' ') bytes)"
afinfo "$fixture" 2>/dev/null | grep -i 'Data format' || true
echo

auth_args=()
if [[ -n "${BACKEND_TOKEN:-}" ]]; then
  auth_args=(-H "Authorization: Bearer ${BACKEND_TOKEN}")
fi

pretty() {
  if command -v jq >/dev/null 2>&1; then jq .; else cat; fi
}

echo "GET $BASE_URL/health"
if ! curl -fsS --max-time 10 ${auth_args[@]+"${auth_args[@]}"} "$BASE_URL/health" | pretty; then
  echo "Could not reach $BASE_URL/health - is \`npx wrangler dev\` running?" >&2
  exit 1
fi
echo

echo "POST $BASE_URL/v1/audio/transcriptions (cleanup=$CLEANUP)"
http_status=$(
  curl -sS --max-time 60 -o /tmp/voicetotext-smoke.json -w '%{http_code}' \
    -X POST ${auth_args[@]+"${auth_args[@]}"} \
    -F "file=@${fixture};type=audio/wav;filename=audio.wav" \
    -F "model=default" \
    -F "dictionary=${DICTIONARY}" \
    -F "cleanup=${CLEANUP}" \
    -F "app_name=smoke.sh" \
    "$BASE_URL/v1/audio/transcriptions"
)
echo "HTTP $http_status"
pretty < /tmp/voicetotext-smoke.json
rm -f /tmp/voicetotext-smoke.json
echo

[[ "$http_status" == "200" ]] || exit 1

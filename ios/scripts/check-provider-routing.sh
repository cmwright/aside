#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/aside-provider-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
sources=(Settings CleanupLevel Trigger History Providers DirectClient Dictionary DictionaryReplacer CleanupPrompt AppleCleanup Log PCMCapture)
inputs=(ios/Pipeline/DictationPipeline.swift ios/scripts/check-provider-routing.swift)
for source in "${sources[@]}"; do inputs+=("mac/Sources/$source.swift"); done
xcrun swiftc -parse-as-library -swift-version 6 "${inputs[@]}" -o "$check_dir/check"
"$check_dir/check"

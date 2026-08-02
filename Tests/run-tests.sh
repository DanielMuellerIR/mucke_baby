#!/usr/bin/env bash
# Tests/run-tests.sh — kompiliert den Headless-Test-Harness und fuehrt ihn aus.
#
# Der Harness testet reinen Foundation-Code (URL-Policy, Playlist-Resolver,
# Recorder-Loeschgrenzen, Preview-Koordinator) — ohne VLCKit, SwiftUI oder
# Netzverbindungen nach aussen (HTTP-Fixtures laufen auf 127.0.0.1). Er laeuft
# damit auch in CI-/Agent-Umgebungen ohne App-Build und ohne Vendor-Cache.
# Exit-Code 0 = alle Pruefungen gruen.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="build/tests"
mkdir -p "$BUILD"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.2"   # gleicher Zielwert wie build.sh

# Nur die Quelldateien, die der Harness wirklich braucht (kein VLCKit-Import):
# Safety/PlaylistResolver sind die Pruefobjekte, Recorder + Models/SongHistory
# liefern Recorder samt seiner Hilfssymbole (migrateLegacyAppDir, JSONDecoder.iso).
swiftc -parse-as-library \
  -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift \
  Sources/PlaylistResolver.swift \
  Sources/Recorder.swift \
  Sources/Models.swift \
  Sources/SongHistory.swift \
  Tests/ReviewHarness.swift \
  -o "$BUILD/review-harness"

"$BUILD/review-harness"

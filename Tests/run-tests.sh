#!/usr/bin/env bash
# Tests/run-tests.sh — kompiliert den Headless-Test-Harness und fuehrt ihn aus.
#
# Der Harness testet reinen Foundation-Code (URL-Policy, Playlist-Resolver,
# Recorder-Loeschgrenzen, Preview-Koordinator) sowie den Store — ohne App-Start,
# VLCKit oder Netzverbindungen nach aussen (HTTP-Fixtures: 127.0.0.1). Der Store
# nutzt SwiftUI nur fuer ObservableObject; es wird keine GUI gestartet. Er laeuft
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
  Sources/RecordingState.swift Sources/Recorder.swift \
  Sources/Models.swift \
  Sources/SongHistory.swift \
  Sources/HistoryFilter.swift \
  Tests/ReviewHarness.swift \
  -o "$BUILD/review-harness"

"$BUILD/review-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/StationSelection.swift Sources/Store.swift Sources/RadioBrowser.swift Sources/StationRepair.swift \
  Tests/StoreHarness.swift -o "$BUILD/store-harness"
"$BUILD/store-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/StationSelection.swift Sources/Store.swift Sources/RadioBrowser.swift Sources/StationRepair.swift \
  Tests/StationSelectionHarness.swift -o "$BUILD/station-selection-harness"
"$BUILD/station-selection-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/StartupSettings.swift \
  Tests/StartupHarness.swift -o "$BUILD/startup-harness"
"$BUILD/startup-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" Sources/MiniWindowPlacement.swift Tests/MiniWindowHarness.swift \
  -o "$BUILD/mini-window-harness"
"$BUILD/mini-window-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Models.swift Sources/SongHistory.swift Sources/HistoryFilter.swift \
  Sources/RecordingState.swift Sources/Recorder.swift Sources/BookmarkStore.swift Tests/BookmarkHarness.swift \
  -o "$BUILD/bookmark-harness"
MUCKE_BOOKMARK_EXPORT_FIXTURE="$BUILD/bookmarks.csv" "$BUILD/bookmark-harness"
python3 - <<'PY'
import csv
from pathlib import Path
with Path('build/tests/bookmarks.csv').open(encoding='utf-8', newline='') as file:
    rows = list(csv.DictReader(file))
assert len(rows) == 1
assert rows[0]['artist'] == 'Björk'
assert rows[0]['title'] == "'@Formula"
assert rows[0]['original'] == '東京, "Live"\r\nGrüße'
assert rows[0]['station'] == "' =HYPERLINK(\"bad\")"
assert rows[0]['heard_at'] == rows[0]['saved_at']
print('Bookmark CSV: unabhängiger UTF-8-/CSV-Roundtrip OK')
PY
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/ICYMetadataReader.swift Sources/RecordingState.swift Sources/Recorder.swift Sources/Models.swift \
  Sources/SongHistory.swift Tests/ICYHarness.swift -o "$BUILD/icy-harness"
"$BUILD/icy-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/ExportRange.swift Sources/SongExporter.swift Sources/ICYMetadataReader.swift Sources/RecordingState.swift Sources/Recorder.swift \
  Sources/Models.swift Sources/SongHistory.swift Tests/ExportHarness.swift \
  -o "$BUILD/export-harness"
"$BUILD/export-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/ExportRange.swift Tests/ExportRangeHarness.swift -o "$BUILD/export-range-harness"
"$BUILD/export-range-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/ExportRange.swift Sources/SongExporter.swift Sources/ExportEditorModel.swift \
  Tests/ExportEditorHarness.swift -o "$BUILD/export-editor-harness"
"$BUILD/export-editor-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/RecordingState.swift Sources/Recorder.swift Sources/Models.swift Sources/SongHistory.swift \
  Sources/ICYMetadataReader.swift Tests/CaptureHarness.swift -o "$BUILD/capture-harness"
"$BUILD/capture-harness"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/RecordingState.swift Sources/Recorder.swift Sources/Models.swift Sources/SongHistory.swift \
  Tests/RecordingLibraryHarness.swift -o "$BUILD/recording-library-harness"
"$BUILD/recording-library-harness"
bash Tests/fleet-rules.sh

swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/PlaybackReconnect.swift Tests/ReconnectClock.swift Tests/ReconnectHarness.swift \
  -o "$BUILD/reconnect-harness"
"$BUILD/reconnect-harness"

swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/RadioBrowser.swift Sources/StationRepair.swift Sources/CatalogCache.swift \
  Tests/CatalogHarness.swift -o "$BUILD/catalog-harness"
"$BUILD/catalog-harness"

swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/SongHistory.swift Sources/SystemMedia.swift \
  Tests/SystemMediaHarness.swift -o "$BUILD/system-media-harness"
"$BUILD/system-media-harness"

python3 Tests/player-events.py
python3 Tests/player-rollover.py
python3 Tests/recording-preview.py

cat Sources/AudioTap.swift Tests/AudioTapHarness.swift > "$BUILD/AudioTapCombined.swift"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" "$BUILD/AudioTapCombined.swift" \
  -o "$BUILD/audio-tap-harness"
"$BUILD/audio-tap-harness"
python3 Tests/release-mount.py
python3 Tests/release-publish.py

swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  Sources/Safety.swift Sources/Models.swift Sources/StationSelection.swift Sources/Store.swift \
  Sources/RadioBrowser.swift Sources/StationRepair.swift Sources/StationHealth.swift Sources/PlaylistResolver.swift \
  Tests/StationRepairHarness.swift -o "$BUILD/station-repair-harness"
"$BUILD/station-repair-harness"

#!/usr/bin/env bash
# Kompiliert und startet die macOS-Harnesses ohne App-Start und ohne Vendor-Cache.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="build/tests"
mkdir -p "$BUILD"
compiler=(swiftc -parse-as-library -target arm64-apple-macos14.2 -sdk "$(xcrun --show-sdk-path)"
          -module-cache-path "$BUILD/module-cache")

run_harness() {
    local name=$1
    shift
    "${compiler[@]}" "$@" -o "$BUILD/$name"
    "$BUILD/$name"
}

history_sources=(Sources/Models.swift Sources/SongRecognition.swift Sources/SongHistory.swift)
recorder_sources=(Sources/RecordingState.swift Sources/Recorder.swift)
export_sources=(Sources/ExportRange.swift Sources/ExportMetadata.swift Sources/SongExporter.swift)
recognition_sources=(Sources/SongRecognition.swift Sources/RecognitionModels.swift Sources/RecognitionCapture.swift)
recognition_service_sources=(
  "${recognition_sources[@]}" Sources/MusicRecognitionService.swift Sources/ShazamRecognitionClient.swift
)
exchange_sources=(
  "${history_sources[@]}" Sources/Safety.swift Sources/StationSelection.swift Sources/HistoryFilter.swift
  Sources/BookmarkStore.swift Sources/ExchangeCodec.swift Sources/ExchangeTransaction.swift Sources/LibraryExchangeStorage.swift
)
store_sources=("${exchange_sources[@]}" Sources/Store.swift Sources/RadioBrowser.swift Sources/StationRepair.swift)

run_harness review-harness Sources/Safety.swift Sources/PlaylistResolver.swift "${recorder_sources[@]}" \
  "${history_sources[@]}" Sources/HistoryFilter.swift Tests/ReviewHarness.swift
run_harness store-harness "${store_sources[@]}" Tests/StoreHarness.swift
run_harness station-selection-harness "${store_sources[@]}" Tests/StationSelectionHarness.swift
run_harness startup-harness Sources/Safety.swift Sources/Models.swift Sources/StartupSettings.swift \
  Tests/StartupHarness.swift
run_harness mini-window-harness Sources/MiniWindowPlacement.swift Tests/MiniWindowHarness.swift
MUCKE_BOOKMARK_EXPORT_FIXTURE="$BUILD/bookmarks.csv" run_harness bookmark-harness \
  "${exchange_sources[@]}" "${recorder_sources[@]}" Tests/BookmarkHarness.swift
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
run_harness icy-harness Sources/ICYMetadataReader.swift "${recorder_sources[@]}" "${history_sources[@]}" \
  Tests/ICYHarness.swift
run_harness timeshift-harness Sources/TimeshiftBuffer.swift Tests/TimeshiftHarness.swift
run_harness timeshift-segments-harness Sources/MetadataTimeline.swift Sources/TimeshiftBuffer.swift \
  Sources/TimeshiftSegments.swift Sources/RecordingState.swift Sources/TimeshiftCapture.swift \
  Tests/TimeshiftSegmentsHarness.swift
run_harness export-harness "${export_sources[@]}" Sources/ICYMetadataReader.swift \
  "${recorder_sources[@]}" "${history_sources[@]}" Tests/ExportHarness.swift
run_harness export-range-harness Sources/ExportRange.swift Tests/ExportRangeHarness.swift
run_harness export-editor-harness Sources/Safety.swift "${export_sources[@]}" \
  Sources/ExportEditorModel.swift Tests/ExportEditorHarness.swift
run_harness capture-harness "${recorder_sources[@]}" "${history_sources[@]}" \
  Sources/ICYMetadataReader.swift Tests/CaptureHarness.swift
run_harness recording-library-harness "${recorder_sources[@]}" "${history_sources[@]}" \
  Tests/RecordingLibraryHarness.swift
bash Tests/fleet-rules.sh

run_harness reconnect-harness Sources/PlaybackReconnect.swift Tests/ReconnectClock.swift \
  Tests/ReconnectHarness.swift

run_harness catalog-harness Sources/Safety.swift Sources/Models.swift Sources/RadioBrowser.swift \
  Sources/StationRepair.swift Sources/CatalogCache.swift Tests/CatalogHarness.swift

run_harness system-media-harness Sources/Safety.swift "${history_sources[@]}" Sources/SystemMedia.swift \
  Tests/SystemMediaHarness.swift

run_harness audio-settings-harness Sources/AudioSettings.swift Tests/AudioSettingsHarness.swift

bash Tests/run-player-tests.sh

run_harness audio-tap-harness "${recognition_sources[@]}" -D AUDIO_TAP_HARNESS Sources/AudioTap.swift \
  Tests/AudioTapHarness.swift
python3 Tests/release-mount.py
python3 Tests/release-publish.py

run_harness station-repair-harness "${store_sources[@]}" Sources/StationHealth.swift \
  Sources/PlaylistResolver.swift Sources/ExchangeMerge.swift Sources/LibraryExchange.swift \
  Tests/StationRepairHarness.swift

run_harness exchange-codec-harness "${exchange_sources[@]}" Sources/ExchangeMerge.swift \
  Tests/ExchangeCodecHarness.swift
run_harness exchange-transaction-harness Sources/ExchangeTransaction.swift \
  Tests/ExchangeTransactionHarness.swift

run_harness library-exchange-harness "${store_sources[@]}" Sources/ExchangeMerge.swift \
  Sources/LibraryExchange.swift Tests/LibraryExchangeHarness.swift

run_harness fixture-tone-harness Tests/FixtureTone.swift Tests/FixtureToneHarness.swift

run_harness radio-commands-harness Sources/Safety.swift "${history_sources[@]}" "${recorder_sources[@]}" \
  Sources/HistoryFilter.swift Sources/RadioCommands.swift Tests/RadioCommandsHarness.swift

run_harness export-queue-harness "${export_sources[@]}" Sources/ExportQueue.swift \
  Tests/ExportQueueHarness.swift

run_harness song-drag-harness Sources/ExportMetadata.swift Sources/SongDragProvider.swift \
  Tests/SongDragHarness.swift

run_harness recognition-harness "${recognition_service_sources[@]}" Tests/RecognitionHarness.swift

run_harness recognition-sdk-harness "${recognition_service_sources[@]}" Tests/RecognitionSDKHarness.swift

MUCKE_RECOGNITION_EXPORT_FIXTURE="$BUILD/recognition-bookmarks.csv" run_harness recognition-bookmark-harness \
  Sources/Safety.swift "${history_sources[@]}" Sources/StationSelection.swift \
  Sources/RecognitionModels.swift Sources/RecognitionSong.swift Sources/BookmarkStore.swift \
  Sources/ExchangeCodec.swift Sources/ExchangeMerge.swift Sources/ExchangeTransaction.swift \
  Sources/LibraryExchangeStorage.swift Tests/RecognitionBookmarkHarness.swift
python3 - <<'CHECK_CSV'
import csv
from pathlib import Path
with Path('build/tests/recognition-bookmarks.csv').open(encoding='utf-8', newline='') as file:
    rows = list(csv.DictReader(file))
assert len(rows) == 3
assert rows[0]['source'] == '' and rows[0]['original'] == 'Björk - Grüße'
assert rows[1]['source'] == 'shazam' and rows[1]['artist'] == 'Björk' and rows[1]['title'] == 'Grüße'
assert rows[1]['original'] == rows[1]['original_icy'] == 'DJ - Grüße (Rare Live Remix)'
assert rows[1]['station'] == 'Eigener Sender — 東京' and rows[1]['shazam_id'] == '123'
assert rows[1]['apple_music_url'] == 'https://music.apple.com/de/song/123'
assert rows[1]['recognized_at'] and rows[1]['station_id']
assert rows[0]['output_id'] == rows[1]['output_id'] == ''
assert rows[2]['output_id'] and rows[2]['output_revision'] == '42'
assert rows[2]['buffer_position'] == '12.345'
assert rows[2]['audio_received_at'] < rows[2]['heard_at'] < rows[2]['recognized_at']
print('Erkennung CSV: unabhängiger Unicode-/Herkunfts-Roundtrip OK')
CHECK_CSV

run_harness sleep-timer-harness Sources/SleepTimer.swift Sources/SleepTimerController.swift \
  Tests/SleepTimerHarness.swift

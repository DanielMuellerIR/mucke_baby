#!/usr/bin/env bash
# Die Harnesses kompilieren unveränderte Player-Quellen gegen ein lokales VLC-Modul.
set -euo pipefail
cd "$(dirname "$0")/.."

build=build/tests
mkdir -p "$build"
compiler=(swiftc -parse-as-library -target arm64-apple-macos14.2 -sdk "$(xcrun --show-sdk-path)"
          -module-cache-path "$build/module-cache")

"${compiler[@]}" -module-name VLCKit -emit-module -emit-library -static \
  Tests/VLCKitDouble.swift -emit-module-path "$build/VLCKit.swiftmodule" -o "$build/libVLCKit.a"

run_harness() {
    local name=$1
    shift
    "${compiler[@]}" -I "$build" -L "$build" -lVLCKit \
      Sources/PlayerDelegateShim.swift "$@" -o "$build/$name"
    "$build/$name"
}

player_sources=(
  Sources/RadioPlayer.swift Sources/MetadataTimeline.swift Sources/TimeshiftBuffer.swift
  Sources/TimeshiftSegments.swift Sources/TimeshiftCapture.swift
  Sources/SongRecognition.swift Sources/RecognitionModels.swift Sources/AudioSettings.swift
  Sources/SleepTimer.swift Sources/SleepTimerController.swift Sources/Safety.swift
  Sources/PlaybackReconnect.swift Sources/PlaybackObservations.swift Sources/RecordingState.swift
)

run_harness player-harness "${player_sources[@]}" Sources/PreviewPlayer.swift \
  Tests/PlayerFixture.swift Tests/PlayerHarness.swift Tests/ReconnectClock.swift
run_harness recording-preview-harness Sources/RecordingPreview.swift Tests/RecordingPreviewHarness.swift
run_harness timeshift-player-harness "${player_sources[@]}" Tests/PlayerFixture.swift Tests/TimeshiftPlayerHarness.swift
run_harness player-rollover-harness "${player_sources[@]}" Sources/Models.swift Sources/SongHistory.swift \
  Sources/Recorder.swift Sources/ICYMetadataReader.swift Tests/PlayerRolloverHarness.swift
"$build/player-rollover-harness" --title-first

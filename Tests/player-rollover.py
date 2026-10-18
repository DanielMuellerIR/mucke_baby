#!/usr/bin/env python3
"""Rollover mit echten ICY-/Recorder-/Verlaufsklassen und kontrollierter Titelqueue."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / 'build/tests'
build.mkdir(parents=True, exist_ok=True)
def replace_once(source, old, new):
    assert source.count(old) == 1, f'Fixture-Injektion nicht eindeutig: {old}'
    return source.replace(old, new)


radio = replace_once((root / 'Sources/RadioPlayer.swift').read_text(), 'import VLCKit\n', '')
# Ausschließlich persistente Pfade und die Queue der Netzwerkfixture injizieren.
radio = replace_once(radio, 'self.history = history ?? SongHistory()', 'self.history = history ?? SongHistory(directory: RolloverFixture.root.appendingPathComponent("history"))')
radio = replace_once(radio, 'private let icy = ICYMetadataReader()', 'private let icy = ICYMetadataReader(configuration: RolloverFixture.configuration, titleQueue: RolloverFixture.titles)')
fixture = (root / 'Tests/PlayerFixture.swift').read_text()
vlc = fixture[:fixture.index('struct Station')]
source = build / 'PlayerRolloverCombined.swift'
source.write_text(vlc + '\n' + radio + '\n' + (root / 'Tests/PlayerRolloverHarness.swift').read_text())
recorder = build / 'RecorderRollover.swift'
recorder.write_text(replace_once((root / 'Sources/Recorder.swift').read_text(),
    'DispatchQueue.main.async { self.onCaptureState?(state) }',
    'RolloverFixture.states.async { self.onCaptureState?(state) }'))
subprocess.run(['swiftc', '-parse-as-library', *[str(root / 'Sources' / (name + '.swift')) for name in ['TimeshiftBuffer', 'TimeshiftSegments', 'TimeshiftCapture']], *[str(root / p) for p in [
    'Sources/SongRecognition.swift', 'Sources/RecognitionModels.swift', 'Sources/AudioSettings.swift', 'Sources/Safety.swift', 'Sources/Models.swift', 'Sources/PlaybackReconnect.swift',
    'Sources/RecordingState.swift', 'Sources/SongHistory.swift', 'Sources/SleepTimer.swift', 'Sources/SleepTimerController.swift',
    'Sources/ICYMetadataReader.swift']], str(recorder), str(source), '-o', str(build / 'player-rollover-harness')], check=True)
subprocess.run([str(build / 'player-rollover-harness')], check=True)
subprocess.run([str(build / 'player-rollover-harness'), '--title-first'], check=True)

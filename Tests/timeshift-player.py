#!/usr/bin/env python3
"""Produkt-Transport mit steuerbaren VLC-Ereignissen und echtem Segmentpuffer."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
build = root / 'build/tests'
build.mkdir(parents=True, exist_ok=True)
fixture = (root / 'Tests/PlayerFixture.swift').read_text().split('@main\nstruct PlayerHarness')[0]
radio = (root / 'Sources/RadioPlayer.swift').read_text().replace('import VLCKit\n', '').replace('DispatchQueue.main.async', 'TestEvents.enqueue')
combined = build / 'TimeshiftPlayerCombined.swift'
combined.write_text(fixture + radio + (root / 'Tests/TimeshiftPlayerHarness.swift').read_text())
names = ['MetadataTimeline', 'TimeshiftBuffer', 'TimeshiftSegments', 'TimeshiftCapture', 'SongRecognition', 'RecognitionModels', 'AudioSettings', 'SleepTimer', 'SleepTimerController', 'Safety', 'PlaybackReconnect', 'RecordingState']
subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(build / 'module-cache'), *[str(root / 'Sources' / (n + '.swift')) for n in names], str(combined), '-o', str(build / 'timeshift-player-harness')], check=True)
subprocess.run([str(build / 'timeshift-player-harness')], check=True, timeout=30)

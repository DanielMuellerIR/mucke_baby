#!/usr/bin/env python3
"""Produktklassen mit VLC-/Dateisystem-Doubles headless auf Ereignisreihenfolge pruefen."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / 'build/tests'
build.mkdir(parents=True, exist_ok=True)
radio = (root / 'Sources/RadioPlayer.swift').read_text().replace('import VLCKit\n', '')
# Steuerbare Ereigniszustellung ist die einzige Ersetzung innerhalb der Klasse.
radio = radio.replace('DispatchQueue.main.async', 'TestEvents.enqueue')
browser = (root / 'Sources/StationBrowser.swift').read_text()
preview = browser[browser.index('@MainActor\nfinal class PreviewPlayer'):browser.index('// MARK: - Katalog-Sheet')]
fixture = (root / 'Tests/PlayerFixture.swift').read_text()
source = build / 'PlayerFixtureCombined.swift'
source.write_text(fixture + '\n' + radio + '\n' + preview)
subprocess.run(['swiftc', '-parse-as-library', str(root / 'Sources/Safety.swift'), str(source),
                '-o', str(build / 'player-harness')], check=True)
subprocess.run([str(build / 'player-harness')], check=True)

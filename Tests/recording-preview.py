#!/usr/bin/env python3
"""Lokale VLC-Vorschau mit echten Delegate-/Generationspfaden und VLC-Double."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / 'build/tests'
fixture = (root / 'Tests/PlayerFixture.swift').read_text()
vlc = fixture[:fixture.index('struct Station')]
radio = (root / 'Sources/RadioPlayer.swift').read_text()
shim = radio[radio.index('final class PlayerDelegateShim'):radio.index('// Kapselt VLCMediaPlayer')]
source = build / 'RecordingPreviewCombined.swift'
source.write_text(vlc + '\n' + shim + '\n' +
    (root / 'Sources/RecordingPreview.swift').read_text().replace('import VLCKit\n', '') + '''
@main struct RecordingPreviewHarness {
    @MainActor static func main() async {
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let preview = RecordingPreview(), a = UUID(), b = UUID()
        let file = URL(fileURLWithPath: "/fixture/recording.ogg")
        preview.play(id: a, url: file, volume: 0.2)
        let first = VLCMediaPlayer.latest!
        let oldDelegate = first.delegate!
        check(preview.currentID == a && preview.isLoading && first.audio?.volume == 20, "Lokale Vorschau startet nicht")
        first.timeEvent()
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(!preview.isLoading, "Erstes Zeitereignis beendet Laden nicht")
        preview.play(id: b, url: file, volume: 0.8)
        check(preview.currentID == b && VLCMediaPlayer.latest !== first, "Wechsel ersetzt VLC-Instanz nicht")
        first.state = .error
        oldDelegate.mediaPlayerStateChanged(Notification(name: Notification.Name("old"), object: first))
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(preview.currentID == b && preview.error == nil, "Alter Fehler beendet neue Vorschau")
        let second = VLCMediaPlayer.latest!
        second.state = .ended; second.stateEvent()
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(preview.currentID == nil && !preview.isLoading, "Dateiende bleibt aktiv")
        preview.play(id: a, url: file, volume: 1)
        let active = VLCMediaPlayer.latest!
        active.state = .error; active.stateEvent()
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(preview.currentID == nil && preview.error != nil, "Lesefehler bleibt unsichtbar")
        preview.play(id: b, url: file, volume: 0)
        preview.stop()
        check(preview.currentID == nil && !preview.isLoading && VLCMediaPlayer.latest?.delegate == nil, "Stop bereinigt Vorschau nicht")
        preview.play(id: a, url: URL(string: "https://fixture.invalid/stream")!, volume: 1)
        check(preview.currentID == nil, "Lokale Vorschau öffnet Netzwerkadresse")
        print("RecordingPreviewHarness: Start, Wechsel, alte Ereignisse, Dateiende, Fehler und Stop OK")
    }
}
''')
subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(build / 'recording-preview-harness')], check=True)
subprocess.run([str(build / 'recording-preview-harness')], check=True)

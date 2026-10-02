// Wird mit AudioTap.swift in einer Datei kompiliert: private Analysepfade
// bekommen synthetische Samples, ohne CoreAudio-Gerät oder Berechtigungsdialog.
import Foundation

extension AudioTap {
    fileprivate func simulateRunningTap() { isActive = true }
    fileprivate func receiveFixture(_ samples: [Float]) { feedMono(samples) }
}

@main
enum AudioTapHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }

    static func main() {
        let tap = AudioTap()
        tap.simulateRunningTap()
        check(!tap.reactive && tap.level == 0, "Tap meldet vor ersten Samples ein Signal")
        let tone = (0..<2048).map { Float(sin(Double($0) * 0.1) * 0.2) }
        tap.receiveFixture(tone)
        check(tap.reactive && tap.level > 0 && tap.waveform.contains { $0 != 0 }, "Tonfixture blieb still")
        tap.stop()
        check(!tap.reactive && tap.level == 0 && tap.bands.allSatisfy { $0 == 0 }
              && tap.waveform.allSatisfy { $0 == 0 }, "Stop behält Analyse des alten Senders")
        tap.simulateRunningTap()
        check(!tap.reactive, "Neuer Sender startet mit altem Signal")
        tap.receiveFixture([Float](repeating: 0, count: 32))
        check(!tap.reactive && tap.waveform.allSatisfy { $0 == 0 }, "Stille übernimmt alten Ringpuffer")
        tap.setOutputVolume(0.25)
        tap.receiveFixture(tone.map { $0 * 0.25 })
        let quiet = tap.level
        tap.stop(); tap.simulateRunningTap(); tap.setOutputVolume(1)
        tap.receiveFixture(tone)
        check(abs(tap.level - quiet) < 0.001, "App-Lautstärke verändert normalisierte Analyse")
        tap.stop(); tap.simulateRunningTap(); tap.setOutputVolume(0)
        tap.receiveFixture([Float](repeating: 0, count: 2048))
        check(!tap.reactive && tap.level == 0, "Stummgeschalteter Tap erfindet Signal")
        tap.stop()
        print("AudioTapHarness: OK")
    }
}

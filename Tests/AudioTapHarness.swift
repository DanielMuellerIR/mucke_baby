// Wird mit AudioTap.swift in einer Datei kompiliert: private Analysepfade
// bekommen synthetische Samples, ohne CoreAudio-Gerät oder Berechtigungsdialog.
import Foundation

extension AudioTap {
    fileprivate func simulateRunningTap() { isActive = true; tapSampleRate = 16_000; _captureRate = 16_000 }
    fileprivate func receiveFixture(_ samples: [Float]) { feedMono(samples) }
    fileprivate func receivePCMFixture(_ samples: [Float]) {
        tapChannels = 2; tapInterleaved = true
        samples.withUnsafeBufferPointer { source in
            var buffers = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                                      mData: UnsafeMutableRawPointer(mutating: source.baseAddress!)))
            withUnsafePointer(to: &buffers) { handleTapInput($0) }
        }
    }
}

@main
enum AudioTapHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }

    static func main() throws {
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
        tap.simulateRunningTap(); tap.setOutputVolume(0.1)
        let token = try tap.recognitionCapture.begin(sampleRate: 16_000)
        let stereo = (0..<48_000).flatMap { _ in [Float(0.025), Float(0.075)] }
        tap.receivePCMFixture(stereo)
        let captured = try tap.recognitionCapture.finish(token)
        check(captured.samples.count == 48_000 && captured.samples.allSatisfy { abs($0 - 0.05) < 0.000001 },
              "Erkennung bekommt normalisierte Visualizerwerte statt tatsächlich ausgegebener PCM-Samples")
        check(tap.waveform.contains { $0 > 0.4 }, "Fixture belegt nicht den Unterschied zur Visualizer-Normalisierung")
        let interrupted = try tap.recognitionCapture.begin(sampleRate: 16_000)
        tap.stop()
        do { _ = try tap.recognitionCapture.finish(interrupted); fatalError("Stop lässt PCM-Sammlung weiterlaufen") }
        catch { check(error as? RecognitionFailure == .audioChanged, "Falscher Unterbrechungsgrund") }
        check(tap.captureSampleRate == nil, "Stop meldet weiterhin Audiozugriff")
        print("AudioTapHarness: OK")
    }
}

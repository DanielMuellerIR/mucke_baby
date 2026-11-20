import CoreAudio
import Foundation

private func sendStereoFixture(_ samples: [Float], to tap: AudioTap) {
    samples.withUnsafeBufferPointer { source in
        var buffers = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(source.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: source.baseAddress)
            )
        )
        withUnsafePointer(to: &buffers) { tap.receivePCMFixture($0) }
    }
}

@main
enum AudioTapHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }

    static func main() throws {
        let sampleRate = 16_000.0
        let tap = AudioTap()
        tap.simulateRunningTap(sampleRate: sampleRate)
        check(!tap.reactive && tap.level == 0, "Tap meldet vor ersten Samples ein Signal")
        let tone = (0..<2048).map { Float(sin(Double($0) * 0.1) * 0.2) }
        tap.receiveMonoFixture(tone)
        check(tap.reactive && tap.level > 0 && tap.waveform.contains { $0 != 0 }, "Tonfixture blieb still")
        tap.stop()
        check(!tap.reactive && tap.level == 0 && tap.bands.allSatisfy { $0 == 0 }
              && tap.waveform.allSatisfy { $0 == 0 }, "Stop behält Analyse des alten Senders")
        tap.simulateRunningTap(sampleRate: sampleRate)
        check(!tap.reactive, "Neuer Sender startet mit altem Signal")
        tap.receiveMonoFixture([Float](repeating: 0, count: 32))
        check(!tap.reactive && tap.waveform.allSatisfy { $0 == 0 }, "Stille übernimmt alten Ringpuffer")
        tap.setOutputVolume(0.25)
        tap.receiveMonoFixture(tone.map { $0 * 0.25 })
        let quiet = tap.level
        tap.stop(); tap.simulateRunningTap(sampleRate: sampleRate); tap.setOutputVolume(1)
        tap.receiveMonoFixture(tone)
        check(abs(tap.level - quiet) < 0.001, "App-Lautstärke verändert normalisierte Analyse")
        tap.stop(); tap.simulateRunningTap(sampleRate: sampleRate); tap.setOutputVolume(0)
        tap.receiveMonoFixture([Float](repeating: 0, count: 2048))
        check(!tap.reactive && tap.level == 0, "Stummgeschalteter Tap erfindet Signal")
        tap.stop()
        tap.simulateRunningTap(sampleRate: sampleRate); tap.setOutputVolume(0.1)
        let token = try tap.recognitionCapture.begin(sampleRate: sampleRate)
        let stereo = (0..<48_000).flatMap { _ in [Float(0.025), Float(0.075)] }
        sendStereoFixture(stereo, to: tap)
        let captured = try tap.recognitionCapture.finish(token)
        check(captured.samples.count == 48_000 && captured.samples.allSatisfy { abs($0 - 0.05) < 0.000001 },
              "Erkennung bekommt normalisierte Visualizerwerte statt tatsächlich ausgegebener PCM-Samples")
        check(tap.waveform.contains { $0 > 0.4 }, "Fixture belegt nicht den Unterschied zur Visualizer-Normalisierung")
        let interrupted = try tap.recognitionCapture.begin(sampleRate: sampleRate)
        tap.stop()
        do { _ = try tap.recognitionCapture.finish(interrupted); fatalError("Stop lässt PCM-Sammlung weiterlaufen") }
        catch { check(error as? RecognitionFailure == .audioChanged, "Falscher Unterbrechungsgrund") }
        check(tap.captureSampleRate == nil, "Stop meldet weiterhin Audiozugriff")
        print("AudioTapHarness: OK")
    }
}

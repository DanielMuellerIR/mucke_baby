import CoreAudio
import Foundation
import MuckeAudioTapPCM

@discardableResult
private func sendStereoFixture(_ samples: [Float], to tap: AudioTap, drain: Bool = true) -> Bool {
    samples.withUnsafeBufferPointer { source in
        var buffers = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(source.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: source.baseAddress)
            )
        )
        let accepted = withUnsafePointer(to: &buffers) { tap.enqueuePCMFixture($0) }
        if drain { tap.drainPCMFixture() }
        return accepted
    }
}

private func sendPlanarFixture(_ left: [Float], _ right: [Float], to tap: AudioTap) {
    let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(buffers.unsafeMutablePointer) }
    left.withUnsafeBufferPointer { left in
        right.withUnsafeBufferPointer { right in
            for (index, source) in [left, right].enumerated() {
                buffers[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(source.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: source.baseAddress)
                )
            }
            tap.receivePCMFixture(UnsafePointer(buffers.unsafeMutablePointer))
        }
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
        let stereo = (0..<512).flatMap { _ in [Float(0.025), Float(0.075)] }
        for _ in 0..<94 {
            check(sendStereoFixture(stereo, to: tap), "Interleaved-PCM wurde abgewiesen")
        }
        let captured = try tap.recognitionCapture.finish(token)
        check(captured.samples.count == 94 * 512 && captured.samples.allSatisfy { abs($0 - 0.05) < 0.000001 },
              "Erkennung bekommt normalisierte Visualizerwerte statt tatsächlich ausgegebener PCM-Samples")
        check(tap.waveform.contains { $0 > 0.4 }, "Fixture belegt nicht den Unterschied zur Visualizer-Normalisierung")
        let interrupted = try tap.recognitionCapture.begin(sampleRate: sampleRate)
        check(sendStereoFixture(stereo, to: tap, drain: false), "Testpuffer blieb leer")
        tap.stop()
        checkInterrupted(interrupted, on: tap)
        check(tap.captureSampleRate == nil, "Stop meldet weiterhin Audiozugriff")

        let newRate = 48_000.0
        tap.simulateRunningTap(sampleRate: newRate, interleaved: false)
        tap.drainPCMFixture()
        check(tap.captureSampleRate == newRate && !tap.reactive && tap.level == 0,
              "Formatwechsel analysiert noch ausstehende Blöcke des alten Taps")
        tap.setOutputVolume(0.1)
        let planarToken = try tap.recognitionCapture.begin(sampleRate: newRate)
        sendPlanarFixture([Float](repeating: 0.025, count: 2048), [Float](repeating: 0.075, count: 2048), to: tap)
        let planar = try tap.recognitionCapture.finish(planarToken)
        check(planar.sampleRate == newRate && planar.samples.count == 2048
              && planar.samples.allSatisfy { abs($0 - 0.05) < 0.000001 }, "Planar-Downmix oder Sample-Rate falsch")
        tap.stop()

        tap.simulateRunningTap(sampleRate: sampleRate)
        tap.setOutputVolume(0.1)
        let dropped = try tap.recognitionCapture.begin(sampleRate: sampleRate)
        for _ in 0..<Int(MuckeAudioPCMSlots) {
            check(sendStereoFixture(stereo, to: tap, drain: false), "PCM-Speicher wurde vorzeitig voll")
        }
        check(!sendStereoFixture(stereo, to: tap, drain: false), "Überlauf überschreibt wartende PCM-Blöcke")
        checkInterrupted(dropped, on: tap)

        let afterDrop = try tap.recognitionCapture.begin(sampleRate: sampleRate)
        tap.setOutputVolume(1)
        tap.drainPCMFixture()
        check(tap.waveform.contains { $0 > 0.4 }, "Analyse verwendet den Reglerstand nach statt bei der Aufnahme")
        check(sendStereoFixture([Float](repeating: 0, count: 1024), to: tap), "Transport nimmt nach Überlauf kein PCM mehr an")
        let resumed = try tap.recognitionCapture.finish(afterDrop)
        check(resumed.samples.count == 512 && resumed.samples.allSatisfy { $0 == 0 },
              "Neue Erkennung erbt PCM oder Überlauf vor ihrem Beginn")
        check(!tap.reactive && tap.waveform.allSatisfy { $0 == 0 }, "Visualizer mischt Signal über eine PCM-Lücke")
        print("AudioTapHarness: OK")
    }

    private static func checkInterrupted(_ token: UUID, on tap: AudioTap) {
        do { _ = try tap.recognitionCapture.finish(token); fatalError("PCM-Sammlung wurde trotz Unterbrechung geliefert") }
        catch { check(error as? RecognitionFailure == .audioChanged, "Falscher Unterbrechungsgrund") }
    }
}

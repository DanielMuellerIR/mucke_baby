import Foundation
import ShazamKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private func fails(_ expected: RecognitionFailure, _ action: () throws -> Void) {
    do { try action(); fatalError("Erwarteter Fehler fehlt: \(expected)") }
    catch { require(error as? RecognitionFailure == expected, "Falscher Fehler: \(error)") }
}

@MainActor private final class FakeMatcher: RecognitionMatching {
    var calls = 0
    var completions: [@MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void] = []
    func match(_ pcm: RecognitionPCM, completion: @escaping @MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void) {
        calls += 1; completions.append(completion)
    }
    // Absichtlich behalten: auch ein verspäteter SDK-Callback muss ungefährlich sein.
    func cancel() {}
}

@main struct RecognitionHarness {
    @MainActor static func main() async throws {
        let samples = [Float](repeating: 0.125, count: 16_000 * 4)
        let capture = RecognitionCapture()
        let first = try capture.begin(sampleRate: 16_000, duration: 3)
        capture.append(samples, sampleRate: 16_000)
        let pcm = try capture.finish(first)
        require(pcm.samples.count == 48_000 && pcm.samples.allSatisfy { $0 == 0.125 }, "Grenze oder tatsächliche Amplitude verloren")
        try pcm.validate()
        let second = try capture.begin(sampleRate: 16_000)
        capture.cancel(first)
        capture.append(samples, sampleRate: 16_000)
        let nextPCM = try capture.finish(second)
        require(nextPCM.samples == samples, "Alter Abbruch löscht neue Sammlung")
        let changed = try capture.begin(sampleRate: 16_000)
        capture.append(samples, sampleRate: 48_000)
        fails(.audioChanged) { _ = try capture.finish(changed) }
        let stopped = try capture.begin(sampleRate: 16_000)
        capture.interrupt()
        fails(.audioChanged) { _ = try capture.finish(stopped) }
        fails(.invalidAudio) { _ = try capture.begin(sampleRate: .nan) }
        fails(.notEnoughAudio) { try RecognitionPCM(samples: [1], sampleRate: 16_000).validate() }
        fails(.silent) { try RecognitionPCM(samples: .init(repeating: 0, count: 48_000), sampleRate: 16_000).validate() }
        var damaged = samples; damaged[200] = .infinity
        fails(.invalidAudio) { try RecognitionPCM(samples: damaged, sampleRate: 16_000).validate() }

        let concurrent = RecognitionCapture(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<2000 { concurrent.append(samples, sampleRate: 16_000) }
            group.leave()
        }
        for _ in 0..<100 {
            let token = try concurrent.begin(sampleRate: 16_000)
            concurrent.cancel(token)
        }
        await withCheckedContinuation { done in group.notify(queue: .global()) { done.resume() } }

        let track = RecognizedTrack(title: "  Grüße\u{0}東京  ", artist: "Björk", shazamID: "123", appleMusicURL: URL(string: "https://music.apple.com/de/song/123"))!
        require(track.title == "Grüße東京" && track.appleMusicURL != nil, "Ergebnis bereinigen")
        var authenticatedURL = URLComponents(string: "https://music.apple.com/song/1")!
        authenticatedURL.user = "fixture-user"
        require(RecognizedTrack(title: "Song", artist: nil, shazamID: nil, appleMusicURL: authenticatedURL.url)?.appleMusicURL == nil, "Link mit Benutzerinfo")
        for unsafe in ["file:///tmp/song", "http://music.apple.com/song/1", "https://music.apple.com.evil.test/song/1", "https://music.apple.com:444/song/1"] {
            require(RecognizedTrack(title: "Song", artist: nil, shazamID: nil, appleMusicURL: URL(string: unsafe))?.appleMusicURL == nil, "Unsicherer Ergebnislink")
        }
        require(RecognizedTrack(title: "\n\u{0}", artist: nil, shazamID: nil, appleMusicURL: nil) == nil, "Leerer Titel")
        require(ShazamRecognitionClient.failure(for: NSError(domain: "SDK", code: 202, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)])) == .offline, "Offline-Kette")
        require(ShazamRecognitionClient.failure(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .timedOut, "Netz-Zeitlimit")
        for code in [SHError.Code.invalidAudioFormat, .signatureInvalid] {
            require(ShazamRecognitionClient.failure(for: NSError(domain: SHErrorDomain, code: code.rawValue)) == .invalidAudio, "SDK-Audiofehler wird als Dienstausfall gemeldet")
        }
        require(ShazamRecognitionClient.failure(for: NSError(domain: SHErrorDomain, code: SHError.Code.audioDiscontinuity.rawValue)) == .audioChanged, "SDK-Unterbrechung")
        require(ShazamRecognitionClient.failure(for: NSError(domain: SHErrorDomain, code: SHError.Code.signatureDurationInvalid.rawValue)) == .notEnoughAudio, "SDK-Dauerfehler")
        require(ShazamRecognitionClient.failure(for: NSError(domain: SHErrorDomain, code: SHError.Code.matchAttemptFailed.rawValue)) == .serviceUnavailable, "SDK-Katalogfehler")

        // Lokale Signaturbildung verwendet den SDK-Generator, ohne Katalogabfrage.
        for rate in [16000.0, 22050, 32000, 44100, 48000, 96000] {
            let signal = (0..<Int(rate * 4)).map { i -> Float in
                let t = Double(i) / rate
                return Float(0.2 * sin(2 * .pi * (220 + 60 * t) * t) + 0.1 * cos(2 * .pi * 713 * t))
            }
            let data = try ShazamRecognitionClient.signatureData(RecognitionPCM(samples: signal, sampleRate: rate), maximumDuration: 12)
            let signature = try SHSignature(dataRepresentation: data)
            require((3.9...4.1).contains(signature.duration), "Signaturdauer bei \(rate)")
        }

        let fake = FakeMatcher(), serviceCapture = RecognitionCapture()
        var context: RecognitionContext? = RecognitionContext(generation: 1, stationID: UUID(), title: "Original")
        var volume: Float = 0.5, rate: Double? = 16_000
        let service = MusicRecognitionService(capture: serviceCapture, sampleRate: { rate }, context: { context }, volume: { volume }, matcher: fake, captureWait: 0.02, timeout: 0.2)
        require(fake.calls == 0 && service.phase == .idle, "Initialisierung fragt Katalog ab")
        context = nil; service.start()
        require(service.phase == .failed(.noPlayback) && fake.calls == 0, "Ohne Wiedergabe")
        context = RecognitionContext(generation: 2, stationID: UUID(), title: "Original")
        volume = 0; service.start()
        require(service.phase == .failed(.muted) && fake.calls == 0, "Stumm")
        volume = 0.5; rate = nil; service.start()
        require(service.phase == .failed(.audioUnavailable) && fake.calls == 0, "Ohne Audiofreigabe")
        rate = 16_000; service.start()
        serviceCapture.append(.init(repeating: 0, count: 48_000), sampleRate: 16_000)
        await wait { !service.phase.isBusy }
        require(service.phase == .failed(.silent) && fake.calls == 0, "Stille fragt Katalog ab")
        service.start(); service.cancel()
        try await Task.sleep(nanoseconds: 40_000_000)
        require(service.phase == .cancelled && fake.calls == 0, "Früher Abbruch fragt später Katalog ab")

        func begin() async {
            service.start(); serviceCapture.append(samples, sampleRate: 16_000)
            await wait { service.phase == .matching || !service.phase.isBusy }
            require(service.phase == .matching, "Matching nicht erreicht")
        }
        await begin(); require(fake.calls == 1, "Genau ein expliziter Aufruf")
        service.start(); require(fake.calls == 1, "Doppelstart")
        fake.completions.last?(.success(track))
        require(service.phase == .matched(track), "Ergebnis fehlt")
        require(service.currentResult?.context.title == "Original" && service.currentAdoption == nil, "Treffer wird automatisch übernommen")
        require(service.adoptCurrentResult() && service.currentAdoption?.track == track && fake.calls == 1, "Bewusste Übernahme fehlt oder fragt erneut ab")
        let adopted = service.currentAdoption
        require(service.adoptCurrentResult() && service.currentAdoption == adopted, "Mehrfachübernahme verändert den Vorschlag")
        service.useRadioTitle()
        require(service.currentAdoption == nil && service.currentResult != nil, "Sendertext wiederherstellen löscht den Vorschlag")
        require(service.adoptCurrentResult(), "Erneute bewusste Übernahme")
        service.refresh(); require(service.phase == .matched(track), "Unverändertes Ergebnis verloren")
        await begin(); service.cancel()
        fake.completions.last?(.success(track))
        require(service.currentAdoption == adopted && service.currentResult == nil && service.phase == .cancelled,
                "Abgebrochene neue Suche verändert bewusste Anzeigeübernahme")
        let runningContext = context
        context = nil; service.refresh()
        require(service.adoptedResult == nil && !service.adoptCurrentResult(), "Stopp behält alte Übernahme")
        context = runningContext
        await begin(); fake.completions.last?(.success(track))
        require(!service.adoptCurrentResult(expected: adopted), "Veraltete Ergebniszeile übernimmt einen neueren Vorschlag")
        require(service.adoptCurrentResult(), "Neue Übernahme nach erneutem Wiedergabekontext")
        context = RecognitionContext(generation: 3, stationID: context!.stationID, title: "Neuer Titel")
        require(service.currentAdoption == nil && !service.adoptCurrentResult(), "Veraltete Übernahme vor refresh möglich")
        service.refresh(); require(service.phase == .idle, "Altes Ergebnis bei Titelwechsel")
        await begin(); let old = fake.completions.last!
        service.cancel(); require(service.phase == .cancelled, "Nutzerabbruch")
        await begin(); old(.success(track))
        require(service.phase == .matching, "Verspäteter Callback überschreibt neuen Auftrag")
        fake.completions.last?(.success(nil)); require(service.phase == .noMatch, "Kein Treffer")
        require(service.currentResult == nil && !service.adoptCurrentResult(), "Kein Treffer wird übernommen")
        await begin(); fake.completions.last?(.failure(.offline))
        require(service.phase == .failed(.offline), "Offline-Ergebnis")
        await begin(); fake.completions.last?(.failure(.serviceUnavailable))
        require(service.phase == .failed(.serviceUnavailable), "Dienstfehler")
        await begin(); context = RecognitionContext(generation: 4, stationID: UUID(), title: "Anderer Sender")
        service.refresh(); fake.completions.last?(.success(track))
        require(service.phase == .failed(.playbackChanged), "Senderwechsel mit spätem Treffer")
        await begin(); context = RecognitionContext(generation: 5, stationID: context!.stationID, title: context!.title)
        fake.completions.last?(.success(track))
        require(service.phase == .failed(.playbackChanged), "Positions-/Wiedergabegeneration ohne refresh")
        require(!service.adoptCurrentResult() && service.currentAdoption == nil, "Später Treffer nach Generationwechsel übernehmbar")
        await begin(); await wait { !service.phase.isBusy }
        require(service.phase == .failed(.timedOut), "Gesamtzeitlimit")
        service.start(); volume = 0; service.refresh()
        require(service.phase == .failed(.muted), "Stummschaltung während Sammlung")
        require(context?.title == "Anderer Sender", "Erkennung schreibt Player-Titel")

        let outputID = UUID(), stationID = UUID(), reception = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ position: Double, revision: UInt64 = 20) -> RecognitionContext {
            RecognitionContext(generation: revision, stationID: stationID, title: "DJ - Original (Live Mix)",
                listening: RecognitionListeningContext(outputID: outputID, revision: revision,
                    position: position, receivedAt: reception.addingTimeInterval(position)))
        }
        volume = 0.5; context = at(4)
        await begin()
        context = at(8); service.refresh()
        require(service.phase == .matching, "Normales Weiterhören verwirft den eingefrorenen Aufruf")
        fake.completions.last?(.success(track))
        require(service.currentResult?.context.listening?.position == 4
                && service.currentResult?.context.listening?.receivedAt == reception.addingTimeInterval(4),
                "Fortschreitende Uhr überschreibt Quellposition")
        require(service.adoptCurrentResult(), "Zeitversatz lässt sich nicht übernehmen")
        let frozen = service.currentAdoption
        context = at(10); service.refresh()
        require(service.currentAdoption == frozen, "Normales Weiterhören verändert Übernahme")
        // Kein refresh zwischen Pause und Fortsetzen: die monotone Revision
        // muss auch einen nur vorübergehend ungültigen Kontext sperren.
        context = nil; context = at(10, revision: 21)
        require(service.currentResult == nil && service.currentAdoption == nil && !service.adoptCurrentResult(),
                "Pause/Fortsetzen reaktiviert alten Treffer")
        for revision: UInt64 in 22...26 {
            context = at(4, revision: revision)
            await begin(); let late = fake.completions.last!
            context = at(4, revision: revision + 1)
            late(.success(track))
            require(service.currentResult == nil && service.currentAdoption == nil,
                    "Gleicher Titel und gleiche Position lassen veralteten Treffer zu")
        }
        print("Musikerkennung: PCM-Grenzen/Format/Abbruch, lokale SDK-Signaturen, explizite Aufrufe, Fehler und veraltete Ergebnisse OK")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Zustand nicht rechtzeitig erreicht")
    }
}

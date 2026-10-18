// Wird mit ShazamRecognitionClient.swift kompiliert, damit der echte Delegate
// gegen einen lokalen SDK-Katalog geprüft wird. Das ersetzt keine Shazam-Abnahme.
import Foundation
import ShazamKit

private final class MatchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<RecognizedTrack?, RecognitionFailure>, Never>?
    init(_ continuation: CheckedContinuation<Result<RecognizedTrack?, RecognitionFailure>, Never>) { self.continuation = continuation }
    func finish(_ result: Result<RecognizedTrack?, RecognitionFailure>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(returning: result)
    }
}

@main struct RecognitionSDKHarness {
    @MainActor static func main() async throws {
        let rate = 44100.0
        let samples = (0..<Int(rate * 8)).map { i -> Float in
            let t = Double(i) / rate
            let envelope = 0.6 + 0.4 * sin(2 * .pi * 3 * t)
            var value = 0.0
            for partial in 1...8 {
                value += sin(2 * .pi * (Double(partial * 137) + Double(partial * 11) * t) * t) / Double(partial)
            }
            return Float(value * envelope * 0.15)
        }
        let data = try ShazamRecognitionClient.signatureData(RecognitionPCM(samples: samples, sampleRate: rate), maximumDuration: 12)
        let signature = try SHSignature(dataRepresentation: data), catalog = SHCustomCatalog()
        let item = SHMediaItem(properties: [.title: "Grüße 東京", .artist: "Fixture Artist", .shazamID: "123",
                                             .appleMusicURL: URL(string: "https://music.apple.com/de/song/123")!])
        try catalog.addReferenceSignature(signature, representing: [item])
        let session = SHSession(catalog: catalog)
        var delegate: ShazamMatchDelegate?
        defer { session.delegate = nil; withExtendedLifetime(delegate) {} }
        let result = await withCheckedContinuation { continuation in
            let completion = MatchCompletion(continuation)
            delegate = ShazamMatchDelegate { completion.finish($0) }
            session.delegate = delegate
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { completion.finish(.failure(.timedOut)) }
            session.match(signature)
        }
        guard case .success(let track?) = result, track.title == "Grüße 東京", track.artist == "Fixture Artist",
              track.shazamID == "123", track.appleMusicURL?.host == "music.apple.com" else {
            fatalError("Lokaler SDK-Abgleich oder Ergebnisübernahme fehlgeschlagen: \(result)")
        }
        print("RecognitionSDK: echter lokaler SHSession-Abgleich und Produktdelegate OK; öffentlicher Katalog bleibt separates Gate")
    }
}

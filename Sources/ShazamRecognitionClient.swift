import Foundation
import AVFoundation
import ShazamKit
import os

private let recognitionLog = Logger(subsystem: "de.danielmuller.macradio", category: "recognition")

private final class ShazamMatchDelegate: NSObject, SHSessionDelegate {
    let completed: @Sendable (Result<RecognizedTrack?, RecognitionFailure>) -> Void
    init(completed: @escaping @Sendable (Result<RecognizedTrack?, RecognitionFailure>) -> Void) { self.completed = completed }
    func session(_ session: SHSession, didFind match: SHMatch) {
        let track = match.mediaItems.first.flatMap {
            RecognizedTrack(title: $0.title, artist: $0.artist, shazamID: $0.shazamID, appleMusicURL: $0.appleMusicURL)
        }
        completed(.success(track))
    }
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error { completed(.failure(ShazamRecognitionClient.failure(for: error))) }
        else { completed(.success(nil)) }
    }
}

@MainActor final class ShazamRecognitionClient: RecognitionMatching {
    private var request: UUID?
    private var session: SHSession?
    private var delegate: ShazamMatchDelegate?
    private var work: Task<Void, Never>?
    private var signatureWork: Task<Data, Error>?

    func match(_ pcm: RecognitionPCM, completion: @escaping @MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void) {
        cancel()
        let id = UUID(), session = SHSession()
        request = id; self.session = session
        let minimum = session.catalog.minimumQuerySignatureDuration, maximum = session.catalog.maximumQuerySignatureDuration
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = Task.detached(priority: .userInitiated) { try Self.signatureData(pcm, maximumDuration: maximum) }
                self.signatureWork = prepared
                let data = try await prepared.value
                try Task.checkCancellation()
                guard self.request == id else { return }
                self.signatureWork = nil
                let signature = try SHSignature(dataRepresentation: data)
                guard signature.duration >= minimum, signature.duration <= maximum else { throw RecognitionFailure.notEnoughAudio }
                let delegate = ShazamMatchDelegate { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.request == id else { return }
                        self.cancel(); completion(result)
                    }
                }
                self.delegate = delegate; session.delegate = delegate
                // Ein expliziter Aufruf, kein Streaming-Matching und keine automatischen Wiederholungen.
                recognitionLog.notice("Music recognition: catalog request")
                session.match(signature)
            } catch is CancellationError { }
            catch {
                guard self.request == id else { return }
                self.cancel(); completion(.failure(error as? RecognitionFailure ?? .invalidAudio))
            }
        }
    }

    func cancel() {
        request = nil
        work?.cancel(); work = nil; signatureWork?.cancel(); signatureWork = nil
        session?.delegate = nil; session = nil; delegate = nil
    }

    nonisolated static func failure(for error: Error) -> RecognitionFailure {
        var next: NSError? = error as NSError, depth = 0
        while let current = next, depth < 4 {
            if current.domain == SHErrorDomain {
                switch current.code {
                case SHError.Code.invalidAudioFormat.rawValue, SHError.Code.signatureInvalid.rawValue: return .invalidAudio
                case SHError.Code.audioDiscontinuity.rawValue: return .audioChanged
                case SHError.Code.signatureDurationInvalid.rawValue: return .notEnoughAudio
                default: break
                }
            }
            if current.domain == NSURLErrorDomain {
                if current.code == NSURLErrorNotConnectedToInternet { return .offline }
                if current.code == NSURLErrorTimedOut { return .timedOut }
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError; depth += 1
        }
        return .serviceUnavailable
    }

    nonisolated static func signatureData(_ pcm: RecognitionPCM, maximumDuration: TimeInterval) throws -> Data {
        try Task.checkCancellation()
        guard maximumDuration.isFinite, maximumDuration >= 3 else { throw RecognitionFailure.notEnoughAudio }
        try pcm.validate()
        let duration = min(RecognitionCapture.maximumDuration, maximumDuration)
        let frames = min(pcm.samples.count, Int(floor(pcm.sampleRate * duration)))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: pcm.sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = input.floatChannelData?[0] else { throw RecognitionFailure.invalidAudio }
        input.frameLength = AVAudioFrameCount(frames)
        pcm.samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: frames) }
        let buffer: AVAudioPCMBuffer
        if [16000.0, 32000.0, 44100.0, 48000.0].contains(pcm.sampleRate) { buffer = input }
        else {
            guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                  let converter = AVAudioConverter(from: format, to: outputFormat),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 44100 / pcm.sampleRate) + 256)) else { throw RecognitionFailure.invalidAudio }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error, error == nil, output.frameLength > 0 else { throw RecognitionFailure.invalidAudio }
            output.frameLength = min(output.frameLength, AVAudioFrameCount(floor(44100 * duration)))
            buffer = output
        }
        try Task.checkCancellation()
        let generator = SHSignatureGenerator(); try generator.append(buffer, at: nil)
        return generator.signature().dataRepresentation
    }
}

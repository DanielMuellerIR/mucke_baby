import Foundation
import Combine

@MainActor protocol RecognitionMatching: AnyObject {
    func match(_ pcm: RecognitionPCM, completion: @escaping @MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void)
    func cancel()
}

@MainActor final class MusicRecognitionService: ObservableObject {
    @Published private(set) var phase: RecognitionPhase = .idle
    @Published private(set) var availability: RecognitionFailure?
    private let capture: RecognitionCapture
    private let sampleRate: () -> Double?
    private let context: () -> RecognitionContext?
    private let volume: () -> Float
    private let matcher: any RecognitionMatching
    private let captureWait: TimeInterval
    private let timeout: TimeInterval
    private var request: UUID?
    private var captureToken: UUID?
    private var requestContext: RecognitionContext?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var audit: Task<Void, Error>?

    init(capture: RecognitionCapture, sampleRate: @escaping () -> Double?,
         context: @escaping () -> RecognitionContext?, volume: @escaping () -> Float,
         matcher: any RecognitionMatching, captureWait: TimeInterval = 12, timeout: TimeInterval = 30) {
        self.capture = capture; self.sampleRate = sampleRate; self.context = context; self.volume = volume
        self.matcher = matcher; self.captureWait = max(0.001, min(12, captureWait)); self.timeout = max(self.captureWait + 0.001, min(60, timeout))
        refresh()
    }

    func refresh() {
        if let previous = requestContext, previous != context() {
            let busy = phase.isBusy
            stopWork(); requestContext = nil
            phase = busy ? .failed(.playbackChanged) : .idle
        }
        let reason: RecognitionFailure?
        if context() == nil { reason = .noPlayback }
        else if !volume().isFinite || volume() <= 0 { reason = .muted }
        else if sampleRate() == nil { reason = .audioUnavailable }
        else { reason = nil }
        if availability != reason { availability = reason }
        if phase.isBusy, let reason { stopWork(); phase = .failed(reason) }
    }

    func start() {
        guard !phase.isBusy else { return }
        refresh()
        guard availability == nil, let current = context(), let rate = sampleRate() else {
            phase = .failed(availability ?? .audioUnavailable); return
        }
        stopWork()
        let id = UUID()
        do { captureToken = try capture.begin(sampleRate: rate) }
        catch { phase = .failed(.audioUnavailable); return }
        request = id; requestContext = current; phase = .listening
        deadline = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000)) }
            catch { return }
            guard self.request == id else { return }
            self.stopWork(); self.phase = .failed(.timedOut)
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.captureWait * 1_000_000_000))
                guard self.request == id, let token = self.captureToken else { return }
                let pcm = try self.capture.finish(token); self.captureToken = nil
                let audit = Task.detached(priority: .userInitiated) { try pcm.validate() }
                self.audit = audit; try await audit.value
                try Task.checkCancellation()
                guard self.request == id else { return }
                self.audit = nil
                self.refresh()
                guard self.request == id else { return }
                guard self.context() == current else { self.stopWork(); self.phase = .failed(.playbackChanged); return }
                self.phase = .matching
                self.matcher.match(pcm) { [weak self] result in
                    guard let self, self.request == id else { return }
                    guard self.context() == current else { self.stopWork(); self.phase = .failed(.playbackChanged); return }
                    self.stopWork()
                    switch result {
                    case .success(let track): self.phase = track.map(RecognitionPhase.matched) ?? .noMatch
                    case .failure(let failure): self.phase = .failed(failure)
                    }
                }
            } catch is CancellationError { }
            catch {
                guard self.request == id else { return }
                self.stopWork(); self.phase = .failed(error as? RecognitionFailure ?? .audioUnavailable)
            }
        }
    }

    func cancel() {
        let busy = phase.isBusy
        stopWork()
        if busy { phase = .cancelled }
    }

    private func stopWork() {
        request = nil
        if let token = captureToken { capture.cancel(token) }
        captureToken = nil
        work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        audit?.cancel(); audit = nil
        matcher.cancel()
    }
}

import Foundation

struct RecognitionPCM: Sendable {
    let samples: [Float]
    let sampleRate: Double

    func validate() throws {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate) else { throw RecognitionFailure.invalidAudio }
        guard Double(samples.count) / sampleRate >= 3 else { throw RecognitionFailure.notEnoughAudio }
        var peak: Float = 0
        for (index, sample) in samples.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            guard sample.isFinite else { throw RecognitionFailure.invalidAudio }
            peak = max(peak, abs(sample))
        }
        guard peak > 0.000001 else { throw RecognitionFailure.silent }
    }
}

final class RecognitionCapture: @unchecked Sendable {
    static let maximumDuration: TimeInterval = 12
    private let lock = NSLock()
    struct LiveSource {
        let nextSequence: () -> UInt64
        let lastDrop: () -> UInt64
    }

    // Die Analyse-Queue leiht den Pointer aus dem PCM-Transport bis zum Ende von append.
    private var memory: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var count = 0
    private var rate: Double = 0
    private var token: UUID?
    private var interrupted = false
    private var liveSource: LiveSource?
    private var firstSequence: UInt64?

    deinit { clear() }

    func begin(sampleRate: Double, duration: TimeInterval = maximumDuration) throws -> UUID {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate),
              duration.isFinite, duration > 0, duration <= Self.maximumDuration else { throw RecognitionFailure.invalidAudio }
        let size = Int(ceil(sampleRate * duration))
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        let id = UUID()
        lock.lock()
        guard memory == nil else {
            lock.unlock(); buffer.deinitialize(count: size); buffer.deallocate()
            throw RecognitionFailure.audioUnavailable
        }
        memory = buffer; capacity = size; count = 0; rate = sampleRate; token = id; interrupted = false
        firstSequence = liveSource?.nextSequence()
        lock.unlock()
        return id
    }

    func append(_ samples: [Float], sampleRate: Double) {
        samples.withUnsafeBufferPointer { append($0, sampleRate: sampleRate) }
    }

    func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, sequence: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let memory, !interrupted else { return }
        if let firstSequence {
            guard let sequence else { interrupted = true; return }
            // Eine wartende Analyse kann noch Blöcke von vor Beginn der Erkennung liefern.
            guard sequence >= firstSequence else { return }
        }
        guard sampleRate == rate else { interrupted = true; return }
        let amount = min(samples.count, capacity - count)
        guard amount > 0 else { return }
        memory.advanced(by: count).update(from: samples.baseAddress!, count: amount)
        count += amount
    }

    func finish(_ id: UUID) throws -> RecognitionPCM {
        lock.lock()
        guard token == id, let buffer = memory else { lock.unlock(); throw RecognitionFailure.audioUnavailable }
        let size = capacity, length = count, sampleRate = rate
        let dropped = firstSequence.map { first in (liveSource?.lastDrop() ?? 0) >= first } ?? false
        let changed = interrupted || dropped
        memory = nil; token = nil; count = 0; capacity = 0
        lock.unlock()
        defer { buffer.deinitialize(count: size); buffer.deallocate() }
        guard !changed else { throw RecognitionFailure.audioChanged }
        return RecognitionPCM(samples: Array(UnsafeBufferPointer(start: buffer, count: length)), sampleRate: sampleRate)
    }

    func cancel(_ id: UUID) {
        lock.lock()
        guard token == id else { lock.unlock(); return }
        let buffer = memory, size = capacity
        memory = nil; token = nil; count = 0; capacity = 0
        lock.unlock()
        buffer?.deinitialize(count: size); buffer?.deallocate()
    }

    func interrupt() { lock.lock(); interrupted = true; lock.unlock() }

    func setLiveSource(_ source: LiveSource?) {
        lock.lock()
        liveSource = source
        interrupted = true
        lock.unlock()
    }

    private func clear() {
        lock.lock()
        let buffer = memory, size = capacity
        memory = nil; token = nil; capacity = 0; count = 0
        lock.unlock()
        buffer?.deinitialize(count: size); buffer?.deallocate()
    }
}

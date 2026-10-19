import Foundation

// Gemeinsame Senke des vorhandenen ICY-Empfangs. Keine eigene Netzwerkverbindung.
// Sender-/Empfangswechsel invalidieren den Puffer auch bei gleichem Sendernamen.
final class TimeshiftCapture {
    enum State: Equatable { case off, waiting, buffering, failed(String) }
    private let lock = NSLock()
    private var enabled = false
    private var session: UUID?
    private var contentType: String?
    private var responseReceived = false
    private var buffer: TimeshiftSegments?
    private var retired: TimeshiftSegments?
    private var state: State = .off
    private let makeBuffer: () throws -> TimeshiftSegments
    private let onState: (State) -> Void

    init(makeBuffer: @escaping () throws -> TimeshiftSegments = { try TimeshiftSegments() },
         onState: @escaping (State) -> Void = { _ in }) {
        self.makeBuffer = makeBuffer; self.onState = onState
    }
    deinit { try? buffer?.close() }

    func setEnabled(_ value: Bool) {
        locked {
            enabled = value
            guard discard() else { return }
            if value { startBuffer() } else { publish(.off) }
        }
    }
    func begin(_ id: UUID) {
        locked {
            let removed = discard(); session = id; contentType = nil; responseReceived = false
            if removed { publish(enabled ? .waiting : .off) }
        }
    }
    func accept(_ type: String?, session id: UUID) {
        locked {
            guard session == id else { return }
            contentType = type; responseReceived = true
            if enabled { startBuffer() }
        }
    }
    func noteTitle(_ title: String, at date: Date? = nil, session id: UUID) {
        locked { if session == id { buffer?.noteTitle(title, at: date) } }
    }
    func append(_ bytes: Data, at date: Date? = nil, session id: UUID) {
        locked {
            guard session == id, let buffer else { return }
            do { try buffer.append(bytes, at: date) }
            catch { fail(error) }
        }
    }
    func end(_ id: UUID? = nil) {
        locked {
            guard id == nil || session == id else { return }
            let removed = discard(); session = nil; contentType = nil; responseReceived = false
            if removed { publish(enabled ? .waiting : .off) }
        }
    }
    func makeReader(delay: TimeInterval, decodedSampleRate: Int? = nil) throws -> TimeshiftSegmentStream {
        try locked {
            guard let buffer else { throw TimeshiftFailure.notReady }
            return try buffer.makeReader(delay: delay, decodedSampleRate: decodedSampleRate)
        }
    }
    var metrics: TimeshiftSegments.Metrics? { locked { buffer?.metrics } }
    var timeline: MetadataTimeline { locked { buffer?.timeline ?? MetadataTimeline() } }
    var currentState: State { locked { state } }
    var requiresDecodedSampleRate: Bool { locked { buffer?.requiresDecodedSampleRate == true } }
    func receivedAt(position: TimeInterval) -> Date? { locked { buffer?.receivedAt(position: position) } }
    func rejectPlayback(_ error: Error) { locked { fail(error) } }
    func makeReader(at position: TimeInterval, decodedSampleRate: Int? = nil) throws -> TimeshiftSegmentStream {
        try locked {
            guard let buffer else { throw TimeshiftFailure.notReady }
            return try buffer.makeReader(at: position, decodedSampleRate: decodedSampleRate)
        }
    }
    func cancelReaders() { locked { buffer?.cancelReaders(); retired?.cancelReaders() } }

    private func startBuffer() {
        guard session != nil, responseReceived else { publish(.waiting); return }
        if let retired {
            guard retired.metrics.readers == 0 else {
                publish(.failed(String(localized: "Zeitversatz wartet auf das Schließen des vorherigen Lesers."))); return
            }
            do { try retired.close(); self.retired = nil }
            catch {
                publish(.failed(String(localized: "Zeitversatz gestoppt: Audio oder Pufferspeicher nicht verfügbar."))); return
            }
        }
        do {
            let next = try makeBuffer()
            do { try next.accept(contentType: contentType) }
            catch { try? next.close(); throw error }
            buffer = next; publish(.buffering)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        _ = discard()
        let message: String
        switch error {
        case TimeshiftFailure.unsupportedFormat:
            message = StreamCapturePolicy.isHLS(contentType)
                ? String(localized: "Zeitversatz ist für HLS nicht verfügbar. Die Live-Wiedergabe läuft weiter.")
                : String(localized: "Zeitversatz unterstützt MP3 und AAC-ADTS. Andere Formate spielen weiterhin live.")
        case TimeshiftFailure.lowDisk:
            message = String(localized: "Zeitversatz gestoppt: weniger als 10 GiB frei.")
        case TimeshiftFailure.invalidAudio:
            message = String(localized: "Zeitversatz gestoppt: Audioformat ist beschädigt oder wird nicht unterstützt.")
        case TimeshiftSegmentFailure.formatChanged:
            message = String(localized: "Zeitversatz gestoppt: Das Audioformat hat sich geändert. Mit Live fortsetzen.")
        case TimeshiftSegmentFailure.readerOverrun:
            message = String(localized: "Zeitversatz gestoppt: Der Leser hat die Puffergrenze erreicht.")
        case TimeshiftSegmentFailure.decoderFormat:
            message = String(localized: "Zeitversatz gestoppt: AAC-Decoderformat passt nicht zum Puffer.")
        default:
            message = String(localized: "Zeitversatz gestoppt: Audio oder Pufferspeicher nicht verfügbar.")
        }
        publish(.failed(message))
    }
    private func discard() -> Bool {
        if let buffer {
            buffer.cancelReaders()
            do { try buffer.close() }
            catch {
                retired = buffer; self.buffer = nil
                publish(.failed(String(localized: "Zeitversatz gestoppt: Audio oder Pufferspeicher nicht verfügbar.")))
                return false
            }
            if buffer.metrics.readers > 0 { retired = buffer }
            self.buffer = nil
        }
        return true
    }
    private func publish(_ next: State) { if next != state { state = next; onState(next) } }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}

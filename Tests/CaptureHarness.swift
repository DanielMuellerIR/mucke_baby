import Foundation

final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Int64) { lock.lock(); self.value = value; lock.unlock() }
    @discardableResult func increment() -> Int64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

final class CaptureProtocol: URLProtocol {
    static let lock = NSLock()
    private static var instance: CaptureProtocol?
    static let starts = CaptureBox(0)
    static let stops = CaptureBox(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.increment()
        var headers = ["Content-Type": "audio/mpeg"]
        if request.url?.lastPathComponent == "metadata" { headers["icy-metaint"] = "3" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        Self.lock.lock(); Self.instance = self; Self.lock.unlock()
    }
    override func stopLoading() {
        Self.stops.increment()
        Self.lock.lock(); if Self.instance === self { Self.instance = nil }; Self.lock.unlock()
    }
    static var ready: Bool { lock.lock(); defer { lock.unlock() }; return instance != nil }
    static func emit(_ data: Data) {
        lock.lock(); let current = instance; lock.unlock()
        guard let current else { fatalError("URLProtocol fehlt") }
        current.client?.urlProtocol(current, didLoad: data)
    }
}

@main
enum CaptureHarness {
    static func check(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func wait(_ condition: () -> Bool) {
        let until = Date().addingTimeInterval(5)
        while !condition() {
            check(Date() < until, "Capture-Fixture wartet zu lange")
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeCapture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(), id = UUID(), foreign = UUID()
        let recorder = Recorder(directory: root.appendingPathComponent("toggle"), minimumFreeBytes: -1)
        recorder.configureCapture(station: "Fixture", streamID: id, enabled: false, revision: 0, at: base)
        recorder.captureAudio(Data([0]), at: base, streamID: id); recorder.flush()
        check(recorder.snapshot().isEmpty && recorder.captureState().phase == .off, "Default aus schreibt Dateien")
        recorder.setCaptureEnabled(true, revision: 1, at: base.addingTimeInterval(1))
        recorder.captureAudio(Data([99]), at: base, streamID: id); recorder.flush()
        check(recorder.snapshot().isEmpty && recorder.captureState().phase == .waiting, "Alte gepufferte Bytes wurden aufgenommen")
        recorder.captureAudio(Data([1,2,3]), at: base.addingTimeInterval(1), streamID: id); recorder.flush()
        check(recorder.captureState().phase == .recording && recorder.captureState().bytes == 3, "Kein tatsächlicher aktiver Status nach Schreibbeginn")
        let first = recorder.snapshot()[0]
        recorder.setCaptureEnabled(false, revision: 2, at: base.addingTimeInterval(2))
        recorder.captureAudio(Data([98]), at: base.addingTimeInterval(2), streamID: id); recorder.flush()
        check(try Data(contentsOf: recorder.dir.appendingPathComponent(first.file)) == Data([1,2,3]), "Ausschalten lässt weitere Bytes durch")
        check(recorder.snapshot()[0].end != nil && recorder.captureState().phase == .off, "Ausschalten schließt Datei nicht")
        recorder.setCaptureEnabled(true, revision: 3, at: base.addingTimeInterval(3))
        recorder.captureAudio(Data([4,5]), at: base.addingTimeInterval(3), streamID: id)
        recorder.captureAudio(Data([97]), at: base.addingTimeInterval(4), streamID: foreign)
        recorder.finishCapture(streamID: foreign, at: base.addingTimeInterval(4)); recorder.flush()
        check(recorder.snapshot().count == 2 && recorder.snapshot()[1].sessionID != first.sessionID && recorder.captureState().phase == .recording, "Neue Segmente oder alte Stream-IDs werden verwechselt")
        recorder.clearCapture(enabled: true, revision: 4, at: base.addingTimeInterval(5))
        recorder.captureAudio(Data([96]), at: base.addingTimeInterval(6), streamID: id); recorder.flush()
        check(recorder.snapshot().allSatisfy { $0.end != nil }, "Stop lässt offene Datei zurück")
        check(try Data(contentsOf: recorder.dir.appendingPathComponent(recorder.snapshot()[1].file)) == Data([4,5]), "Alte Daten schreiben nach Stop weiter")

        let rollover = Recorder(directory: root.appendingPathComponent("rollover"), minimumFreeBytes: -1)
        rollover.configureCapture(station: "Roll", streamID: id, enabled: true, revision: 1, at: base)
        rollover.captureAudio(Data([1,2,3]), at: base, streamID: id); rollover.flush()
        rollover.songBoundary(at: base.addingTimeInterval(86_401)); rollover.flush()
        check(rollover.captureState().phase == .waiting && rollover.captureState().bytes == 0, "Leere Rollover-Datei wird als aktive Aufnahme gemeldet")
        rollover.captureAudio(Data([4]), at: base.addingTimeInterval(86_402), streamID: id); rollover.flush()
        check(rollover.captureState().phase == .recording && rollover.captureState().bytes == 1 && rollover.snapshot().count == 2, "Rollover zählt alte Bytes zur neuen Datei")
        rollover.clearCapture(enabled: false, revision: 2, at: base.addingTimeInterval(86_403)); rollover.flush()

        let free = CaptureBox(Recorder.minFreeBytes + 1)
        let disk = Recorder(directory: root.appendingPathComponent("disk"), availableCapacity: free.get, capacityCheckInterval: 0.01)
        disk.configureCapture(station: "Disk", streamID: id, enabled: true, revision: 1, at: base)
        disk.captureAudio(Data([1]), at: base, streamID: id); disk.flush()
        check(disk.captureState().phase == .recording, "Disk-Fixture startet nicht")
        free.set(Recorder.minFreeBytes - 1)
        wait { disk.captureState().phase == .lowDisk }
        check(disk.snapshot()[0].end != nil, "Periodischer Disk-Schutz benötigt weitere Audiobytes")
        disk.captureAudio(Data([2]), at: Date(), streamID: id); disk.flush()
        check(try Data(contentsOf: disk.dir.appendingPathComponent(disk.snapshot()[0].file)) == Data([1]), "Disk-Stopp wird durch neue Bytes rückgängig")

        let writes = CaptureBox(0)
        let failed = Recorder(directory: root.appendingPathComponent("write"), minimumFreeBytes: -1, writeAudio: { handle, data in
            if writes.increment() == 2 { throw CocoaError(.fileWriteNoPermission) }
            try handle.write(contentsOf: data)
        })
        failed.configureCapture(station: "Write", streamID: id, enabled: true, revision: 1, at: base)
        failed.captureAudio(Data([1]), at: base, streamID: id)
        failed.captureAudio(Data([2]), at: base.addingTimeInterval(1), streamID: id)
        failed.captureAudio(Data([3]), at: base.addingTimeInterval(2), streamID: id); failed.flush()
        check(failed.captureState().phase == .writeFailed && failed.snapshot().count == 1 && failed.snapshot()[0].end != nil, "Schreibfehler bleibt aktiv oder beginnt still neue Dateien")
        check(try Data(contentsOf: failed.dir.appendingPathComponent(failed.snapshot()[0].file)) == Data([1]), "Fehlgeschlagene Bytes wurden als Aufnahme gemeldet")
        failed.setCaptureEnabled(false, revision: 2); failed.setCaptureEnabled(true, revision: 3)
        failed.captureAudio(Data([4]), at: Date().addingTimeInterval(1), streamID: id); failed.flush()
        check(failed.captureState().phase == .recording && failed.snapshot().count == 2, "Expliziter neuer Aufnahmeversuch bleibt gesperrt")
        failed.clearCapture(enabled: false, revision: 4); failed.flush()

        let index = Recorder(directory: root.appendingPathComponent("index"), minimumFreeBytes: -1)
        try FileManager.default.createDirectory(at: index.dir.appendingPathComponent("recordings-index.json"), withIntermediateDirectories: true)
        index.configureCapture(station: "Index", streamID: id, enabled: true, revision: 1, at: base)
        index.captureAudio(Data([1]), at: base, streamID: id); index.flush()
        check(index.captureState().phase == .writeFailed && index.snapshot().isEmpty, "Nicht gespeicherter Index wird als Aufnahme gemeldet")
        check(try FileManager.default.contentsOfDirectory(atPath: index.dir.path) == ["recordings-index.json"], "Indexfehler hinterlässt verwaiste Audiodatei")

        for path in ["audio-only", "metadata"] {
            let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CaptureProtocol.self]
            let reader = ICYMetadataReader(configuration: cfg)
            let target = Recorder(directory: root.appendingPathComponent(path), minimumFreeBytes: -1)
            let received = CaptureBox(0), starts = CaptureProtocol.starts.get(), stops = CaptureProtocol.stops.get()
            target.configureCapture(station: path, streamID: id, enabled: false, revision: 0)
            reader.start(url: URL(string: "https://fixture.invalid/" + path)!, allowAudioOnly: true,
                onStart: { type, _ in target.captureFormat(type, streamID: id) },
                onAudioAt: { data, date in target.captureAudio(data, at: date, streamID: id); received.increment() })
            wait { CaptureProtocol.ready }
            func emit(_ bytes: [UInt8]) {
                var wire = Data(bytes)
                if path == "metadata" { wire.append(0) }
                let before = received.get(); CaptureProtocol.emit(wire); wait { received.get() > before }; target.flush()
            }
            emit([90,91,92]); check(target.snapshot().isEmpty, "Inaktive ICY-Senke schreibt")
            target.setCaptureEnabled(true, revision: 1); emit([1,2,3])
            target.setCaptureEnabled(false, revision: 2); emit([93,94,95])
            target.setCaptureEnabled(true, revision: 3); emit([4,5,6])
            reader.stop(); target.clearCapture(enabled: false, revision: 4); target.flush()
            wait { CaptureProtocol.stops.get() == stops + 1 }
            check(CaptureProtocol.starts.get() == starts + 1, "Umschalten öffnet zusätzliche Streamverbindung")
            let clips = target.snapshot(); check(clips.count == 2 && clips.allSatisfy { $0.end != nil }, "ICY-Umschalten hinterlässt falsche Clips")
            check(try Data(contentsOf: target.dir.appendingPathComponent(clips[0].file)) == Data([1,2,3]), "ICY-Datei enthält Metadaten oder ausgeschaltete Bytes")
            check(try Data(contentsOf: target.dir.appendingPathComponent(clips[1].file)) == Data([4,5,6]), "Zweites ICY-Segment falsch")
        }
        print("CaptureHarness: Default, Bytegrenzen, Umschalten, Stream-IDs, Disk, Schreibfehler und eine ICY-Verbindung OK")
    }
}

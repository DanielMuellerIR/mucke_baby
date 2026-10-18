import Foundation

@main struct TimeshiftSegmentsHarness {
    static func check(_ value: Bool, _ message: String = "Prüfung fehlgeschlagen") { precondition(value, message) }
    static func frame(_ payload: UInt8 = 0) -> Data { Data([0xff, 0xfb, 0x90, 0] + [UInt8](repeating: payload, count: 413)) }
    static func expect(_ expected: Error, _ body: () throws -> Void) {
        do { try body(); fatalError("Fehlender Fehler: \(expected)") }
        catch { precondition(String(describing: error) == String(describing: expected), "\(error) statt \(expected)") }
    }
    static func main() throws {
        if CommandLine.arguments.count > 2 {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let buffer = try TimeshiftSegments(root: root, freeBytes: { _ in Int64.max })
            try buffer.accept(contentType: "audio/mpeg"); try buffer.append(frame())
            // exit lässt die Audio-/Indexdateien liegen und gibt nur den Kernel-Lock frei.
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimeshiftSegmentsHarness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("recording.mp3"), sentinel = Data("Dauerhafte Aufnahme".utf8)
        try sentinel.write(to: recording)
        let buffers = root.appendingPathComponent("buffers")
        let buffer = try TimeshiftSegments(root: buffers,
            limits: TimeshiftSegmentLimits(duration: 2, bytes: 131_072, segmentDuration: 0.25), freeBytes: { _ in Int64.max })
        for type in [nil, "audio/aac", "audio/ogg", "audio/opus", "audio/flac", "text/plain"] as [String?] {
            expect(TimeshiftFailure.unsupportedFormat) { try buffer.accept(contentType: type) }
        }
        try buffer.accept(contentType: "audio/mpeg")
        var source = Data()
        for index in 0..<50 { let data = frame(UInt8(index)); source.append(data); try buffer.append(data) }
        let reader = try buffer.makeReader(delay: 2); reader.open()
        expect(TimeshiftSegmentFailure.tooManyReaders) { _ = try buffer.makeReader(delay: 1) }
        var output = [UInt8](repeating: 0, count: 509), received = Data()
        // Kleine Lesegrößen kreuzen Frame- und Dateigrenzen. Keine Vorläufe doppeln.
        while received.count < source.count {
            let count = reader.read(&output, maxLength: min(output.count, source.count - received.count))
            precondition(count > 0); received.append(contentsOf: output.prefix(count))
        }
        precondition(received == source, "Segmentwechsel verändert Bytes")
        let current = buffer.index.last!, file = buffer.directory.appendingPathComponent(current.file)
        let held = try Data(contentsOf: file)
        try TimeshiftSegments.cleanupAbandoned(root: buffers)
        precondition(FileManager.default.fileExists(atPath: file.path), "Aktive Sitzung entfernt")
        try buffer.close()
        check(try Data(contentsOf: file) == held, "Close löscht Datei eines aktiven Lesers")
        reader.close()
        precondition(!FileManager.default.fileExists(atPath: buffer.directory.path), "Letzter Leser räumt nicht auf")

        let paused = try TimeshiftSegments(root: buffers,
            limits: TimeshiftSegmentLimits(duration: 2, bytes: 131_072, segmentDuration: 0.25), freeBytes: { _ in Int64.max })
        try paused.accept(contentType: "audio/mpeg")
        for _ in 0..<50 { try paused.append(frame()) }
        let slow = try paused.makeReader(delay: 2)
        let first = paused.index.first!, oldest = paused.directory.appendingPathComponent(first.file)
        let initial = try Data(contentsOf: oldest)
        expect(TimeshiftSegmentFailure.readerOverrun) {
            for _ in 0..<500 { try paused.append(frame()) }
        }
        precondition(paused.metrics.bytes <= 131_072 && paused.metrics.duration <= 2.00001)
        check(try Data(contentsOf: oldest) == initial, "Überlauf löscht verwendetes Segment")
        try paused.close(); slow.close()

        var free = Int64.max
        let bounded = try TimeshiftSegments(root: buffers,
            limits: TimeshiftSegmentLimits(duration: 30, bytes: 32_768, segmentDuration: 0.25), freeBytes: { _ in free })
        try bounded.accept(contentType: "Audio/MPEG; charset=binary")
        for _ in 0..<10_000 { try bounded.append(frame()) }
        precondition(bounded.metrics.bytes <= 32_768 && bounded.metrics.live > 250, "Bytelimit/Dauerlauf")
        let onDisk = try FileManager.default.contentsOfDirectory(at: bounded.directory, includingPropertiesForKeys: [.fileSizeKey])
        let audioBytes = try onDisk.filter { $0.pathExtension == "mp3" }.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(audioBytes == bounded.metrics.bytes, "Vorläufe werden nicht mitgezählt")
        free = 10 * 1024 * 1024 * 1024 - 1
        expect(TimeshiftFailure.lowDisk) { try bounded.append(frame()) }
        try bounded.close()
        expect(TimeshiftFailure.lowDisk) { _ = try TimeshiftSegments(root: buffers, freeBytes: { _ in 0 }) }

        let durationBound = try TimeshiftSegments(root: buffers, freeBytes: { _ in Int64.max })
        try durationBound.accept(contentType: "audio/mpeg")
        for _ in 0..<15_000 { try durationBound.append(frame()) }
        precondition(durationBound.metrics.live > 390 && durationBound.metrics.oldest > 90)
        precondition(durationBound.metrics.duration <= 300.00001 && durationBound.metrics.bytes <= 32 * 1024 * 1024)
        precondition(durationBound.metrics.segments <= 256)
        let storedIndex = try Data(contentsOf: durationBound.directory.appendingPathComponent("index.json"))
        precondition(storedIndex.count <= 1_048_576)
        let decodedIndex = try JSONDecoder().decode([TimeshiftSegment].self, from: storedIndex)
        precondition(decodedIndex.count == durationBound.metrics.segments)
        try durationBound.close()

        // Ein wartender Stream muss auf Close aufwachen; kein blockierter VLC-Stop.
        let waiting = try TimeshiftSegments(root: buffers, freeBytes: { _ in Int64.max })
        try waiting.accept(contentType: "audio/mpeg")
        for _ in 0..<125 { try waiting.append(frame()) }
        let blocked = try waiting.makeReader(delay: 30); blocked.open()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while blocked.read(&bytes, maxLength: bytes.count) > 0 {}
            blocked.close(); done.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        waiting.cancelReaders(); try waiting.close()
        precondition(done.wait(timeout: .now() + 2) == .success, "Wartender Leser bleibt hängen")
        precondition(!FileManager.default.fileExists(atPath: waiting.directory.path))

        let malformed = try TimeshiftSegments(root: buffers, freeBytes: { _ in Int64.max })
        try malformed.accept(contentType: "audio/mpeg")
        try malformed.append(frame())
        var changed = frame(); changed[3] = 0xc0
        expect(TimeshiftSegmentFailure.formatChanged) { try malformed.append(changed) }
        try malformed.close()
        let garbage = try TimeshiftSegments(root: buffers, freeBytes: { _ in Int64.max })
        try garbage.accept(contentType: "audio/mpeg")
        expect(TimeshiftFailure.invalidAudio) { try garbage.append(Data(repeating: 0, count: 70_000)) }
        try garbage.close()

        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--crash", buffers.path]; try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        check(try FileManager.default.contentsOfDirectory(atPath: buffers.path).filter { $0 != "manager.lock" }.count == 1)
        let survivor = root.appendingPathComponent("survivor")
        try FileManager.default.createDirectory(at: survivor, withIntermediateDirectories: false)
        try sentinel.write(to: survivor.appendingPathComponent("audio.mp3"))
        try FileManager.default.createSymbolicLink(at: buffers.appendingPathComponent(UUID().uuidString), withDestinationURL: survivor)
        let incomplete = buffers.appendingPathComponent(".creating-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
        try TimeshiftSegments.cleanupAbandoned(root: buffers)
        precondition(!FileManager.default.fileExists(atPath: incomplete.path), "Unvollständiger Crash-Start bleibt liegen")
        check(try FileManager.default.contentsOfDirectory(atPath: buffers.path).filter { $0 != "manager.lock" }.count == 1, "Crash-Puffer nicht entfernt")
        check(try Data(contentsOf: survivor.appendingPathComponent("audio.mp3")) == sentinel)

        let capture = TimeshiftCapture(makeBuffer: { try TimeshiftSegments(root: buffers, freeBytes: { _ in Int64.max }) })
        let old = UUID(), new = UUID()
        capture.begin(old); capture.accept("audio/mpeg", session: old); capture.append(frame(), session: old)
        precondition(capture.metrics == nil, "Default nimmt auf")
        capture.setEnabled(true)
        for _ in 0..<25 { capture.append(frame(), session: old) }
        precondition(capture.metrics?.bytes ?? 0 > 0)
        capture.begin(new); capture.accept("audio/mpeg", session: new)
        capture.append(frame(), session: old); capture.end(old)
        precondition(capture.metrics?.bytes == 0, "Alte Session verändert neue")
        capture.append(frame(), session: new)
        for _ in 0..<150 { capture.append(frame(), session: new) }
        let heldReader = try capture.makeReader(delay: 30)
        capture.setEnabled(false); precondition(capture.metrics == nil)
        capture.setEnabled(true); precondition(capture.metrics == nil, "Neuer Puffer wächst neben altem Leser")
        heldReader.close()
        capture.setEnabled(false); capture.setEnabled(true)
        precondition(capture.metrics != nil)
        capture.setEnabled(true); capture.end(); precondition(capture.metrics == nil)
        check(try Data(contentsOf: recording) == sentinel, "Dauerhafte Aufnahme verändert")
        print("Timeshift segments: Grenzen, Leser, Crash, Disk, Sessionwechsel und Datenerhalt OK")
    }
}

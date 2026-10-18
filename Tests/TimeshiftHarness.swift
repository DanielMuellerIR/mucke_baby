import Foundation

@main struct TimeshiftHarness {
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
    static func expect(_ expected: TimeshiftFailure, _ body: () throws -> Void) {
        do { try body(); fatalError("Fehlender Fehler: \(expected)") }
        catch { check(error as? TimeshiftFailure == expected, "Unerwarteter Fehler: \(error)") }
    }
    static func frame(_ byte: UInt8 = 0) -> Data {
        Data([0xff, 0xfb, 0x90, 0x00] + [UInt8](repeating: byte, count: 413))
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimeshiftHarness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("dauerhafte-aufnahme.mp3"), sentinel = Data("Bestehende Aufnahme".utf8)
        try sentinel.write(to: recording)
        let duration = 1152.0 / 44100
        var endGuard = TimeshiftEndGuard()
        check(!endGuard.observe(position: 2, duration: 12, uptime: 1), "Frühes Ende")
        check(!endGuard.observe(position: 2, duration: 12, uptime: 99), "Stillstand mitten im Ausschnitt beendet ihn")
        check(!endGuard.observe(position: 11.764, duration: 11.976, uptime: 100), "Fortschritt gilt als Ende")
        check(!endGuard.observe(position: 11.764, duration: 11.976, uptime: 101.9), "Endfrist zu kurz")
        check(endGuard.observe(position: 11.764, duration: 11.976, uptime: 102), "Belegter EOF-Stillstand bleibt hängen")
        endGuard.reset()
        check(!endGuard.observe(position: 11.764, duration: 11.976, uptime: 500), "Pause zählt als Stillstand")
        check(!endGuard.observe(position: .nan, duration: 12, uptime: 501), "Ungültige Position gilt als Ende")
        for chunk in [1, 17, 4096, 100_000] {
            let buffer = try TimeshiftBuffer(parentDirectory: root, freeBytes: { _ in Int64.max })
            try buffer.accept(contentType: "Audio/MPEG; charset=binary")
            let source = (0..<160).reduce(into: Data()) { $0.append(frame(UInt8($1))) }
            buffer.noteTitle("Artist - Erster Titel")
            for start in stride(from: 0, to: source.count, by: chunk) {
                try buffer.append(source.subdata(in: start..<min(source.count, start + chunk)))
            }
            check(abs(buffer.metrics.live - 160 * duration) < 0.0001, "Codeczeit hängt von Netzwerkstücken ab")
            let snapshot = try buffer.makeSnapshot(delay: 5)
            let copied = try Data(contentsOf: snapshot.url)
            check(copied == source.suffix(snapshot.bytes), "Ausschnitt enthält andere Audio-Bytes")
            check(snapshot.title(at: 1) == "Artist - Erster Titel", "Titelanker fehlt")
            expect(.snapshotInUse) { _ = try buffer.makeSnapshot(delay: 2) }
            try buffer.close()
            check(!FileManager.default.fileExists(atPath: buffer.directory.path), "Puffer nicht entfernt")
            expect(.closed) { try buffer.append(frame()) }
        }

        var free = Int64.max
        let byteBound = try TimeshiftBuffer(parentDirectory: root,
            limits: TimeshiftLimits(duration: 30, compressedBytes: 16_384), freeBytes: { _ in Int64.max })
        try byteBound.accept(contentType: "audio/mpeg")
        for _ in 0..<200 { try byteBound.append(frame()) }
        check(byteBound.metrics.live > 5 && byteBound.metrics.duration < 1.1
              && byteBound.metrics.bufferedBytes == 39 * 417, "Bytelimit greift nicht vor dem Dauerlimit")
        let byteClip = try byteBound.makeSnapshot(delay: 10)
        check(byteClip.bytes == byteBound.metrics.bufferedBytes && byteClip.bytes <= 16_384, "Ausschnitt überschreitet Bytelimit")
        try byteBound.close()
        let fragmented = try TimeshiftBuffer(parentDirectory: root, freeBytes: { _ in Int64.max })
        try fragmented.accept(contentType: "audio/mpeg")
        fragmented.noteTitle("Alt")
        try fragmented.append(frame().prefix(200))
        fragmented.noteTitle("Neu")
        try fragmented.append(frame().suffix(217))
        for _ in 0..<25 { try fragmented.append(frame()) }
        let fragmentedClip = try fragmented.makeSnapshot(delay: 2)
        check(fragmentedClip.titles.count == 2 && fragmentedClip.titles[0].raw == "Alt"
              && fragmentedClip.titles[1].raw == "Neu" && abs(fragmentedClip.titles[1].offset - duration) < 0.0001,
              "ICY-Grenze beschriftet einen bereits begonnenen Frame rückwirkend")
        try fragmented.close()
        let limits = TimeshiftLimits(duration: 2, compressedBytes: 32_768)
        let buffer = try TimeshiftBuffer(parentDirectory: root, limits: limits, freeBytes: { _ in free })
        for type in [nil, "audio/aac", "audio/ogg", "audio/opus", "text/plain"] as [String?] {
            expect(.unsupportedFormat) { try buffer.accept(contentType: type) }
        }
        expect(.unsupportedFormat) { try buffer.append(frame()) }
        try buffer.accept(contentType: "audio/mpeg")
        expect(.notReady) { _ = try buffer.makeSnapshot(delay: .nan) }
        buffer.noteTitle("Erster")
        for _ in 0..<20 { try buffer.append(frame(1)) }
        buffer.noteTitle("Zweiter")
        for _ in 0..<20 { try buffer.append(frame(2)) }
        let clip = try buffer.makeSnapshot(delay: 2)
        check(clip.titles.map(\.raw) == ["Erster", "Zweiter"] && clip.titles[0].offset == 0
              && abs(clip.titles[1].offset - 20 * duration) < 0.0001, "Falsche Titelzeitachse")
        check(clip.title(at: 0.2) == "Erster" && clip.title(at: 0.8) == "Zweiter", "Titel verwendet Live-Zeit")
        let protected = try Data(contentsOf: clip.url)
        buffer.noteTitle("../../Dritter")
        for _ in 0..<500 { try buffer.append(frame(3)) }
        check(buffer.metrics.bufferedBytes <= limits.compressedBytes, "Bytelimit überschritten")
        check(buffer.metrics.duration <= limits.duration + 0.0001, "Dauerlimit überschritten")
        check(buffer.metrics.oldest > clip.end, "Überlauf nicht erreicht")
        check(try Data(contentsOf: clip.url) == protected, "Aktiver Ausschnitt beim Überlauf verändert")
        free = 10 * 1024 * 1024 * 1024 - 1
        expect(.lowDisk) { try buffer.append(frame()) }
        check(try Data(contentsOf: clip.url) == protected, "Disk-Gate zerstört aktiven Ausschnitt")
        free = 10 * 1024 * 1024 * 1024
        try buffer.append(frame())
        try buffer.releaseSnapshot(UUID())
        check(FileManager.default.fileExists(atPath: clip.url.path), "Alte Leser-ID löscht aktuellen Ausschnitt")
        try buffer.releaseSnapshot(clip.id)
        expect(.invalidAudio) { try buffer.append(Data(repeating: 0, count: 70_000)) }
        check(buffer.metrics.pendingBytes <= 8192, "Parser wächst bei beschädigtem Audio")
        try buffer.close(); try buffer.close()
        check(try Data(contentsOf: recording) == sentinel, "Dauerhafte Aufnahme verändert")
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == [recording.lastPathComponent], "Eigene Dateien blieben liegen")
        expect(.lowDisk) { _ = try TimeshiftBuffer(parentDirectory: root, freeBytes: { _ in 0 }) }
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == [recording.lastPathComponent], "Abgelehnter Puffer bleibt liegen")
        print("TimeshiftHarness: Frame-/Bytezeit, Splitpakete, Grenzen, Titel, Leser, Disk, Fehler und Aufnahmeschutz OK")
    }
}

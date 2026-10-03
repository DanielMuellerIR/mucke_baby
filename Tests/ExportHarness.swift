import Foundation
import AVFoundation

@main
enum ExportHarness {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func waitForRecording(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); check(false, "ungültiger Export wurde akzeptiert") }
        catch {}
    }

    // Eigene PCM-Fixture braucht weder Wiedergabe noch Audio-/Mikrofonrechte.
    static func makeTone(_ url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.3)
        }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }

    static func decode(_ url: URL, duration: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let actual = Double(file.length) / file.processingFormat.sampleRate
        check(abs(actual - duration) < 0.15, "falsche Ausschnittdauer: \(actual)")
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        check(values.contains { abs($0) > 0.05 }, "Export enthält nur Stille")
        return values
    }

    static func rms(_ values: ArraySlice<Float>) -> Double {
        sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count))
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-ExportTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SongExporter.cleanupTemporaryExports(); try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.wav")
        try makeTone(source, seconds: 12)
        let original = try Data(contentsOf: source)
        let target = root.appendingPathComponent("song.m4a")
        let sentinel = Data("vorhandenes Exportziel".utf8)
        try sentinel.write(to: target)

        for alias in [source, root.appendingPathComponent("symlink.wav"), root.appendingPathComponent("hardlink.wav")] {
            if alias.lastPathComponent == "symlink.wav" { try fm.createSymbolicLink(at: alias, withDestinationURL: source) }
            if alias.lastPathComponent == "hardlink.wav" { try fm.linkItem(at: source, to: alias) }
            await rejects { try await SongExporter.export(source: source, offset: 0, duration: 5, mode: .hardCut, to: alias) }
            check(try Data(contentsOf: source) == original, "Aufnahme wurde durch Alias-Ziel verändert")
        }
        for (offset, duration) in [(0.0, 0.5), (.nan, 5), (0, .infinity)] {
            await rejects { try await SongExporter.export(source: source, offset: offset, duration: duration, mode: .hardCut, to: target) }
            check(try Data(contentsOf: target) == sentinel, "ungültiger Bereich hat Ziel verändert")
        }
        let unreadable = root.appendingPathComponent("bad.mp3")
        try Data("keine Audiodatei".utf8).write(to: unreadable)
        await rejects { try await SongExporter.export(source: unreadable, offset: 0, duration: 5, mode: .hardCut, to: target) }
        check(try Data(contentsOf: target) == sentinel, "unlesbare Quelle hat Ziel verändert")

        let cancelled = Task { try await SongExporter.export(source: source, offset: 0, duration: 5, mode: .hardCut, to: target) }
        cancelled.cancel()
        do { try await cancelled.value; check(false, "abgebrochener Task exportierte trotzdem") }
        catch is CancellationError {}
        check(try Data(contentsOf: target) == sentinel, "Abbruch hat vorhandenes Ziel verändert")

        for mode in [SongExporter.Mode.hardCut, .faded] {
            try await SongExporter.export(source: source, offset: 2, duration: 60, mode: mode, to: target)
            let truncated = try decode(target, duration: 10)
            if mode == .faded {
                check(rms(truncated.suffix(2400)) < rms(truncated[120_000..<122_400]) * 0.3,
                      "Ausblendung liegt hinter dem tatsächlichen Audioende")
            }
            try await SongExporter.export(source: source, offset: 2, duration: 5, mode: mode, to: target)
            let values = try decode(target, duration: 5)
            if mode == .faded {
                let middle = rms(values[(values.count / 2)..<(values.count / 2 + 2400)])
                print("Fade RMS: start=\(rms(values.prefix(2400))) middle=\(middle) end=\(rms(values.suffix(2400)))")
                check(rms(values.prefix(2400)) < middle * 0.3, "Einblendung fehlt")
                check(rms(values.suffix(2400)) < middle * 0.3, "Ausblendung fehlt")
            }
        }
        // Nach Start der Medienarbeit abbrechen, nicht nur vor Eintritt ins export().
        let longSource = root.appendingPathComponent("long.wav")
        try makeTone(longSource, seconds: 300)
        let beforeCancellation = try Data(contentsOf: target)
        let active = Task { try await SongExporter.export(source: longSource, offset: 0, duration: 299, mode: .faded, to: target) }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !(try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".mucke-export-") }) {
            check(Date() < deadline, "aktiver Export begann nicht")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        active.cancel()
        do { try await active.value; check(false, "laufender Export ignorierte Abbruch") }
        catch is CancellationError {}
        check(try Data(contentsOf: target) == beforeCancellation, "aktiver Abbruch hat Ziel überschrieben")
        check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".mucke-export-") }, "Staging-Datei blieb liegen")

        // Fehler beim atomaren Übernehmen muss fertige Staging-Datei ebenfalls entfernen.
        let directoryTarget = root.appendingPathComponent("directory.m4a")
        try fm.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        await rejects { try await SongExporter.export(source: source, offset: 0, duration: 5, mode: .hardCut, to: directoryTarget) }
        check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".mucke-export-") }, "Staging nach Zielfehler blieb liegen")

        for name in ["", "../.hidden/evil:\0", " .", String(repeating: "X", count: 1000), "日本語"] {
            let safe = SongExporter.safeFileBase(name)
            check(!safe.isEmpty && !safe.hasPrefix(".") && !safe.contains("/") && !safe.contains(":"), "unsicherer Titel")
            check(safe.utf8.count <= 180 && !safe.contains("\0"), "ungültiger Dateiname")
        }
        let first = try await SongExporter.exportTemporary(source: source, offset: 0, duration: 5, name: "../Song")
        let second = try await SongExporter.exportTemporary(source: source, offset: 0, duration: 5, name: "../Song")
        check(first != second, "Drag-Exporte kollidieren")
        _ = try decode(first, duration: 5)
        _ = try decode(second, duration: 5)
        let tempRoot = first.deletingLastPathComponent().deletingLastPathComponent()
        let children = try fm.contentsOfDirectory(atPath: tempRoot.path)
        await rejects { _ = try await SongExporter.exportTemporary(source: unreadable, offset: 0, duration: 5, name: "failure") }
        check(try fm.contentsOfDirectory(atPath: tempRoot.path).sorted() == children.sorted(), "fehlgeschlagener Drag hinterließ Temp-Verzeichnis")
        SongExporter.cleanupTemporaryExports()
        check(!fm.fileExists(atPath: tempRoot.path), "Drag-Dateien blieben nach Cleanup liegen")
        check(try Data(contentsOf: source) == original, "Quelle nach Export verändert")

        if let fixturePath = ProcessInfo.processInfo.environment["MUCKE_AUDIO_FIXTURES"] {
            let fixtures = URL(fileURLWithPath: fixturePath)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CompleteMP3Protocol.self]
            let reader = ICYMetadataReader(configuration: config)
            let full = Recorder(directory: root.appendingPathComponent("fast-mp3"), minimumFreeBytes: -1)
            let finished = DispatchSemaphore(value: 0)
            reader.start(url: fixtures.appendingPathComponent("tone.mp3"), allowAudioOnly: true,
                onStart: { full.begin(station: "Fixture", contentType: $0, at: $1) },
                onAudio: { full.write($0) },
                onCompletion: { full.end(at: $0); finished.signal() })
            let didFinish = await Task.detached { waitForRecording(finished) }.value
            check(didFinish, "Gebündelte MP3-Fixture endet nicht")
            full.flush()
            let fullClip = full.snapshot()[0]
            check(abs(fullClip.end!.timeIntervalSince(fullClip.start) - 12) < 0.15, "Aufnahmeende folgt Empfang statt zwölf Sekunden Audio")
            let entry = SongEntry(station: "Fixture", raw: "Complete song", start: fullClip.start,
                                  end: fullClip.start.addingTimeInterval(12))
            guard let export = full.exportSource(for: entry) else { check(false, "Gebündelte Aufnahme nicht exportierbar"); return }
            check(try Data(contentsOf: export.url) == Data(contentsOf: fixtures.appendingPathComponent("tone.mp3")), "Gebündelte Aufnahme verändert")
            try await SongExporter.export(source: export.url, offset: export.offset, duration: export.duration, mode: .hardCut, to: target)
            _ = try decode(target, duration: 12)
            reader.stop()
            print("ExportHarness: ICY-MP3 in einem Callback, zwölf Sekunden exportiert")
            for ext in ["mp3", "aac", "ogg", "opus"] {
                let input = fixtures.appendingPathComponent("tone." + ext)
                let bytes = try Data(contentsOf: input)
                let recordingDirectory = root.appendingPathComponent("recording-" + ext)
                let recorder = Recorder(directory: recordingDirectory, minimumFreeBytes: -1)
                recorder.begin(station: "../Fixture:\0", contentType: ["mp3": "audio/mpeg", "aac": "audio/aac", "ogg": "audio/ogg", "opus": "audio/opus"][ext])
                for position in stride(from: 0, to: bytes.count, by: 137) {
                    recorder.write(bytes.subdata(in: position..<min(position + 137, bytes.count)))
                }
                recorder.end(); recorder.flush()
                let clip = recorder.snapshot().first!
                let recording = recordingDirectory.appendingPathComponent(clip.file)
                check(clip.ext == ext && clip.end != nil, "Codec/Abschluss im Recorder falsch")
                check(try Data(contentsOf: recording) == bytes, "Recorder veränderte Audio")
                for mode in [SongExporter.Mode.hardCut, .faded] {
                    try await SongExporter.export(source: recording, offset: 2, duration: 5, mode: mode, to: target)
                    _ = try decode(target, duration: 5)
                    if let evidencePath = ProcessInfo.processInfo.environment["MUCKE_EXPORT_EVIDENCE"] {
                        let file = "export-\(ext)-\(mode == .faded ? "faded" : "hard").m4a"
                        try fm.copyItem(at: target, to: URL(fileURLWithPath: evidencePath).appendingPathComponent(file))
                    }
                }
                check(try Data(contentsOf: input) == bytes, "\(ext)-Quelle verändert")
                print("ExportHarness: \(ext) hardCut/faded decodiert")
            }
        } else {
            print("ExportHarness: Codecfixtures nicht gesetzt; PCM-Kernfälle geprüft")
        }
        print("ExportHarness: OK")
    }
}

private final class CompleteMP3Protocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "audio/mpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! Data(contentsOf: request.url!))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

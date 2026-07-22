import Foundation

@main
enum ReviewHarness {
    static func main() throws {
        try testRecordingDeletionInTemporaryDirectory()
        testURLPolicyAndIdentity()
        testLatestRequestWins()
        testPreviewSwitchDoesNotStopReplacement()
        print("ReviewHarness: OK")
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func testRecordingDeletionInTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuckeBaby-Review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder(directory: directory, minimumFreeBytes: 0)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.begin(station: "Test", contentType: "audio/mpeg", at: start)
        recorder.write(Data([0x01, 0x02, 0x03]))
        recorder.end(at: start.addingTimeInterval(10))
        recorder.flush()

        let completed = recorder.snapshot()
        check(completed.count == 1 && completed[0].end != nil,
              "abgeschlossene Testaufnahme fehlt")
        let completedURL = directory.appendingPathComponent(completed[0].file)
        check(FileManager.default.fileExists(atPath: completedURL.path),
              "Testaufnahme wurde nicht angelegt")

        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().isEmpty, "abgeschlossene Aufnahme blieb im Index")
        check(!FileManager.default.fileExists(atPath: completedURL.path),
              "abgeschlossene Aufnahme blieb auf dem Datentraeger")

        recorder.begin(station: "Laufend", contentType: "audio/aac", at: start)
        recorder.write(Data([0x04]))
        recorder.flush()
        let active = recorder.snapshot()
        check(active.count == 1 && active[0].end == nil,
              "laufende Testaufnahme fehlt")
        let activeURL = directory.appendingPathComponent(active[0].file)

        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().count == 1 && recorder.snapshot()[0].end == nil,
              "laufende Aufnahme wurde aus dem Index geloescht")
        check(FileManager.default.fileExists(atPath: activeURL.path),
              "laufende Aufnahme-Datei wurde geloescht")
        recorder.end(at: start.addingTimeInterval(10))
        recorder.flush()
    }

    private static func testURLPolicyAndIdentity() {
        check(StreamURLPolicy.validatedURL("https://Example.COM/Stream?Token=AbC") != nil,
              "gueltige HTTPS-URL abgewiesen")
        check(StreamURLPolicy.validatedURL("http://example.com:80/")?.absoluteString
              == "http://example.com/", "HTTP-Defaultport nicht kanonisiert")
        for invalid in ["file:///etc/passwd", "ftp://example.com/a", "javascript:alert(1)",
                        "https:///ohne-host", "example.com/ohne-schema"] {
            check(StreamURLPolicy.validatedURL(invalid) == nil,
                  "unsichere URL akzeptiert: \(invalid)")
        }

        check(PlaylistResolver.firstMediaURL(in: "[playlist]\nFile1=file:///etc/passwd") == nil,
              "Playlist liess lokales Ziel durch")
        check(PlaylistResolver.firstMediaURL(
            in: "[playlist]\nFile1=https://Example.COM/Stream?Token=AbC"
        )?.absoluteString == "https://example.com/Stream?Token=AbC",
        "Playlist veraenderte case-sensitiven Pfad oder Query")

        check(StationURLIdentity("HTTPS://Example.COM/Stream?Token=AbC")
              == StationURLIdentity("https://example.com:443/Stream?Token=AbC"),
              "Schema-/Host-Case oder Defaultport erzeugt falsche Dublette")
        check(StationURLIdentity("https://example.com/Stream")
              != StationURLIdentity("https://example.com/stream"),
              "Pfad wurde faelschlich casefolded")
        check(StationURLIdentity("https://example.com/a?Token=AbC")
              != StationURLIdentity("https://example.com/a?token=AbC"),
              "Query wurde faelschlich casefolded")
        check(StationURLIdentity("http://example.com/a")
              != StationURLIdentity("https://example.com/a"),
              "verschiedene Schemas wurden zusammengelegt")
    }

    private static func testLatestRequestWins() {
        var requests = LatestRequestGeneration()
        let first = requests.begin()
        let second = requests.begin()
        check(!requests.accepts(first), "alter Request blieb schreibberechtigt")
        check(requests.accepts(second), "neuester Request wurde abgewiesen")
        requests.invalidate()
        check(!requests.accepts(second), "abgebrochener Request blieb schreibberechtigt")
    }

    private static func testPreviewSwitchDoesNotStopReplacement() {
        var preview = PreviewSwitchCoordinator()
        guard case let .replace(first) = preview.toggle(stationID: "A") else {
            check(false, "erste Vorschau war kein Replace")
            return
        }
        guard case let .replace(second) = preview.toggle(stationID: "B") else {
            check(false, "Wechsel A -> B loeste Stop statt Replace aus")
            return
        }
        check(!preview.accepts(first, stationID: "A"), "spaete A-Antwort blieb gueltig")
        check(preview.accepts(second, stationID: "B"), "aktuelle B-Antwort wurde abgewiesen")
        guard case .stop = preview.toggle(stationID: "B") else {
            check(false, "zweiter Klick auf B stoppte die Vorschau nicht")
            return
        }
    }
}

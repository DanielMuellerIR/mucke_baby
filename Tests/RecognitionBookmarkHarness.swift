import Foundation

@main enum RecognitionBookmarkHarness {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-RecognitionBookmarks-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_790_000_000.125)
        let station = Station(name: "Eigener Sender — 東京", url: "https://radio.example.org/live", favorite: true)
        let raw = "DJ - Grüße (Rare Live Remix)"
        let track = RecognizedTrack(title: "Grüße", artist: "Björk", shazamID: "123", appleMusicURL: URL(string: "https://music.apple.com/de/song/123"))!
        let result = RecognitionResult(track: track, context: RecognitionContext(generation: 7, stationID: station.id, title: raw), capturedAt: date,
                                       recognizedAt: date.addingTimeInterval(12))
        let song = result.song(station: station.name)
        check(song.raw == raw && song.artist == "Björk" && song.title == "Grüße", "Vorschlag verliert Original oder Katalogtitel")
        check(song.recognition?.source == "shazam" && song.recognition?.stationID == station.id
              && song.recognition?.recognizedAt == date.addingTimeInterval(12) && song.recognition?.originalICY == raw,
              "Herkunft oder Zeitpunkt fehlt")

        let store = BookmarkStore(directory: root.appendingPathComponent("normal"))
        let legacy = SongEntry(station: "Alter eigener Name", raw: "Björk - Grüße", artist: "Björk", title: "Grüße", start: date)
        try store.add(legacy, at: date)
        let legacyEntry = store.entries[0]
        let legacyData = try Data(contentsOf: store.fileURL)
        try check(try version(legacyData) == 1, "Altdaten werden unnötig hochgestuft")
        let id = try store.add(song, at: date)
        check(store.entries.count == 2 && store.entries[0] == legacyEntry, "Katalogvorschlag ersetzt vorhandenen Eintrag")
        var repeated = song; repeated.station = "Späterer Sendername"; repeated.start = date.addingTimeInterval(200)
        try check(try store.add(repeated) == id && store.entries.count == 2, "Mehrfachklick erzeugt Dubletten")
        check(store.entries[1].station == station.name && store.entries[1].heardAt == date, "Doppeltes Merken überschreibt erste Quelle")
        let otherResult = RecognitionResult(track: track, context: RecognitionContext(generation: 8, stationID: station.id, title: "DJ - Grüße (Club Mix)"), capturedAt: date, recognizedAt: date.addingTimeInterval(12))
        let otherMix = otherResult.song(station: station.name)
        let otherID = try store.add(otherMix, at: date)
        check(id != otherID && store.entries.count == 3, "Gleicher Katalogtitel verschmilzt unterschiedliche Radio-Mixe")
        let persisted = try Data(contentsOf: store.fileURL)
        try check(try version(persisted) == 2, "Herkunft kann von alten Schreibern unbemerkt entfernt werden")
        check(BookmarkStore(directory: store.fileURL.deletingLastPathComponent()).entries == store.entries, "Neustart verliert Herkunft")
        try store.toggle(song)
        check(!store.contains(song) && store.contains(otherMix) && store.contains(legacy), "Entfernen verwechselt Radio-Mix oder Altbestand")
        try store.add(song, at: date)

        let listening = RecognitionListeningContext(outputID: UUID(), revision: 42, position: 12.345,
            receivedAt: date.addingTimeInterval(-80))
        let buffered = RecognitionResult(track: track,
            context: RecognitionContext(generation: 42, stationID: station.id, title: "DJ - Grüße (Buffered Mix)", listening: listening),
            capturedAt: date, recognizedAt: date.addingTimeInterval(12)).song(station: station.name)
        try store.add(buffered, at: date)
        try check(try version(Data(contentsOf: store.fileURL)) == 3, "Hörkontext fehlt Versionsschutz")
        let reloaded = BookmarkStore(directory: store.fileURL.deletingLastPathComponent())
        check(reloaded.entries == store.entries && reloaded.entries.last?.heardAt == date
              && reloaded.entries.last?.recognition?.listening == listening,
              "Persistenz verliert Hörzeit, Ausgabegeneration oder Pufferempfang")
        let bufferedLibrary = ExchangeLibrary(stations: [station], groups: [], bookmarks: reloaded.entries)
        let bufferedData = try ExchangeCodec.encode(bufferedLibrary, at: date)
        try check(try version(bufferedData) == 3 && ExchangeCodec.decode(bufferedData) == bufferedLibrary,
                  "V3-Roundtrip verliert Hörkontext")
        var downgraded = try JSONSerialization.jsonObject(with: bufferedData) as! [String: Any]
        downgraded["formatVersion"] = 2
        do { _ = try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: downgraded)); fatalError("V2 akzeptiert Hörkontext") }
        catch {}
        let bufferedIndex = bufferedLibrary.bookmarks.firstIndex { $0.recognition?.listening != nil }!
        for invalid: [String: Any] in [
            ["outputID": listening.outputID.uuidString, "revision": 42, "position": -1, "receivedAt": "2026-10-19T00:00:00Z"],
            ["outputID": listening.outputID.uuidString, "revision": 42, "position": 12],
            ["outputID": "invalid", "revision": 42]
        ] {
            var damaged = try JSONSerialization.jsonObject(with: bufferedData) as! [String: Any]
            var entries = damaged["bookmarks"] as! [[String: Any]]
            var provenance = entries[bufferedIndex]["recognition"] as! [String: Any]
            provenance["listening"] = invalid; entries[bufferedIndex]["recognition"] = provenance; damaged["bookmarks"] = entries
            do { _ = try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: damaged)); fatalError("Ungültiger Hörkontext akzeptiert") }
            catch {}
        }
        try store.toggle(buffered)

        let titleless = RecognitionResult(track: track, context: RecognitionContext(generation: 9, stationID: station.id, title: ""), capturedAt: date, recognizedAt: date.addingTimeInterval(12)).song(station: station.name)
        try store.add(titleless, at: date)
        check(titleless.raw == "Björk - Grüße" && titleless.recognition?.originalICY == "", "Titelloser Sender erhält erfundenen Originaltext")
        check(BookmarkStore(directory: store.fileURL.deletingLastPathComponent()).contains(titleless), "Titelloser Katalogtreffer nicht persistent")
        let oldDirectory = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try legacyData.write(to: oldDirectory.appendingPathComponent("bookmarks.json"))
        let oldStore = BookmarkStore(directory: oldDirectory)
        check(oldStore.entries == [legacyEntry] && oldStore.entries[0].recognition == nil, "V1-Migration verändert eigene Metadaten")
        try check(try Data(contentsOf: oldStore.fileURL) == legacyData, "Lesen schreibt Altdaten um")

        let longTrack = RecognizedTrack(title: String(repeating: "👩🏽‍💻", count: 300), artist: String(repeating: "👨‍👩‍👧‍👦", count: 300),
                                        shazamID: String(repeating: "東京", count: 100), appleMusicURL: nil)!
        check(longTrack.title.utf8.count <= 1024 && longTrack.artist.utf8.count <= 1024
              && longTrack.shazamID!.utf8.count <= 256, "Katalogmetadaten passen nicht in portable UTF-8-Grenzen")
        try store.add(RecognitionResult(track: longTrack, context: result.context, capturedAt: date,
                                        recognizedAt: date.addingTimeInterval(12)).song(station: station.name))
        let group = StationGroup(name: "Eigene Gruppe — 東京", stationIDs: [station.id])
        let library = ExchangeLibrary(stations: [station], groups: [group], bookmarks: store.entries)
        let exchange = try ExchangeCodec.encode(library, at: date)
        try check(try version(exchange) == 2, "Austausch verliert Versionsschutz")
        try check(try ExchangeCodec.decode(exchange) == library, "Mac-Austausch verliert Herkunft oder Originaltext")
        let same = try ExchangeMergePlan(local: library, incoming: ExchangeCodec.decode(exchange))
        check(same.rows.allSatisfy { $0.state == .unchanged }, "Herkunfts-Roundtrip erzeugt Konflikte")
        check(same.rows.contains { $0.incomingDescription.contains("Shazam") && $0.incomingDescription.contains(raw)
            && $0.incomingDescription.contains("music.apple.com") }, "Importvorschau versteckt Herkunft oder Originaltext")
        let merged = try ExchangeMergePlan(local: ExchangeLibrary(stations: [station], groups: [group], bookmarks: [legacyEntry]), incoming: library).resolved(selections: [:])
        check(merged.bookmarks[0] == legacyEntry && merged.bookmarks.count == library.bookmarks.count, "Import verändert Altbestand oder verliert Mixe")
        try check(try version(ExchangeCodec.encode(ExchangeLibrary(stations: [station], groups: [], bookmarks: [legacyEntry]))) == 1, "V1-Austausch unnötig verändert")
        let object = try JSONSerialization.jsonObject(with: exchange) as! [String: Any]
        func reject(_ mutate: (inout [String: Any]) -> Void) throws {
            var value = object; mutate(&value)
            do { _ = try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: value)); fatalError("Unsichere Herkunft akzeptiert") }
            catch {}
        }
        try reject { $0["formatVersion"] = 1 }
        let recognizedIndex = library.bookmarks.firstIndex { $0.recognition != nil }!
        func provenanceChange(_ key: String, _ value: Any) throws {
            try reject { object in
                var entries = object["bookmarks"] as! [[String: Any]]
                var provenance = entries[recognizedIndex]["recognition"] as! [String: Any]
                provenance[key] = value; entries[recognizedIndex]["recognition"] = provenance; object["bookmarks"] = entries
            }
        }
        for unsafe in ["file:///tmp/track", "http://music.apple.com/song/1", "https://music.apple.com.evil.test/song/1", "https://music.apple.com:444/song/1"] {
            try provenanceChange("appleMusicURL", unsafe)
        }
        var authenticated = URLComponents(string: "https://music.apple.com/song/1")!
        authenticated.user = "fixture-user"
        try provenanceChange("appleMusicURL", authenticated.string!)
        try provenanceChange("source", "unknown")
        try provenanceChange("recognizedAt", "2026-02-30T12:00:00Z")
        try provenanceChange("originalICY", String(repeating: "x", count: 4097))
        try reject { value in
            var entries = value["bookmarks"] as! [[String: Any]]
            entries[recognizedIndex]["title"] = ""; value["bookmarks"] = entries
        }

        let before = store.entries, beforeData = try Data(contentsOf: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        var failureSong = song; failureSong.title = "Neuer Titel"
        do { try store.add(failureSong); fatalError("Schreibfehler wird verschluckt") } catch {}
        check(store.entries == before && store.diskData == beforeData, "Schreibfehler zeigt falschen Erfolg")
        try check(try Data(contentsOf: store.fileURL) == beforeData, "Schreibfehler verändert gespeicherte Daten")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try store.add(failureSong)
        check(store.contains(failureSong), "Speichern nach behobenem Schreibfehler nicht möglich")

        let recognized = store.entries.first { $0.recognition?.originalICY == raw }!
        let bufferedBookmark = SongBookmark(id: UUID(), station: station.name, raw: buffered.raw, artist: buffered.artist,
            title: buffered.title, heardAt: buffered.start, savedAt: date, recognition: buffered.recognition)
        let csv = BookmarkStore.exportData([legacyEntry, recognized, bufferedBookmark], format: .csv)
        if let path = ProcessInfo.processInfo.environment["MUCKE_RECOGNITION_EXPORT_FIXTURE"] {
            try csv.write(to: URL(fileURLWithPath: path))
        }
        let text = String(decoding: BookmarkStore.exportData([recognized], format: .text), as: UTF8.self)
        check(text.contains(raw) && text.contains("source: shazam") && text.contains("Björk – Grüße"), "Textexport verliert Herkunft")
        print("Erkannte Merkeinträge: V1/V2, Herkunft, Mixidentität, Wiederholung, titellose Sender, Schreibfehler und Austausch OK")
    }

    static func version(_ data: Data) throws -> Int {
        (try JSONSerialization.jsonObject(with: data) as! [String: Any])["formatVersion"] as! Int
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
}

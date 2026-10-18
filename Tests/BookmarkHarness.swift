import Foundation

@main
enum BookmarkHarness {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-Bookmarks-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("normal")
        let store = BookmarkStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let song = SongEntry(station: "Jazz Atelier", raw: "Björk - Grüße (Original Mix)",
                             artist: "Björk", title: "Grüße (Original Mix)", start: date, end: date.addingTimeInterval(60))
        let id = try store.add(song, at: date.addingTimeInterval(100))
        check(id != song.id && store.entries.count == 1, "Eigene stabile Bookmark-ID fehlt")
        var duplicate = song
        duplicate.id = UUID(); duplicate.station = "Anderer Sender"
        duplicate.artist = "  BJÖRK "; duplicate.title = "GRÜSSE   (Original Mix)"
        check(try store.add(duplicate) == id, "Dubletten trotz vereinheitlichter Schreibweise")
        check(store.entries[0].station == song.station && store.entries[0].raw == song.raw,
              "Wiederholtes Merken überschreibt die Originalquelle")
        var remix = song; remix.title = "Grüße (Live Mix)"; remix.raw = "Björk - Grüße (Live Mix)"
        try store.add(remix, at: date)
        check(store.entries.count == 2, "Verschiedene Mixe wurden verschmolzen")
        let restored = BookmarkStore(directory: directory)
        check(restored.entries == store.entries, "Neustart verliert IDs oder Metadaten")

        let width = SongEntry(station: "夜のラジオ", raw: "ＦＯＯ - 東京", artist: "ＦＯＯ", title: "東京", start: date)
        let widthID = try store.add(width, at: date)
        var narrow = width; narrow.artist = "foo"
        check(try store.add(narrow) == widthID, "Zeichenbreite erzeugt Dublette")
        let fallback = SongEntry(station: "No split", raw: " Unknown   TITLE ", start: date)
        let fallbackID = try store.add(fallback, at: date)
        var fallback2 = fallback; fallback2.raw = "unknown title"
        check(try store.add(fallback2) == fallbackID, "Rohtext-Fallback erzeugt Dublette")
        var placeholder = song; placeholder.placeholder = true
        expectFailure("Mitschnitt-Platzhalter darf kein gemerkter Song werden") { try store.add(placeholder) }
        var empty = song; empty.raw = " \n "
        expectFailure("Leerer Titel darf nicht gespeichert werden") { try store.add(empty) }

        let history = SongHistory(directory: directory)
        history.note(station: song.station, raw: song.raw, at: date)
        history.closeCurrent(at: date.addingTimeInterval(60))
        history.clear()
        let recorder = Recorder(directory: root.appendingPathComponent("recordings"), minimumFreeBytes: -1)
        recorder.begin(station: "Fixture", contentType: "audio/mpeg", at: date)
        recorder.write(Data(repeating: 1, count: 256))
        recorder.end(at: date.addingTimeInterval(60)); recorder.flush()
        recorder.deleteAllCompleted(); recorder.flush()
        check(history.entries.isEmpty && recorder.snapshot().isEmpty, "Löschfixture wurde nicht geleert")
        check(BookmarkStore(directory: directory).entries == store.entries,
              "Verlauf-/Aufnahmelöschung verändert die Merkliste")
        try store.toggle(song)
        check(!store.contains(song) && store.contains(remix), "Herz-Aus entfernt den falschen Mix")
        try store.remove(id: widthID)
        check(!store.contains(width), "Entfernen über eigene ID funktioniert nicht")

        let blocked = root.appendingPathComponent("blocked")
        let blockedStore = BookmarkStore(directory: blocked)
        try fm.createDirectory(at: blocked.appendingPathComponent("bookmarks.json"), withIntermediateDirectories: false)
        expectFailure("Schreibfehler muss gemeldet werden") { try blockedStore.add(song) }
        check(blockedStore.entries.isEmpty, "Fehlgeschlagenes Schreiben zeigt falschen Erfolg")

        let corrupt = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let damaged = Data("fragment with recoverable title".utf8)
        try damaged.write(to: corrupt.appendingPathComponent("bookmarks.json"))
        let recovered = BookmarkStore(directory: corrupt)
        check(!recovered.isReadOnly && recovered.notice != nil, "Recovery-Zustand fehlt")
        let backups = try fm.contentsOfDirectory(at: corrupt, includingPropertiesForKeys: nil)
        check(try backups.contains { try Data(contentsOf: $0) == damaged }, "Beschädigte Datei nicht unverändert gesichert")
        try recovered.add(song)
        check(BookmarkStore(directory: corrupt).entries.count == 1, "Neue Liste nach Recovery nicht nutzbar")

        let future = root.appendingPathComponent("future")
        try fm.createDirectory(at: future, withIntermediateDirectories: true)
        let futureURL = future.appendingPathComponent("bookmarks.json")
        let futureData = Data("{\"formatVersion\":3,\"futureFields\":[\"do not overwrite\"]}".utf8)
        try futureData.write(to: futureURL)
        let futureStore = BookmarkStore(directory: future)
        check(futureStore.isReadOnly && futureStore.notice != nil, "Unbekannte Version nicht gesperrt")
        expectFailure("Unbekannte Version darf nicht überschrieben werden") { try futureStore.add(song) }
        check(try Data(contentsOf: futureURL) == futureData, "Unbekannte Version verändert")
        check(try fm.contentsOfDirectory(at: future, includingPropertiesForKeys: nil).count == 1,
              "Unbekannte Version fälschlich als beschädigt verschoben")

        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedURL = locked.appendingPathComponent("bookmarks.json")
        try damaged.write(to: lockedURL)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let lockedStore = BookmarkStore(directory: locked)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        check(lockedStore.isReadOnly, "Fehlgeschlagene Sicherung muss Schreiben dauerhaft sperren")
        expectFailure("Fehlgeschlagene Sicherung darf später kein Überschreiben erlauben") { try lockedStore.add(song) }
        check(try Data(contentsOf: lockedURL) == damaged, "Fehlgeschlagene Sicherung verliert Original")

        let unreadable = root.appendingPathComponent("unreadable")
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let unreadableURL = unreadable.appendingPathComponent("bookmarks.json")
        try Data("private bytes".utf8).write(to: unreadableURL)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
        let unreadableStore = BookmarkStore(directory: unreadable)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
        check(unreadableStore.isReadOnly, "Lesefehler muss Schreiben sperren")
        check(try Data(contentsOf: unreadableURL) == Data("private bytes".utf8), "Unlesbare Datei verändert")

        let fileURL = directory.appendingPathComponent("bookmarks.json")
        let beforeExport = try Data(contentsOf: fileURL)
        expectFailure("Export darf Persistenz nicht ersetzen") { try store.export(store.entries, format: .csv, to: fileURL) }
        let symlink = root.appendingPathComponent("alias.csv")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: fileURL)
        expectFailure("Export über Symlink darf Persistenz nicht ersetzen") { try store.export(store.entries, format: .text, to: symlink) }
        let hardlink = root.appendingPathComponent("hardlink.csv")
        try fm.linkItem(at: fileURL, to: hardlink)
        expectFailure("Export über Hardlink darf Persistenz nicht ersetzen") { try store.export(store.entries, format: .csv, to: hardlink) }
        check(try Data(contentsOf: fileURL) == beforeExport, "Export hat Persistenz verändert")
        let csvSong = SongEntry(station: " =HYPERLINK(\"bad\")", raw: "東京, \"Live\"\r\nGrüße",
                                artist: "Björk", title: "@Formula", start: date)
        try store.add(csvSong, at: date)
        let fixture = store.entries.last!
        let csv = root.appendingPathComponent("export.csv")
        try store.export([fixture], format: .csv, to: csv)
        if let fixturePath = ProcessInfo.processInfo.environment["MUCKE_BOOKMARK_EXPORT_FIXTURE"] {
            try Data(contentsOf: csv).write(to: URL(fileURLWithPath: fixturePath))
        }
        let text = String(decoding: BookmarkStore.exportData([fixture], format: .text), as: UTF8.self)
        check(text.contains(csvSong.raw) && text.contains(csvSong.station), "Textexport verliert Unicode oder Rohtext")
        print("BookmarkHarness: Persistenz, Identität, Datenunabhängigkeit, Recovery, Schreibfehler und Export OK")
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func expectFailure<T>(_ message: String, _ action: () throws -> T) {
        do { _ = try action() }
        catch { return }
        fatalError(message)
    }
}

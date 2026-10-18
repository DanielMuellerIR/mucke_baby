import Foundation

@main
enum LibraryExchangeHarness {
    enum Failure: Error { case injected }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeExchangeStores-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"); try Data("[]".utf8).write(to: seed)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for bookmarkFirst in [false, true] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            let store = Store(directory: directory, seedURL: seed), bookmarks = BookmarkStore(directory: directory)
            for seeded in store.stations { _ = store.delete(seeded) }
            let local = Station(name: "My station", url: "https://radio.example.org/local", favorite: true)
            try store.add(local); try store.saveGroup(name: "My group"); let group = store.groups[0]
            try store.update(local, groupIDs: [group.id]); try store.setQuickSlot(0, stationID: local.id)
            let song = SongEntry(station: local.name, raw: "Artist - Title", start: date)
            try bookmarks.add(song, at: date)
            let sentinel = directory.appendingPathComponent("verlauf.json"); try Data("history sentinel".utf8).write(to: sentinel)
            let beforeStations = try Data(contentsOf: store.stationsURL), beforeBookmarks = try Data(contentsOf: bookmarks.fileURL)
            let before = LibraryExchange.snapshot(store: store, bookmarks: bookmarks)
            var incomingStation = local; incomingStation.name = "Imported station"; incomingStation.favorite = false
            let newStation = Station(name: "New station", url: "https://radio.example.org/new", radioBrowserID: UUID())
            let newBookmark = SongBookmark(id: UUID(), station: "Other", raw: "Other - Song", artist: "Other", title: "Song", heardAt: date, savedAt: date)
            let incoming = ExchangeLibrary(stations: [incomingStation, newStation], groups: [], bookmarks: [newBookmark])
            let bytes = try ExchangeCodec.encode(incoming)
            let request = try LibraryExchange.prepare(bytes, store: store, bookmarks: bookmarks)
            try check(Data(contentsOf: store.stationsURL) == beforeStations && Data(contentsOf: bookmarks.fileURL) == beforeBookmarks,
                      "Vorbereitung/Abbruch verändert Dateien")
            check(LibraryExchange.snapshot(store: store, bookmarks: bookmarks) == before, "Vorschau verändert Oberfläche")
            expectFailure("Fehler vor Commit wurde als Erfolg gemeldet") {
                try LibraryExchange.apply(request, choices: [:], store: store, bookmarks: bookmarks) { phase in
                    if phase == .beforeCommit { throw Failure.injected }
                }
            }
            try check(Data(contentsOf: store.stationsURL) == beforeStations && Data(contentsOf: bookmarks.fileURL) == beforeBookmarks,
                      "Fehlgeschlagene Speicherung verändert Bestand")
            check(LibraryExchange.snapshot(store: store, bookmarks: bookmarks) == before, "Fehlgeschlagene Speicherung publiziert neue Daten")
            try fm.setAttributes([.immutable: true], ofItemAtPath: bookmarks.fileURL.path)
            expectFailure("Erkennbarer Dateischreibschutz muss vor Commit scheitern") { try LibraryExchange.apply(request, choices: [:], store: store, bookmarks: bookmarks) }
            try fm.setAttributes([.immutable: false], ofItemAtPath: bookmarks.fileURL.path)
            try check(Data(contentsOf: store.stationsURL) == beforeStations && Data(contentsOf: bookmarks.fileURL) == beforeBookmarks,
                      "Dateischreibschutz verändert Bestand")
            let notice = try LibraryExchange.apply(request, choices: [:], store: store, bookmarks: bookmarks) { phase in
                if phase == .afterCommit { throw Failure.injected }
            }
            check(notice != nil && store.isReadOnly && bookmarks.isReadOnly, "Gewonnener Commit ohne Dateiabschluss nicht geschützt")
            check(store.stations == [local, newStation] && bookmarks.entries.count == 2 && store.quickSlots[0] == local.id,
                  "Gespeicherter Journalbestand nicht vollständig sichtbar oder Schnellplatz verändert")
            try check(Data(contentsOf: store.stationsURL) == beforeStations && Data(contentsOf: bookmarks.fileURL) == beforeBookmarks,
                      "Unterbrechungsfixture schrieb schon kanonische Dateien")
            expectFailure("Normaler Sender-Writer überschreibt offenen Import") { try store.add(newStation) }
            expectFailure("Normaler Bookmark-Writer überschreibt offenen Import") { try bookmarks.add(song) }
            let restoredStore: Store, restoredBookmarks: BookmarkStore
            if bookmarkFirst {
                restoredBookmarks = BookmarkStore(directory: directory); restoredStore = Store(directory: directory, seedURL: seed)
            } else {
                restoredStore = Store(directory: directory, seedURL: seed); restoredBookmarks = BookmarkStore(directory: directory)
            }
            check(restoredStore.stations == store.stations && restoredBookmarks.entries == bookmarks.entries,
                  "Neustart/Reihenfolge lädt gemischten Bestand")
            check(!restoredStore.isReadOnly && !restoredBookmarks.isReadOnly && !fm.fileExists(atPath: directory.appendingPathComponent(ExchangeTransaction.journalName).path),
                  "Recovery nicht abgeschlossen")
            try check(Data(contentsOf: sentinel) == Data("history sentinel".utf8), "Import verändert Verlauf")
            let stale = try LibraryExchange.prepare(bytes, store: restoredStore, bookmarks: restoredBookmarks)
            var external = restoredStore.stations; external[0].name = "External edit"
            let externalData = try JSONEncoder().encode(StationCollection(stations: external, groups: restoredStore.groups, quickSlots: restoredStore.quickSlots))
            try externalData.write(to: restoredStore.stationsURL)
            expectFailure("Externe Änderung nach Vorschau überschrieben") { try LibraryExchange.apply(stale, choices: [:], store: restoredStore, bookmarks: restoredBookmarks) }
            try check(Data(contentsOf: restoredStore.stationsURL) == externalData, "Externe Änderung zerstört")
            expectFailure("Schon vor Vorschau geänderte Datei als aktuell übernommen") { _ = try LibraryExchange.prepare(bytes, store: restoredStore, bookmarks: restoredBookmarks) }
        }
        let damaged = root.appendingPathComponent("damaged"); try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        let journal = damaged.appendingPathComponent(ExchangeTransaction.journalName), sentinel = Data("broken journal".utf8)
        try sentinel.write(to: journal)
        let protectedStore = Store(directory: damaged, seedURL: seed), protectedBookmarks = BookmarkStore(directory: damaged)
        check(protectedStore.isReadOnly && protectedBookmarks.isReadOnly, "Beschädigtes Journal erlaubt Neubefüllung")
        try check(Data(contentsOf: journal) == sentinel && fm.contentsOfDirectory(atPath: damaged.path).count == 1,
                  "Journal beschädigt, verschoben oder durch Seeds ergänzt")
        let exportDirectory = root.appendingPathComponent("protected"); try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let protectedFile = exportDirectory.appendingPathComponent("stations.json"); try Data("keep".utf8).write(to: protectedFile)
        let alias = root.appendingPathComponent("alias.json"); try fm.linkItem(at: protectedFile, to: alias)
        expectFailure("Export überschreibt Datenalias") { try LibraryExchange.writeExport(Data("replace".utf8), to: alias, protectedDirectories: [exportDirectory]) }
        expectFailure("Export schreibt in Datenordner") { try LibraryExchange.writeExport(Data(), to: exportDirectory.appendingPathComponent("new.json"), protectedDirectories: [exportDirectory]) }
        let output = root.appendingPathComponent("portable.json")
        try LibraryExchange.writeExport(Data("portable".utf8), to: output, protectedDirectories: [exportDirectory])
        try check(Data(contentsOf: protectedFile) == Data("keep".utf8) && Data(contentsOf: output) == Data("portable".utf8), "Exportziel/Schutz fehlerhaft")
        print("LibraryExchange: beide Stores, Abbruch, Commitgrenze, Neustartreihenfolge, Schreibschutz und Exportgrenzen OK")
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }
}

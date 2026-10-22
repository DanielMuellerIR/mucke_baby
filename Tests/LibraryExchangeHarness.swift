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
        for (version, bookmarkFirst) in (1...3).flatMap({ version in [false, true].map { (version, $0) } }) {
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
            let listening = RecognitionListeningContext(outputID: UUID(), revision: 42, position: 12.345,
                                                        receivedAt: date.addingTimeInterval(-80))
            let recognition = version == 1 ? nil : SongRecognition(recognizedAt: date.addingTimeInterval(12),
                stationID: newStation.id, originalICY: "Other - Song (Radio Mix)", shazamID: "fixture", appleMusicURL: nil,
                listening: version == 3 ? listening : nil)
            let newBookmark = SongBookmark(id: UUID(), station: "Other", raw: "Other - Song", artist: "Other", title: "Song",
                                           heardAt: date, savedAt: date, recognition: recognition)
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
            let persisted = try ExchangeCodec.dateDecoder().decode(BookmarkDocument.self, from: Data(contentsOf: bookmarks.fileURL))
            check(persisted.formatVersion == version && persisted.entries.last == newBookmark,
                  "Recovery verliert Erkennungsherkunft oder Hörkontext in V\(version)")
            for invalidVersion in [0, 4] + (version > 1 ? Array(1..<version) : []) {
                var invalid = try JSONSerialization.jsonObject(with: Data(contentsOf: bookmarks.fileURL)) as! [String: Any]
                invalid["formatVersion"] = invalidVersion
                let invalidData = try JSONSerialization.data(withJSONObject: invalid)
                expectFailure("Transaktionsvalidator akzeptiert unbekannte Version oder herabgestufte Herkunft") {
                    try LibraryExchangeStorage.validate(name: "bookmarks.json", data: invalidData)
                }
            }
            let stationOnly = Station(name: "Station-only import", url: "https://radio.example.org/station-only")
            let stationBytes = try ExchangeCodec.encode(ExchangeLibrary(stations: [stationOnly], groups: [], bookmarks: []))
            let stationRequest = try LibraryExchange.prepare(stationBytes, store: restoredStore, bookmarks: restoredBookmarks)
            try check(LibraryExchange.apply(stationRequest, choices: [:], store: restoredStore, bookmarks: restoredBookmarks) == nil,
                      "Senderimport mit bestehender V\(version)-Merkliste bleibt offen")
            check(Store(directory: directory, seedURL: seed).stations == restoredStore.stations
                  && restoredStore.stations.contains(stationOnly)
                  && BookmarkStore(directory: directory).entries == persisted.entries,
                  "Senderimport verliert vorhandene V\(version)-Merkungen oder speichert nicht")
            try check(Data(contentsOf: sentinel) == Data("history sentinel".utf8), "Import verändert Verlauf")
            let stale = try LibraryExchange.prepare(bytes, store: restoredStore, bookmarks: restoredBookmarks)
            var external = restoredStore.stations; external[0].name = "External edit"
            let externalData = try JSONEncoder().encode(StationCollection(stations: external, groups: restoredStore.groups, quickSlots: restoredStore.quickSlots))
            try externalData.write(to: restoredStore.stationsURL)
            expectFailure("Externe Änderung nach Vorschau überschrieben") { try LibraryExchange.apply(stale, choices: [:], store: restoredStore, bookmarks: restoredBookmarks) }
            try check(Data(contentsOf: restoredStore.stationsURL) == externalData, "Externe Änderung zerstört")
            expectFailure("Schon vor Vorschau geänderte Datei als aktuell übernommen") { _ = try LibraryExchange.prepare(bytes, store: restoredStore, bookmarks: restoredBookmarks) }
        }
        let legacyDirectory = root.appendingPathComponent("legacy-no-ids")
        try fm.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("stations.json")
        let legacyBytes = Data("[{\"name\":\"Existing legacy name\",\"url\":\"https://radio.example.org/legacy\",\"favorite\":true}]".utf8)
        try legacyBytes.write(to: legacyFile)
        let legacyStore = Store(directory: legacyDirectory, seedURL: seed), legacyBookmarks = BookmarkStore(directory: legacyDirectory)
        let localID = legacyStore.stations[0].id
        let addition = try ExchangeCodec.encode(ExchangeLibrary(stations: [Station(name: "New", url: "https://radio.example.org/addition")], groups: [], bookmarks: []))
        let legacyPreview = try LibraryExchange.prepare(addition, store: legacyStore, bookmarks: legacyBookmarks)
        try check(Data(contentsOf: legacyFile) == legacyBytes, "Legacy-Vorschau schreibt IDs vor Bestätigung")
        try LibraryExchange.apply(legacyPreview, choices: [:], store: legacyStore, bookmarks: legacyBookmarks)
        check(legacyStore.stations[0].id == localID && legacyStore.stations[0].name == "Existing legacy name" && legacyStore.stations[0].favorite,
              "Legacy-Import ersetzt vorhandene lokale Identität oder Favoriten")
        check(Store(directory: legacyDirectory, seedURL: seed).stations == legacyStore.stations, "Bestätigte Legacy-IDs nicht dauerhaft stabil")
        let unsafeDirectory = root.appendingPathComponent("unsafe-local")
        try fm.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
        let unsafeFile = unsafeDirectory.appendingPathComponent("stations.json"), unsafeData = Data("[{\"name\":\"Old local entry\",\"url\":\"file:///old/audio.mp3\"}]".utf8)
        try unsafeData.write(to: unsafeFile)
        let unsafeStore = Store(directory: unsafeDirectory, seedURL: seed), unsafeBookmarks = BookmarkStore(directory: unsafeDirectory)
        do { _ = try LibraryExchange.prepare(addition, store: unsafeStore, bookmarks: unsafeBookmarks); fatalError("Nicht portable Alteinträge still verändert") }
        catch ExchangeFormatError.invalidLocalData {}
        try check(Data(contentsOf: unsafeFile) == unsafeData, "Nicht portable Alteinträge werden beim Austausch umgeschrieben")
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
        print("LibraryExchange: V1/V2/V3, Senderimport mit Erkennungsmerkungen, beide Recovery-Reihenfolgen, Abbruch und Schreibschutz OK")
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }
}

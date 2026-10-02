import Foundation

@main
enum StoreHarness {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuckeBaby-Store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seedURL = root.appendingPathComponent("seed.json")
        try Data("""
        [{"name":"Valid","url":" HTTPS://Example.COM:443/Live?Token=AbC ","favorite":true},
         {"name":"File","url":"file:///tmp/audio.mp3"},
         {"name":"Hostless","url":"https:///"}]
        """.utf8).write(to: seedURL)
        let store = Store(directory: root.appendingPathComponent("stations"), seedURL: seedURL)
        check(store.stations.count == 1, "Seed muss unzulässige URLs aussortieren")
        check(store.stations[0].url == "https://example.com/Live?Token=AbC"
              && store.stations[0].favorite, "Seed muss gültige URLs und Flags erhalten")

        let corruptRoot = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("stations.json")
        let damaged = Data("recoverable station fragment".utf8)
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let oldBackup = corruptRoot.appendingPathComponent("stations.json.broken-\(date)")
        try Data("previous backup".utf8).write(to: oldBackup)
        try damaged.write(to: corruptURL)
        _ = Store(directory: corruptRoot, seedURL: seedURL)
        let backups = try FileManager.default.contentsOfDirectory(at: corruptRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("stations.json.broken-") }
        check(try backups.contains { try Data(contentsOf: $0) == damaged },
              "Defekte Senderdatei wurde bei vorhandener Tagessicherung überschrieben")
        check(try Data(contentsOf: oldBackup) == Data("previous backup".utf8), "Vorherige Sicherung verändert")

        let lockedRoot = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedRoot, withIntermediateDirectories: true)
        let lockedURL = lockedRoot.appendingPathComponent("stations.json")
        try damaged.write(to: lockedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedRoot.path)
        let locked = Store(directory: lockedRoot, seedURL: seedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedRoot.path)
        check(try Data(contentsOf: lockedURL) == damaged, "Fehlgeschlagene Sicherung verlor Original")
        do {
            try locked.add(Station(name: "Unsaved", url: "https://example.com/live"))
            fatalError("Fehlgeschlagene Sicherung erlaubte späteres Überschreiben")
        } catch StationSaveError.persistenceFailed {}

        let unreadableRoot = root.appendingPathComponent("unreadable")
        let unreadableURL = unreadableRoot.appendingPathComponent("stations.json")
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: true)
        let unreadable = Store(directory: unreadableRoot, seedURL: seedURL)
        check(unreadable.stations.isEmpty, "Lesefehler darf keine Ersatzsender veröffentlichen")
        do {
            try unreadable.add(Station(name: "Unsaved", url: "https://example.com/live"))
            fatalError("Ungeklärter Lesefehler erlaubte späteres Überschreiben")
        } catch StationSaveError.persistenceFailed {}

        let invalidURLs = ["file:///tmp/audio.mp3", "ftp://example.com/stream", "https:///", "", "/stream"]
        for raw in invalidURLs {
            let before = try Data(contentsOf: store.stationsURL)
            let snapshot = store.stations
            reject { try store.add(Station(name: "Rejected", url: raw, favorite: true)) }
            var edit = snapshot[0]
            edit.url = raw; edit.name = "Rejected edit"; edit.favorite = false
            reject { try store.update(edit) }
            check(store.stations == snapshot, "Abgewiesene Änderung verändert den Speicher")
            check(try Data(contentsOf: store.stationsURL) == before,
                  "Abgewiesene Änderung verändert die Datei")
            check(!store.addIfNew(name: "Catalog", url: raw), "Katalog lässt unzulässige URL durch")
        }

        let new = Station(name: "New", url: " HTTP://EXAMPLE.com:80/Case?Key=X ")
        try store.add(new)
        var edited = new
        edited.url = "HTTPS://EXAMPLE.COM:443/Changed?Key=Y"
        edited.name = "Edited"
        try store.update(edited)
        check(store.stations.last?.id == new.id
              && store.stations.last?.url == "https://example.com/Changed?Key=Y",
              "add/update müssen gültige URLs normalisieren und Identität erhalten")
        let persisted = try JSONDecoder().decode([Station].self, from: Data(contentsOf: store.stationsURL))
        check(persisted == store.stations, "Akzeptierte Änderungen müssen auf Platte stehen")
        check(store.importData(Data("""
        [{"name":"Duplicate","url":"https://EXAMPLE.com:443/Changed?Key=Y"},
         {"name":"Case-sensitive","url":"https://example.com/changed?Key=Y"},
         {"name":"Unsafe","url":"file:///tmp/audio"}]
        """.utf8)) == 1, "Import muss Dubletten und unzulässige URLs überspringen")
        let imported = store.stations.last!
        check(imported.enabled && !imported.favorite, "Importflags bleiben erhalten")
        let beforeMalformed = try Data(contentsOf: store.stationsURL)
        check(store.importData(Data("not json".utf8)) == -1, "Defekter Import muss Fehler melden")
        check(try Data(contentsOf: store.stationsURL) == beforeMalformed, "Defekter Import verändert Bestände")

        // Bestandsdaten durchlaufen beim Lesen bewusst keine neue URL-Policy.
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = Station(name: "Legacy", url: "file:///old/audio.mp3", favorite: true)
        let legacyURL = legacyRoot.appendingPathComponent("stations.json")
        let legacyData = try JSONEncoder().encode([legacy])
        try legacyData.write(to: legacyURL)
        let old = Store(directory: legacyRoot, seedURL: seedURL)
        check(old.stations == [legacy], "Alt-Sender müssen unverändert lesbar bleiben")
        check(try Data(contentsOf: legacyURL) == legacyData, "Laden schreibt Altbestand um")
        var renamed = legacy
        renamed.name = "Renamed"
        reject { try old.update(renamed) }
        try old.add(Station(name: "Safe addition", url: "https://example.com/new"))
        let reloaded = Store(directory: legacyRoot, seedURL: seedURL)
        check(reloaded.stations.first == legacy, "Speichern anderer Sender verliert Altbestand")
        renamed.url = "https://example.com/fixed"
        try old.update(renamed)
        check(old.stations.first == renamed, "Korrigierter Alt-Sender muss speicherbar sein")

        let snapshot = store.stations
        let beforeFailure = try Data(contentsOf: store.stationsURL)
        let held = root.appendingPathComponent("held-stations")
        try FileManager.default.moveItem(at: store.dir, to: held)
        try Data("blocked".utf8).write(to: store.dir)
        defer {
            try? FileManager.default.removeItem(at: store.dir)
            try? FileManager.default.moveItem(at: held, to: store.dir)
        }
        do {
            try store.add(Station(name: "Unsaved", url: "https://example.com/failure", favorite: true))
            fatalError("Speicherfehler wurde verschluckt")
        } catch StationSaveError.persistenceFailed {}
        var failedEdit = snapshot[0]
        failedEdit.name = "Unsaved edit"
        do {
            try store.update(failedEdit)
            fatalError("Speicherfehler der Bearbeitung wurde verschluckt")
        } catch StationSaveError.persistenceFailed {}
        check(store.stations == snapshot, "Fehlgeschlagene Speicherung verändert Sender/Favoriten")
        check(!store.delete(snapshot[0]), "Löschen meldet trotz Speicherfehler Erfolg")
        store.delete(at: IndexSet(integer: 0), in: snapshot)
        store.move(from: IndexSet(integer: 0), to: snapshot.count)
        store.toggleEnabled(snapshot[0])
        store.setFavorite(snapshot.last!)
        check(!store.addIfNew(name: "Catalog", url: "https://example.com/catalog"),
              "Katalog meldet ungespeicherten Sender als hinzugefügt")
        check(store.importData(Data("[{\"name\":\"Import\",\"url\":\"https://example.com/import\"}]".utf8)) == -2,
              "Import meldet trotz Speicherfehler Erfolg")
        check(store.stations == snapshot && store.persistenceFailed,
              "Fehlgeschlagene Senderaktion verändert Zustand oder meldet keinen Speicherfehler")
        check(try Data(contentsOf: held.appendingPathComponent("stations.json")) == beforeFailure,
              "Fehlgeschlagene Speicherung verändert den Dateibestand")

        let emptyRoot = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: emptyRoot.appendingPathComponent("stations.json"))
        check(Store(directory: emptyRoot, seedURL: seedURL).stations.isEmpty,
              "Gespeicherte leere Liste darf nicht durch Seeds ersetzt werden")
        let fallback = Store(directory: root.appendingPathComponent("fallback"), seedURL: nil)
        check(!fallback.stations.isEmpty && fallback.stations.allSatisfy {
            StreamURLPolicy.validatedURL($0.url) != nil
        }, "Fallback muss gültige Sender enthalten")
        let favoritesURL = root.appendingPathComponent("favorites.json")
        try Data("""
        [{"name":"A","url":"https://example.com/a","favorite":true},
         {"name":"B","url":"https://example.com/b","favorite":true}]
        """.utf8).write(to: favoritesURL)
        let favorites = Store(directory: root.appendingPathComponent("favorites"), seedURL: favoritesURL)
        check(favorites.stations.filter(\.favorite).count == 1 && favorites.favorite?.name == "A",
              "Erstbefüllung muss genau den ersten gültigen Favoriten behalten")
        print("StoreHarness: OK")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    private static func reject(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Unzulässige URL wurde akzeptiert")
        } catch StationSaveError.invalidURL {
        } catch {
            fatalError("Falscher Validierungsfehler: \(error)")
        }
    }
}

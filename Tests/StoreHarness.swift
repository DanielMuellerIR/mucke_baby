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

        let emptyRoot = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: emptyRoot.appendingPathComponent("stations.json"))
        check(Store(directory: emptyRoot, seedURL: seedURL).stations.isEmpty,
              "Gespeicherte leere Liste darf nicht durch Seeds ersetzt werden")
        let fallback = Store(directory: root.appendingPathComponent("fallback"), seedURL: nil)
        check(!fallback.stations.isEmpty && fallback.stations.allSatisfy {
            StreamURLPolicy.validatedURL($0.url) != nil
        }, "Fallback muss gültige Sender enthalten")
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

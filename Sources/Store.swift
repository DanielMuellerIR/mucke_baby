import Foundation
import SwiftUI

// Haelt die Senderliste und kuemmert sich um Laden/Speichern.
// Speicherort: ~/Library/Application Support/MuckeBaby/stations.json
// (gut von Hand editierbar und damit auch agent-/skriptsteuerbar).
@MainActor
final class Store: ObservableObject {
    @Published var stations: [Station] = []

    let dir: URL
    let stationsURL: URL

    init() {
        migrateLegacyAppDir(in: .applicationSupportDirectory)   // alten „MacRadio"-Ordner übernehmen
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("MuckeBaby", isDirectory: true)
        stationsURL = dir.appendingPathComponent("stations.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadStations()
    }

    // Nur sichtbare Sender (fuer die normale Ansicht).
    var enabledStations: [Station] { stations.filter { $0.enabled } }

    // Der Favorit (Autostart). Maximal einer.
    var favorite: Station? { stations.first { $0.favorite } }

    // MARK: - Laden / Speichern

    func loadStations() {
        if let data = try? Data(contentsOf: stationsURL) {
            // Datei vorhanden: Dekodierung versuchen.
            if let list = try? JSONDecoder().decode([Station].self, from: data), !list.isEmpty {
                stations = list
                return
            }
            // Datei vorhanden, aber nicht dekodierbar -> sichern statt ueberschreiben.
            // Format: stations.json.broken-YYYY-MM-DD (ISO 8601, alphabetisch sortierbar).
            let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10) // nur Datum
            let backup = stationsURL.deletingLastPathComponent()
                .appendingPathComponent("stations.json.broken-\(dateStr)")
            // Eventuelle aeltere Sicherung desselben Tages einfach ueberschreiben (try? = ok).
            try? FileManager.default.moveItem(at: stationsURL, to: backup)
        }
        // Keine Datei (oder kaputte Datei gesichert) -> aus Seed neu aufbauen.
        stations = seededStations()
        saveStations()
    }

    func saveStations() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stations) {
            try? data.write(to: stationsURL, options: .atomic)
        }
    }

    // MARK: - Seed (Erstbefuellung)

    // Liest seed-stations.json aus dem App-Bundle. Faellt auf eine
    // generische Default-Liste zurueck (relevant fuer eine spaetere
    // GitHub-Veroeffentlichung ohne persoenliche Sender).
    private func seededStations() -> [Station] {
        if let url = Bundle.main.url(forResource: "seed-stations", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let seeds = try? JSONDecoder().decode([SeedStation].self, from: data),
           !seeds.isEmpty {
            return seeds.map { $0.toStation() }
        }
        return Self.builtinDefaults.map { $0.toStation() }
    }

    // Fallback, falls keine Seed-Datei gebuendelt ist.
    static let builtinDefaults: [SeedStation] = {
        let json = """
        [
          {"name":"Smooth Chill","url":"https://media-ssl.musicradio.com/ChillMP3","favorite":true},
          {"name":"Austrian Rock Radio","url":"http://live.antenne.at/arr"},
          {"name":"Radio BOB","url":"http://live6.infonetmedia.si/Europa05"},
          {"name":"Deep House Radio","url":"http://62.210.105.16:7000/stream"}
        ]
        """
        return (try? JSONDecoder().decode([SeedStation].self, from: Data(json.utf8))) ?? []
    }()

    // MARK: - CRUD

    func add(_ station: Station) {
        stations.append(station)
        saveStations()
    }

    func update(_ station: Station) {
        guard let i = stations.firstIndex(where: { $0.id == station.id }) else { return }
        stations[i] = station
        saveStations()
    }

    func delete(_ station: Station) {
        stations.removeAll { $0.id == station.id }
        saveStations()
    }

    func delete(at offsets: IndexSet, in subset: [Station]) {
        // offsets beziehen sich auf die uebergebene Teilliste -> auf ids mappen.
        let ids = offsets.map { subset[$0].id }
        stations.removeAll { ids.contains($0.id) }
        saveStations()
    }

    func move(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        saveStations()
    }

    func toggleEnabled(_ station: Station) {
        guard let i = stations.firstIndex(where: { $0.id == station.id }) else { return }
        stations[i].enabled.toggle()
        saveStations()
    }

    // Genau einen Favoriten setzen (alle anderen verlieren das Flag).
    func setFavorite(_ station: Station) {
        for i in stations.indices { stations[i].favorite = (stations[i].id == station.id) }
        saveStations()
    }

    // MARK: - Import (kuratierte Genre-Listen, Punkt 1)

    // URL-Schluessel fuer Dubletten: Schema/Host case-insensitiv, Pfad/Query
    // bewusst case-sensitiv. Ungueltige bzw. Nicht-Web-URLs haben keinen Key.
    private func normURL(_ value: String) -> StationURLIdentity? {
        StationURLIdentity(value)
    }

    // Ist ein Sender mit dieser URL (normalisiert) schon in der Liste?
    // Genutzt vom Sender-Katalog fuer das ✓ an bereits uebernommenen Sendern.
    func containsURL(_ url: String) -> Bool {
        guard let key = normURL(url) else { return false }
        return stations.contains { normURL($0.url) == key }
    }

    // Einzelnen Sender uebernehmen, falls seine URL noch nicht in der Liste ist.
    // Rueckgabe: true = neu hinzugefuegt, false = Dublette (nichts passiert).
    @discardableResult
    func addIfNew(name: String, url: String) -> Bool {
        guard let validated = StreamURLPolicy.validatedURL(url),
              !containsURL(validated.absoluteString)
        else { return false }
        stations.append(Station(name: name, url: validated.absoluteString,
                                enabled: true, favorite: false))
        saveStations()
        return true
    }

    // Fuegt nur Sender hinzu, die per (normalisierter) URL noch nicht da sind.
    // Gibt die Zahl der neu hinzugefuegten zurueck.
    @discardableResult
    func importStations(_ seeds: [SeedStation]) -> Int {
        var seen = Set(stations.compactMap { normURL($0.url) })
        var added = 0
        for s in seeds {
            guard let validated = StreamURLPolicy.validatedURL(s.url),
                  let key = normURL(validated.absoluteString)
            else { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            // Importierte Sender nie als Favorit uebernehmen.
            stations.append(Station(name: s.name, url: validated.absoluteString,
                                    enabled: true, favorite: false))
            added += 1
        }
        if added > 0 { saveStations() }
        return added
    }

    // Manifest der gebuendelten Genre-Listen (Resources/genre-lists/manifest.json).
    func availableGenreLists() -> [GenreList] {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json",
                                        subdirectory: "genre-lists"),
              let data = try? Data(contentsOf: url),
              var lists = try? JSONDecoder().decode([GenreList].self, from: data)
        else { return [] }
        // Senderzahl je Liste nachladen (fuer die Anzeige).
        for i in lists.indices { lists[i].count = stations(in: lists[i]).count }
        return lists
    }

    // Sender einer Genre-Liste aus dem Bundle laden.
    func stations(in list: GenreList) -> [SeedStation] {
        let name = (list.file as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: "json",
                                        subdirectory: "genre-lists"),
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([SeedStation].self, from: data)
        else { return [] }
        return seeds
    }

    @discardableResult
    func importGenreList(_ list: GenreList) -> Int {
        importStations(stations(in: list))
    }

    // MARK: - JSON Im-/Export (portabel, ohne interne ids)

    // Aktuelle Senderliste als JSON-Daten (Array aus {name,url,enabled,favorite}).
    func exportData() -> Data? {
        let arr = stations.map {
            PortableStation(name: $0.name, url: $0.url, enabled: $0.enabled, favorite: $0.favorite)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(arr)
    }

    // JSON importieren (tolerant: SeedStation-Format). Fuegt neue Sender hinzu
    // (Dubletten per URL uebersprungen). -1 = Datei nicht lesbar.
    func importData(_ data: Data) -> Int {
        guard let seeds = try? JSONDecoder().decode([SeedStation].self, from: data) else { return -1 }
        return importStations(seeds)
    }
}

// Portables Export-Format (kein interner UUID-Ballast).
struct PortableStation: Codable {
    var name: String
    var url: String
    var enabled: Bool
    var favorite: Bool
}

// Eintrag im Genre-Listen-Manifest.
struct GenreList: Identifiable, Decodable {
    var id: String
    var name: String
    var file: String
    var count: Int? = nil   // zur Laufzeit gefuellt
}

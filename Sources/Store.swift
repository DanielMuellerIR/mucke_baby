import Foundation
import SwiftUI

enum StationSaveError: Error {
    case invalidURL
    case persistenceFailed
    case stationNotFound
    case invalidGroupName
    case stationChanged
}

// Haelt die Senderliste und kuemmert sich um Laden/Speichern.
// Speicherort: ~/Library/Application Support/MuckeBaby/stations.json
// (gut von Hand editierbar und damit auch agent-/skriptsteuerbar).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var stations: [Station] = []
    @Published private(set) var groups: [StationGroup] = []
    @Published private(set) var quickSlots: [UUID?] = Array(repeating: nil, count: 5)
    @Published var persistenceFailed = false
    @Published private(set) var loadNotice: String?

    var persistenceMessage: String {
        loadNotice ?? String(localized: "Die Senderliste konnte nicht gespeichert werden. Bitte den Speicherzugriff prüfen und erneut versuchen.")
    }

    let dir: URL
    let stationsURL: URL
    private let seedURL: URL?
    private var canPersist = false

    init(directory: URL? = nil,
         seedURL: URL? = Bundle.main.url(forResource: "seed-stations", withExtension: "json")) {
        if let directory {
            dir = directory
        } else {
            migrateLegacyAppDir(in: .applicationSupportDirectory)   // alten „MacRadio"-Ordner übernehmen
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("MuckeBaby", isDirectory: true)
        }
        self.seedURL = seedURL
        stationsURL = dir.appendingPathComponent("stations.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadStations()
    }

    // Nur sichtbare Sender (fuer die normale Ansicht).
    var enabledStations: [Station] { stations.filter { $0.enabled } }

    var favorites: [Station] { enabledStations.filter { $0.favorite } }

    // MARK: - Laden / Speichern

    func loadStations() {
        canPersist = false
        loadNotice = nil
        let collection: StationCollection?
        struct Header: Decodable { let formatVersion: Int }
        do {
            if let data = try? Data(contentsOf: stationsURL),
               let header = try? JSONDecoder().decode(Header.self, from: data), header.formatVersion != 2 {
                loadNotice = String(localized: "Die Senderliste stammt aus einer anderen App-Version und bleibt unverändert. Bitte eine passende App-Version verwenden.")
                persistenceFailed = true
                return
            }
            collection = try JSONFileRecovery.load(StationCollection.self, from: stationsURL)
        }
        catch { persistenceFailed = true; return }
        canPersist = true
        if let collection {
            stations = collection.stations; groups = collection.groups; quickSlots = collection.quickSlots
            persistenceFailed = false
        }
        else { _ = attemptCommit(seededStations()) }
    }

    private func commitCollection(_ next: StationCollection) throws {
        guard canPersist else { throw StationSaveError.persistenceFailed }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(next).write(to: stationsURL, options: .atomic)
        } catch {
            throw StationSaveError.persistenceFailed
        }
        stations = next.stations
        groups = next.groups
        quickSlots = next.quickSlots
    }

    private func commitStations(_ next: [Station]) throws {
        let ids = Set(next.map(\.id))
        let keptGroups = groups.map { group in
            var group = group
            group.stationIDs = group.stationIDs.filter { ids.contains($0) }
            return group
        }
        try commitCollection(StationCollection(stations: next, groups: keptGroups, quickSlots: quickSlots))
    }

    private func attemptCommit(_ next: [Station]) -> Bool {
        do {
            try commitStations(next)
            persistenceFailed = false
            return true
        } catch {
            persistenceFailed = true
            return false
        }
    }

    // MARK: - Seed (Erstbefuellung)

    // Liest seed-stations.json aus dem App-Bundle. Faellt auf eine
    // generische Default-Liste zurueck (relevant fuer eine spaetere
    // GitHub-Veroeffentlichung ohne persoenliche Sender).
    private func seededStations() -> [Station] {
        let seeds: [SeedStation]
        if let url = seedURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([SeedStation].self, from: data),
           !decoded.isEmpty {
            seeds = decoded
        } else {
            seeds = Self.builtinDefaults
        }
        return seeds.compactMap { seed in
            try? validatedStation(seed.toStation())
        }
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

    private func validatedStation(_ station: Station) throws -> Station {
        guard let url = StreamURLPolicy.validatedURL(station.url) else {
            throw StationSaveError.invalidURL
        }
        var validated = station
        validated.url = url.absoluteString
        return validated
    }

    func add(_ station: Station, groupIDs: Set<UUID> = []) throws {
        let validated = try validatedStation(station)
        try commitCollection(StationCollection(stations: stations + [validated],
                                               groups: assigning(validated.id, to: groupIDs), quickSlots: quickSlots))
    }

    func update(_ station: Station, groupIDs: Set<UUID>? = nil) throws {
        let validated = try validatedStation(station)
        guard let i = stations.firstIndex(where: { $0.id == station.id }) else {
            throw StationSaveError.stationNotFound
        }
        var next = stations
        next[i] = validated
        try commitCollection(StationCollection(stations: next,
                                               groups: groupIDs.map { assigning(station.id, to: $0) } ?? groups,
                                               quickSlots: quickSlots))
    }

    func applyURLRepair(_ proposal: StationURLRepairProposal) throws {
        guard var station = stations.first(where: { $0.id == proposal.stationID }) else {
            throw StationSaveError.stationNotFound
        }
        guard station.radioBrowserID == proposal.radioBrowserID, station.url == proposal.oldURL else {
            throw StationSaveError.stationChanged
        }
        // Nur die URL aus der Vorschau übernehmen, nie den veralteten Sender-Snapshot.
        station.url = proposal.newURL
        try update(station)
    }

    @discardableResult
    func delete(_ station: Station) -> Bool {
        attemptCommit(stations.filter { $0.id != station.id })
    }

    func delete(at offsets: IndexSet, in subset: [Station]) {
        // offsets beziehen sich auf die uebergebene Teilliste -> auf ids mappen.
        let ids = offsets.map { subset[$0].id }
        _ = attemptCommit(stations.filter { !ids.contains($0.id) })
    }

    func move(from source: IndexSet, to destination: Int) {
        var next = stations
        next.move(fromOffsets: source, toOffset: destination)
        _ = attemptCommit(next)
    }

    func toggleEnabled(_ station: Station) {
        guard let i = stations.firstIndex(where: { $0.id == station.id }) else { return }
        var next = stations
        next[i].enabled.toggle()
        _ = attemptCommit(next)
    }

    func toggleFavorite(_ station: Station) {
        guard let index = stations.firstIndex(where: { $0.id == station.id }) else { return }
        var next = stations
        next[index].favorite.toggle()
        _ = attemptCommit(next)
    }

    private func assigning(_ stationID: UUID, to groupIDs: Set<UUID>) -> [StationGroup] {
        groups.map { group in
            var group = group
            group.stationIDs.removeAll { $0 == stationID }
            if groupIDs.contains(group.id) { group.stationIDs.append(stationID) }
            return group
        }
    }

    func saveGroup(id: UUID? = nil, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(where: {
            $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }) else { throw StationSaveError.invalidGroupName }
        var next = groups
        if let id {
            guard let index = next.firstIndex(where: { $0.id == id }) else { throw StationSaveError.stationNotFound }
            next[index].name = name
        } else { next.append(StationGroup(name: name)) }
        try commitCollection(StationCollection(stations: stations, groups: next, quickSlots: quickSlots))
    }

    func deleteGroup(_ id: UUID) throws {
        try commitCollection(StationCollection(stations: stations, groups: groups.filter { $0.id != id }, quickSlots: quickSlots))
    }

    func moveGroups(from offsets: IndexSet, to destination: Int) throws {
        var next = groups
        next.move(fromOffsets: offsets, toOffset: destination)
        try commitCollection(StationCollection(stations: stations, groups: next, quickSlots: quickSlots))
    }

    func setQuickSlot(_ index: Int, stationID: UUID?) throws {
        guard quickSlots.indices.contains(index) else { return }
        var next = quickSlots
        next[index] = stationID
        try commitCollection(StationCollection(stations: stations, groups: groups, quickSlots: next))
    }

    func quickStation(at index: Int) -> Station? {
        guard quickSlots.indices.contains(index), let id = quickSlots[index] else { return nil }
        return enabledStations.first { $0.id == id && StreamURLPolicy.validatedURL($0.url) != nil }
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
    // true erst nach Speicherung; false bei Dublette, ungültiger URL oder Speicherfehler.
    @discardableResult
    func addIfNew(name: String, url: String, radioBrowserID: UUID? = nil) -> Bool {
        guard let validated = StreamURLPolicy.validatedURL(url),
              !containsURL(validated.absoluteString)
        else { return false }
        return attemptCommit(stations + [Station(name: name, url: validated.absoluteString,
                                                 enabled: true, favorite: false, radioBrowserID: radioBrowserID)])
    }

    // Fuegt nur Sender hinzu, die per (normalisierter) URL noch nicht da sind.
    // Gibt die Zahl der neu hinzugefuegten zurück; -2 bei Speicherfehler.
    @discardableResult
    func importStations(_ seeds: [SeedStation]) -> Int {
        var seen = Set(stations.compactMap { normURL($0.url) })
        var next = stations
        var added = 0
        for s in seeds {
            guard let validated = StreamURLPolicy.validatedURL(s.url),
                  let key = normURL(validated.absoluteString)
            else { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            // Importierte Sender nie als Favorit uebernehmen.
            next.append(Station(name: s.name, url: validated.absoluteString,
                                    enabled: true, favorite: false, radioBrowserID: s.radioBrowserID))
            added += 1
        }
        if added > 0, !attemptCommit(next) { return -2 }
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

    // Portabler Senderexport mit optionaler Katalogherkunft, ohne lokale Sender-IDs.
    func exportData() -> Data? {
        let arr = stations.map {
            PortableStation(name: $0.name, url: $0.url, enabled: $0.enabled, favorite: $0.favorite,
                            radioBrowserID: $0.radioBrowserID)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(arr)
    }

    // JSON importieren (tolerant: SeedStation-Format). Fuegt neue Sender hinzu
    // (Dubletten per URL übersprungen). -1 = Datei nicht lesbar, -2 = Speicherfehler.
    func importData(_ data: Data) -> Int {
        guard let seeds = try? JSONDecoder().decode([SeedStation].self, from: data) else { return -1 }
        return importStations(seeds)
    }
}

// Lokale Sender-IDs bleiben lokal; Katalog-IDs sind auf anderen Geräten nutzbar.
struct PortableStation: Codable {
    var name: String
    var url: String
    var enabled: Bool
    var favorite: Bool
    var radioBrowserID: UUID?
}

// Eintrag im Genre-Listen-Manifest.
struct GenreList: Identifiable, Decodable {
    var id: String
    var name: String
    var file: String
    var count: Int? = nil   // zur Laufzeit gefuellt
}

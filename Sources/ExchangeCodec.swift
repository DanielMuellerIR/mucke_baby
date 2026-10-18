import Foundation

struct ExchangeLibrary: Equatable {
    var stations: [Station]
    var groups: [StationGroup]
    var bookmarks: [SongBookmark]
    var isLegacy = false
}

enum ExchangeFormatError: LocalizedError {
    case unsupportedVersion, invalidData, limitExceeded, invalidURL, duplicateID, missingReference, invalidLocalData
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: String(localized: "Diese Austauschdatei verwendet ein unbekanntes Format oder eine neuere Version.")
        case .invalidData: String(localized: "Die Austauschdatei enthält ungültige oder fehlende Angaben. Es wurde nichts übernommen.")
        case .limitExceeded: String(localized: "Die Austauschdatei überschreitet die zulässige Größe oder Anzahl von Einträgen.")
        case .invalidURL: String(localized: "Die Austauschdatei enthält eine unsichere oder ungültige Stream-URL.")
        case .duplicateID: String(localized: "Die Austauschdatei enthält doppelte IDs. Es wurde nichts übernommen.")
        case .missingReference: String(localized: "Eine importierte Gruppe verweist auf einen fehlenden oder mehrfach zugeordneten Sender.")
        case .invalidLocalData: String(localized: "Die lokale Bibliothek enthält Einträge, die nicht in das Austauschformat passen. Sie bleibt unverändert. Bitte Namen, Senderadressen und Gruppenbezüge prüfen.")
        }
    }
}

enum ExchangeCodec {
    static let format = "mucke-baby-library"
    static let byteLimit = 8 * 1024 * 1024
    static let stationLimit = 2_000
    static let groupLimit = 200
    static let bookmarkLimit = 20_000

    private struct Header: Decodable {
        let format: String?
        let formatVersion: Int
    }
    private struct StationRecord: Codable {
        let id: UUID?
        let name: String
        let url: String
        var enabled = true
        var favorite = false
        let radioBrowserID: UUID?

        init(_ station: Station) {
            id = station.id; name = station.name; url = station.url
            enabled = station.enabled; favorite = station.favorite; radioBrowserID = station.radioBrowserID
        }
        enum CodingKeys: CodingKey { case id, name, url, enabled, favorite, radioBrowserID }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(String.self, forKey: .url)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
            radioBrowserID = try c.decodeIfPresent(UUID.self, forKey: .radioBrowserID)
        }
        func station(requireID: Bool) throws -> Station {
            guard !requireID || id != nil else { throw ExchangeFormatError.invalidData }
            guard ExchangeCodec.validText(name, limit: 256, required: true, multiline: false), url.utf8.count <= 4096 else {
                throw ExchangeFormatError.invalidData
            }
            guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  components.user == nil, components.password == nil,
                  let validated = StreamURLPolicy.validatedURL(url) else { throw ExchangeFormatError.invalidURL }
            return Station(id: id ?? UUID(), name: name, url: validated.absoluteString,
                           enabled: enabled, favorite: favorite, radioBrowserID: radioBrowserID)
        }
    }
    private struct Document: Codable {
        let format: String
        let formatVersion: Int
        let exportedAt: Date
        let stations: [StationRecord]
        let groups: [StationGroup]
        let bookmarks: [SongBookmark]
    }
    private struct LegacyCollection: Decodable {
        let stations: [StationRecord]
        let groups: [StationGroup]?
    }

    static func decode(_ data: Data) throws -> ExchangeLibrary {
        guard data.count <= byteLimit else { throw ExchangeFormatError.limitExceeded }
        do {
            let decoder = dateDecoder()
            if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
                let records = try decoder.decode([StationRecord].self, from: data)
                guard records.count <= stationLimit else { throw ExchangeFormatError.limitExceeded }
                let library = ExchangeLibrary(stations: try records.map { try $0.station(requireID: false) },
                                              groups: [], bookmarks: [], isLegacy: true)
                try validate(library)
                return library
            }
            let header = try decoder.decode(Header.self, from: data)
            if header.format == nil, header.formatVersion == 2 {
                let old = try decoder.decode(LegacyCollection.self, from: data)
                let library = ExchangeLibrary(stations: try old.stations.map { try $0.station(requireID: true) },
                                              groups: old.groups ?? [], bookmarks: [], isLegacy: true)
                try validate(library)
                return library
            }
            guard header.format == format, header.formatVersion == 1 else { throw ExchangeFormatError.unsupportedVersion }
            let document = try decoder.decode(Document.self, from: data)
            let library = ExchangeLibrary(stations: try document.stations.map { try $0.station(requireID: true) },
                                          groups: document.groups, bookmarks: document.bookmarks)
            try validate(library)
            return library
        } catch let error as ExchangeFormatError { throw error }
        catch { throw ExchangeFormatError.invalidData }
    }

    static func encode(_ library: ExchangeLibrary, at date: Date = Date()) throws -> Data {
        try validate(library)
        let encoder = dateEncoder()
        let data = try encoder.encode(Document(format: format, formatVersion: 1, exportedAt: date,
                                               stations: library.stations.map(StationRecord.init),
                                               groups: library.groups, bookmarks: library.bookmarks))
        guard data.count <= byteLimit else { throw ExchangeFormatError.limitExceeded }
        return data
    }

    static func validate(_ library: ExchangeLibrary) throws {
        guard library.stations.count <= stationLimit, library.groups.count <= groupLimit,
              library.bookmarks.count <= bookmarkLimit else { throw ExchangeFormatError.limitExceeded }
        guard Set(library.stations.map(\.id)).count == library.stations.count,
              Set(library.groups.map(\.id)).count == library.groups.count,
              Set(library.bookmarks.map(\.id)).count == library.bookmarks.count else { throw ExchangeFormatError.duplicateID }
        for station in library.stations { _ = try StationRecord(station).station(requireID: true) }
        let ids = Set(library.stations.map(\.id))
        for group in library.groups {
            guard validText(group.name, limit: 256, required: true, multiline: false) else { throw ExchangeFormatError.invalidData }
            guard group.stationIDs.count <= stationLimit, Set(group.stationIDs).count == group.stationIDs.count,
                  group.stationIDs.allSatisfy({ ids.contains($0) }) else { throw ExchangeFormatError.missingReference }
        }
        for entry in library.bookmarks {
            guard validText(entry.raw, limit: 4096, required: true), validText(entry.station, limit: 256),
                  entry.artist.map({ validText($0, limit: 1024) }) ?? true,
                  entry.title.map({ validText($0, limit: 1024) }) ?? true,
                  validDate(entry.heardAt), validDate(entry.savedAt) else { throw ExchangeFormatError.invalidData }
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
    private static func validText(_ text: String, limit: Int, required: Bool = false, multiline: Bool = true) -> Bool {
        text.utf8.count <= limit && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0)
                && (!multiline || ![9, 10, 13].contains($0.value)) }
    }
    static func dateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard validDate(date) else { throw ExchangeFormatError.invalidData }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer(); try c.encode(formatter.string(from: date))
        }
        return encoder
    }
    static func dateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
                throw ExchangeFormatError.invalidData
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            guard let date = formatter.date(from: text), validDate(date) else { throw ExchangeFormatError.invalidData }
            var offset = 0
            if !text.hasSuffix("Z") {
                let zone = Array(text.suffix(6))
                guard let hours = Int(String(zone[1...2])), let minutes = Int(String(zone[4...5])),
                      hours <= 23, minutes <= 59 else { throw ExchangeFormatError.invalidData }
                offset = (hours * 3600 + minutes * 60) * (zone[0] == "-" ? -1 : 1)
            }
            // Foundation normalisiert z. B. den 30. Februar. Kalenderfehler
            // dürfen importierte Hörzeitpunkte nicht still verschieben.
            let calendarCheck = ISO8601DateFormatter()
            calendarCheck.formatOptions = [.withInternetDateTime]
            calendarCheck.timeZone = TimeZone(secondsFromGMT: offset)
            let secondText = String(text.prefix(19)) + (text.hasSuffix("Z") ? "Z" : String(text.suffix(6)))
            guard let secondDate = calendarCheck.date(from: secondText),
                  calendarCheck.string(from: secondDate).prefix(19) == text.prefix(19) else { throw ExchangeFormatError.invalidData }
            return date
        }
        return decoder
    }
}

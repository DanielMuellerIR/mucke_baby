import Foundation

struct SongBookmark: Identifiable, Codable, Equatable {
    var id: UUID
    var station: String
    var raw: String
    var artist: String?
    var title: String?
    var heardAt: Date
    var savedAt: Date
    var recognition: SongRecognition? = nil

    var song: SongEntry {
        SongEntry(id: id, station: station, raw: raw, artist: artist, title: title,
                  start: heardAt, end: heardAt, recognition: recognition)
    }
}

struct BookmarkDocument: Codable {
    let formatVersion: Int
    let entries: [SongBookmark]
    init(entries: [SongBookmark]) {
        formatVersion = entries.contains { $0.recognition != nil } ? 2 : 1
        self.entries = entries
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        entries = try container.decode([SongBookmark].self, forKey: .entries)
        guard [1, 2].contains(formatVersion),
              formatVersion == 2 || entries.allSatisfy({ $0.recognition == nil }),
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && ($0.recognition?.isValid ?? true)
                  && ($0.recognition == nil || !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid bookmark entries"))
        }
    }
}
private enum BookmarkLoadVersionError: Error { case unsupported }

struct BookmarkIdentity: Hashable {
    let artist: String
    let title: String
    let recognizedOriginal: String?

    init(_ song: SongEntry) {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        if let artist = song.artist, let title = song.title,
           !normalized(artist).isEmpty, !normalized(title).isEmpty {
            self.artist = normalized(artist)
            self.title = normalized(title)
        } else {
            artist = ""
            title = normalized(song.raw)
        }
        // Ein allgemeiner Katalogtitel darf unterschiedliche Radio-Mixangaben nicht verschmelzen.
        recognizedOriginal = song.recognition.map { normalized($0.originalICY) }
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var entries: [SongBookmark] = []
    @Published private(set) var notice: String?
    private(set) var isReadOnly = false
    private(set) var diskData: Data?
    let fileURL: URL

    private struct Header: Decodable { let formatVersion: Int }

    enum StoreError: LocalizedError {
        case readOnly, noTitle, protectedDestination
        var errorDescription: String? {
            switch self {
            case .readOnly: return String(localized: "Die Merkliste ist schreibgeschützt. Bitte den Speicherzugriff oder die Dateiversion prüfen.")
            case .noTitle: return String(localized: "Dieser Eintrag enthält keinen Songtitel.")
            case .protectedDestination: return String(localized: "Die Merklistendatei darf nicht durch einen Export ersetzt werden.")
            }
        }
    }

    init(directory: URL? = nil) {
        if directory == nil { migrateLegacyAppDir(in: .applicationSupportDirectory) }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby", isDirectory: true)
        fileURL = directory.appendingPathComponent("bookmarks.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let recovery = try LibraryExchangeStorage.recover(in: directory) {
                guard let data = recovery.values["bookmarks.json"] else { throw ExchangeDiskError.invalidJournal }
                let imported = try ExchangeCodec.dateDecoder().decode(BookmarkDocument.self, from: data)
                adoptImport(imported.entries, data: data, pending: recovery.pending, notice: recovery.notice)
                return
            }
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            if let loaded = try JSONFileRecovery.loadSnapshot(BookmarkDocument.self, from: fileURL,
                                                              decoder: ExchangeCodec.dateDecoder(), validate: { data in
                if let header = try? JSONDecoder().decode(Header.self, from: data), ![1, 2].contains(header.formatVersion) {
                    throw BookmarkLoadVersionError.unsupported
                }
            }) {
                entries = loaded.value.entries; diskData = loaded.data
            }
            if existed, !FileManager.default.fileExists(atPath: fileURL.path) {
                notice = String(localized: "Die beschädigte Merkliste wurde separat gesichert. Eine neue Liste kann angelegt werden.")
            }
        } catch BookmarkLoadVersionError.unsupported {
            isReadOnly = true
            notice = String(localized: "Diese Merkliste verwendet eine unbekannte Dateiversion. Die Datei bleibt unverändert.")
        } catch {
            isReadOnly = true
            notice = String(localized: "Die Merkliste konnte nicht geladen werden. Die Datei bleibt geschützt.")
        }
    }

    func contains(_ song: SongEntry) -> Bool {
        let identity = BookmarkIdentity(song)
        return entries.contains { BookmarkIdentity($0.song) == identity }
    }

    @discardableResult
    func add(_ song: SongEntry, at date: Date = Date()) throws -> UUID {
        guard !isReadOnly else { throw StoreError.readOnly }
        guard !song.isPlaceholder, !song.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.noTitle
        }
        if let existing = entries.first(where: { BookmarkIdentity($0.song) == BookmarkIdentity(song) }) {
            return existing.id
        }
        let bookmark = SongBookmark(id: UUID(), station: song.station, raw: song.raw,
                                    artist: song.artist, title: song.title, heardAt: song.start, savedAt: date,
                                    recognition: song.recognition)
        try persist(entries + [bookmark])
        return bookmark.id
    }

    func toggle(_ song: SongEntry) throws {
        if contains(song) {
            let identity = BookmarkIdentity(song)
            try persist(entries.filter { BookmarkIdentity($0.song) != identity })
        } else { try add(song) }
    }

    func remove(id: UUID) throws { try persist(entries.filter { $0.id != id }) }

    private func persist(_ value: [SongBookmark]) throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        guard try ExchangeTransaction.read(fileURL.deletingLastPathComponent().appendingPathComponent(ExchangeTransaction.journalName)) == nil else {
            throw ExchangeDiskError.pending
        }
        let data = try ExchangeCodec.dateEncoder().encode(BookmarkDocument(entries: value))
        let stored = try ExchangeCodec.dateDecoder().decode(BookmarkDocument.self, from: data)
        try data.write(to: fileURL, options: .atomic)
        diskData = data
        // Erst nach erfolgreichem Schreiben darf das Herz Erfolg anzeigen.
        entries = stored.entries
    }

    func adoptImport(_ value: [SongBookmark], data: Data, pending: Bool, notice: String?) {
        entries = value; diskData = data; isReadOnly = pending; self.notice = notice
    }

    enum ExportFormat { case text, csv }

    func export(_ value: [SongBookmark], format: ExportFormat, to destination: URL) throws {
        let source = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        var sameFile = source == target
        if let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            sameFile = sameFile || (sourceID as? NSObject)?.isEqual(targetID) == true
        }
        guard !sameFile else { throw StoreError.protectedDestination }
        try Self.exportData(value, format: format).write(to: destination, options: .atomic)
    }

    static func exportData(_ entries: [SongBookmark], format: ExportFormat) -> Data {
        let date = ISO8601DateFormatter()
        let text: String
        switch format {
        case .text:
            text = entries.map { entry in
                var fields = [entry.raw, entry.station, date.string(from: entry.heardAt), date.string(from: entry.savedAt)]
                if let recognition = entry.recognition {
                    fields.insert([entry.artist, entry.title].compactMap { $0 }.joined(separator: " – "), at: 0)
                    fields += ["source: shazam", "recognized_at: " + date.string(from: recognition.recognizedAt),
                               "original_icy: " + recognition.originalICY, "station_id: " + recognition.stationID.uuidString]
                    if let id = recognition.shazamID { fields.append("shazam_id: " + id) }
                    if let url = recognition.appleMusicURL { fields.append("apple_music_url: " + url.absoluteString) }
                }
                return fields.joined(separator: "\n")
            }.joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
        case .csv:
            func quoted(_ value: String) -> String {
                var value = value
                // CSV-Quotes allein verhindern keine Formelausführung in Tabellen.
                if let first = value.drop(while: { $0.isWhitespace }).first, "=+-@".contains(first) {
                    value = "'" + value
                }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let hasRecognition = entries.contains { $0.recognition != nil }
            let rows = entries.map { entry in
                var fields = [entry.artist ?? "", entry.title ?? entry.raw, entry.raw, entry.station,
                              date.string(from: entry.heardAt), date.string(from: entry.savedAt)]
                if hasRecognition {
                    let recognition = entry.recognition
                    fields += [recognition?.source ?? "", recognition.map { date.string(from: $0.recognizedAt) } ?? "",
                               recognition?.stationID.uuidString ?? "", recognition?.originalICY ?? "",
                               recognition?.shazamID ?? "", recognition?.appleMusicURL?.absoluteString ?? ""]
                }
                return fields.map(quoted).joined(separator: ",")
            }
            let header = "artist,title,original,station,heard_at,saved_at"
                + (hasRecognition ? ",source,recognized_at,station_id,original_icy,shazam_id,apple_music_url" : "")
            text = ([header] + rows).joined(separator: "\r\n") + "\r\n"
        }
        return Data(text.utf8)
    }
}

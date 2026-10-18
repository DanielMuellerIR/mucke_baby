import Foundation

struct SongBookmark: Identifiable, Codable, Equatable {
    var id: UUID
    var station: String
    var raw: String
    var artist: String?
    var title: String?
    var heardAt: Date
    var savedAt: Date

    var song: SongEntry {
        SongEntry(id: id, station: station, raw: raw, artist: artist, title: title,
                  start: heardAt, end: heardAt)
    }
}

struct BookmarkDocument: Codable {
    let formatVersion: Int
    let entries: [SongBookmark]
    init(entries: [SongBookmark]) { formatVersion = 1; self.entries = entries }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        entries = try container.decode([SongBookmark].self, forKey: .entries)
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid bookmark entries"))
        }
    }
}

struct BookmarkIdentity: Hashable {
    let artist: String
    let title: String

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
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var entries: [SongBookmark] = []
    @Published private(set) var notice: String?
    private(set) var isReadOnly = false
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
                adoptImport(imported.entries, pending: recovery.pending, notice: recovery.notice)
                return
            }
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            if let header = try JSONFileRecovery.load(Header.self, from: fileURL) {
                // Neuere Versionen sind keine beschädigten Dateien. Unverändert
                // liegen lassen, damit eine passende App sie später lesen kann.
                guard header.formatVersion == 1 else {
                    isReadOnly = true
                    notice = String(localized: "Diese Merkliste verwendet eine unbekannte Dateiversion. Die Datei bleibt unverändert.")
                    return
                }
                if let document = try JSONFileRecovery.load(BookmarkDocument.self, from: fileURL, decoder: ExchangeCodec.dateDecoder()) {
                    guard document.formatVersion == 1 else { throw StoreError.readOnly }
                    entries = document.entries
                }
            }
            if existed, !FileManager.default.fileExists(atPath: fileURL.path) {
                notice = String(localized: "Die beschädigte Merkliste wurde separat gesichert. Eine neue Liste kann angelegt werden.")
            }
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
                                    artist: song.artist, title: song.title, heardAt: song.start, savedAt: date)
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
        // Erst nach erfolgreichem Schreiben darf das Herz Erfolg anzeigen.
        entries = stored.entries
    }

    func adoptImport(_ value: [SongBookmark], pending: Bool, notice: String?) {
        entries = value; isReadOnly = pending; self.notice = notice
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
                [entry.raw, entry.station, date.string(from: entry.heardAt), date.string(from: entry.savedAt)]
                    .joined(separator: "\n")
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
            let rows = entries.map { entry in
                [entry.artist ?? "", entry.title ?? entry.raw, entry.raw, entry.station,
                 date.string(from: entry.heardAt), date.string(from: entry.savedAt)]
                    .map(quoted).joined(separator: ",")
            }
            text = (["artist,title,original,station,heard_at,saved_at"] + rows).joined(separator: "\r\n") + "\r\n"
        }
        return Data(text.utf8)
    }
}

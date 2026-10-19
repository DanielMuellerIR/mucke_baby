import Foundation

struct ExchangeMergePlan {
    enum Kind: String { case station, group, bookmark }
    enum State { case new, unchanged, conflict }
    enum Choice: String, CaseIterable { case keepLocal, useIncoming, keepBoth }
    struct Key: Hashable { let kind: Kind; let id: UUID }
    struct Row: Identifiable {
        let id: Key
        let state: State
        let title: String
        let localID: UUID?
        let localDescription: String?
        let incomingDescription: String
    }
    let local: ExchangeLibrary
    let incoming: ExchangeLibrary
    let rows: [Row]
    private let duplicateIDs: [Key: UUID]

    init(local: ExchangeLibrary, incoming: ExchangeLibrary) throws {
        do { try ExchangeCodec.validate(local) }
        catch { throw ExchangeFormatError.invalidLocalData }
        try ExchangeCodec.validate(incoming)
        self.local = local; self.incoming = incoming
        var rows: [Row] = []
        var stationMap: [UUID: UUID] = [:]
        let localStations = Dictionary(uniqueKeysWithValues: local.stations.map { ($0.id, $0) })
        let localURLs = Dictionary(grouping: local.stations, by: { StationURLIdentity($0.url)! })
        let incomingURLs = Dictionary(grouping: incoming.stations, by: { StationURLIdentity($0.url)! })
        let incomingStationIDs = Set(incoming.stations.map(\.id))
        for station in incoming.stations {
            let identity = StationURLIdentity(station.url)!
            let urlMatches = localURLs[identity] ?? []
            let incomingURLCount = incomingURLs[identity]?.count ?? 0
            let match = localStations[station.id]
                ?? (urlMatches.count == 1 && incomingURLCount == 1 && !incomingStationIDs.contains(urlMatches[0].id) ? urlMatches.first : nil)
            stationMap[station.id] = match?.id ?? station.id
            var comparable = station; comparable.id = match?.id ?? station.id
            rows.append(Row(id: Key(kind: .station, id: station.id),
                            state: match == nil ? .new : comparable == match ? .unchanged : .conflict,
                            title: station.name, localID: match?.id,
                            localDescription: match.map(Self.describe), incomingDescription: Self.describe(station)))
        }
        let localGroups = Dictionary(uniqueKeysWithValues: local.groups.map { ($0.id, $0) })
        let localNames = Dictionary(grouping: local.groups, by: { Self.groupName($0.name) })
        let incomingNames = Dictionary(grouping: incoming.groups, by: { Self.groupName($0.name) })
        let incomingGroupIDs = Set(incoming.groups.map(\.id))
        for group in incoming.groups {
            let nameMatches = localNames[Self.groupName(group.name)] ?? []
            let incomingNameCount = incomingNames[Self.groupName(group.name)]?.count ?? 0
            let match = localGroups[group.id]
                ?? (nameMatches.count == 1 && incomingNameCount == 1 && !incomingGroupIDs.contains(nameMatches[0].id) ? nameMatches.first : nil)
            var comparable = group; comparable.id = match?.id ?? group.id
            comparable.stationIDs = group.stationIDs.map { stationMap[$0]! }
            rows.append(Row(id: Key(kind: .group, id: group.id),
                            state: match == nil ? .new : comparable == match ? .unchanged : .conflict,
                            title: group.name, localID: match?.id,
                            localDescription: match.map { Self.describe($0, stations: local.stations) },
                            incomingDescription: Self.describe(group, stations: incoming.stations)))
        }
        let localBookmarks = Dictionary(uniqueKeysWithValues: local.bookmarks.map { ($0.id, $0) })
        let localSongs = Dictionary(grouping: local.bookmarks, by: { BookmarkIdentity($0.song) })
        let incomingSongs = Dictionary(grouping: incoming.bookmarks, by: { BookmarkIdentity($0.song) })
        let incomingBookmarkIDs = Set(incoming.bookmarks.map(\.id))
        for entry in incoming.bookmarks {
            let identity = BookmarkIdentity(entry.song)
            let matches = localSongs[identity] ?? []
            let incomingCount = incomingSongs[identity]?.count ?? 0
            let match = localBookmarks[entry.id]
                ?? (matches.count == 1 && incomingCount == 1 && !incomingBookmarkIDs.contains(matches[0].id) ? matches.first : nil)
            var comparable = entry; comparable.id = match?.id ?? entry.id
            rows.append(Row(id: Key(kind: .bookmark, id: entry.id),
                            state: match == nil ? .new : comparable == match ? .unchanged : .conflict,
                            title: entry.raw, localID: match?.id,
                            localDescription: match.map(Self.describe), incomingDescription: Self.describe(entry)))
        }
        self.rows = rows
        var occupied = Set(local.stations.map(\.id) + incoming.stations.map(\.id)
                           + local.groups.map(\.id) + incoming.groups.map(\.id)
                           + local.bookmarks.map(\.id) + incoming.bookmarks.map(\.id))
        var duplicates: [Key: UUID] = [:]
        for row in rows where row.state == .conflict {
            var id = UUID(); while occupied.contains(id) { id = UUID() }
            occupied.insert(id); duplicates[row.id] = id
        }
        duplicateIDs = duplicates
    }

    func choice(for row: Row, selections: [Key: Choice]) -> Choice {
        row.state == .new ? selections[row.id] ?? .useIncoming
            : row.state == .unchanged ? .keepLocal : selections[row.id] ?? .keepLocal
    }

    func resolved(selections: [Key: Choice]) throws -> ExchangeLibrary {
        var result = local
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var stationMap: [UUID: UUID] = [:]
        for station in incoming.stations {
            let row = rowsByID[Key(kind: .station, id: station.id)]!
            let choice = choice(for: row, selections: selections)
            var value = station
            if let localID = row.localID {
                value.id = choice == .keepBoth ? duplicateIDs[row.id]! : localID
                stationMap[station.id] = value.id
                if choice == .useIncoming, let index = result.stations.firstIndex(where: { $0.id == localID }) {
                    result.stations[index] = value
                } else if choice == .keepBoth { result.stations.append(value) }
            } else if choice != .keepLocal {
                stationMap[station.id] = station.id; result.stations.append(value)
            }
        }
        for group in incoming.groups {
            let row = rowsByID[Key(kind: .group, id: group.id)]!
            let choice = choice(for: row, selections: selections)
            guard choice != .keepLocal else { continue }
            var value = group
            value.stationIDs = group.stationIDs.compactMap { stationMap[$0] }
            value.id = choice == .keepBoth ? duplicateIDs[row.id]! : row.localID ?? group.id
            if let localID = row.localID, choice == .useIncoming,
               let index = result.groups.firstIndex(where: { $0.id == localID }) {
                result.groups[index] = value
            } else {
                value.name = Self.availableGroupName(value.name, groups: result.groups)
                result.groups.append(value)
            }
        }
        for entry in incoming.bookmarks {
            let row = rowsByID[Key(kind: .bookmark, id: entry.id)]!
            let choice = choice(for: row, selections: selections)
            guard choice != .keepLocal else { continue }
            var value = entry
            value.id = choice == .keepBoth ? duplicateIDs[row.id]! : row.localID ?? entry.id
            if let localID = row.localID, choice == .useIncoming,
               let index = result.bookmarks.firstIndex(where: { $0.id == localID }) {
                result.bookmarks[index] = value
            } else { result.bookmarks.append(value) }
        }
        try ExchangeCodec.validate(result)
        return result
    }

    func resultDescription(for row: Row, selections: [Key: Choice], library: ExchangeLibrary) -> String? {
        let choice = choice(for: row, selections: selections)
        let id = choice == .keepBoth ? duplicateIDs[row.id] : row.localID ?? row.id.id
        switch row.id.kind {
        case .station: return library.stations.first { $0.id == id }.map(Self.describe)
        case .group: return library.groups.first { $0.id == id }.map { Self.describe($0, stations: library.stations) }
        case .bookmark: return library.bookmarks.first { $0.id == id }.map(Self.describe)
        }
    }

    private static func groupName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func availableGroupName(_ name: String, groups: [StationGroup]) -> String {
        let existing = Set(groups.map { groupName($0.name) })
        if !existing.contains(groupName(name)) { return name }
        var count = 1
        var candidate: String
        repeat {
            var base = name
            candidate = String(localized: "\(base) (Import \(count))")
            while candidate.utf8.count > 256 && !base.isEmpty {
                base.removeLast(); candidate = String(localized: "\(base) (Import \(count))")
            }
            count += 1
        } while existing.contains(groupName(candidate))
        return candidate
    }
    private static func describe(_ station: Station) -> String {
        [station.name, station.url,
         station.enabled ? String(localized: "Sichtbar") : String(localized: "Ausgeblendet"),
         station.favorite ? String(localized: "Favorit") : String(localized: "Kein Favorit"),
         station.radioBrowserID.map { "Radio Browser: " + $0.uuidString } ?? String(localized: "Ohne Katalogherkunft")].joined(separator: "\n")
    }
    private static func describe(_ group: StationGroup, stations: [Station]) -> String {
        let names = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0.name) })
        return ([group.name] + group.stationIDs.compactMap { names[$0] }).joined(separator: "\n")
    }
    private static func describe(_ entry: SongBookmark) -> String {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = entry.recognition == nil ? [entry.raw] : []
        if let artist = entry.artist { lines.append(String(localized: "Interpret: \(artist)")) }
        if let title = entry.title { lines.append(String(localized: "Titel: \(title)")) }
        lines.append(String(localized: "Sender: \(entry.station)"))
        lines.append(String(localized: "Gehört: \(date.string(from: entry.heardAt))"))
        lines.append(String(localized: "Gemerkt: \(date.string(from: entry.savedAt))"))
        if let recognition = entry.recognition {
            lines.append(String(localized: "Quelle: Shazam"))
            lines.append(String(localized: "Erkannt: \(date.string(from: recognition.recognizedAt))"))
            if let received = recognition.listening?.receivedAt {
                lines.append(String(localized: "Audio empfangen: \(date.string(from: received))"))
            }
            if let listening = recognition.listening {
                lines.append(String(localized: "Audioausgabe: \(listening.outputID.uuidString)"))
                lines.append(String(localized: "Ausgaberevision: \(String(listening.revision))"))
                if let position = listening.position {
                    lines.append(String(localized: "Pufferposition: \(String(position)) s"))
                }
            }
            lines.append(String(localized: "Sendertext: \(recognition.originalICY.isEmpty ? String(localized: "Kein Sendertext") : recognition.originalICY)"))
            if let url = recognition.appleMusicURL { lines.append("Apple Music: " + url.absoluteString) }
        }
        return lines.joined(separator: "\n")
    }
}

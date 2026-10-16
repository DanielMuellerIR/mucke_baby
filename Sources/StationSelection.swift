import Foundation

struct StationGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var stationIDs: [UUID] = []
}

struct StationCollection: Codable {
    var formatVersion = 2
    var stations: [Station]
    var groups: [StationGroup] = []
    var quickSlots: [UUID?] = Array(repeating: nil, count: 5)

    init(stations: [Station], groups: [StationGroup] = [], quickSlots: [UUID?] = Array(repeating: nil, count: 5)) {
        self.stations = stations; self.groups = groups; self.quickSlots = quickSlots
    }

    enum CodingKeys: CodingKey { case formatVersion, stations, groups, quickSlots }
    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([Station].self) {
            stations = legacy
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        stations = try container.decode([Station].self, forKey: .stations)
        groups = try container.decodeIfPresent([StationGroup].self, forKey: .groups) ?? []
        quickSlots = try container.decodeIfPresent([UUID?].self, forKey: .quickSlots) ?? Array(repeating: nil, count: 5)
        guard formatVersion == 2, quickSlots.count == 5,
              Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Invalid station collection"))
        }
    }
}

enum StationListScope: Hashable {
    case all, favorites, ungrouped, group(UUID)
}

enum StationSelection {
    static func filtered(_ stations: [Station], groups: [StationGroup], query: String,
                         scope: StationListScope = .all) -> [Station] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let members: Set<UUID>
        switch scope {
        case .group(let id): members = Set(groups.first { $0.id == id }?.stationIDs ?? [])
        case .ungrouped: members = Set(groups.flatMap(\.stationIDs))
        default: members = []
        }
        return stations.filter { station in
            guard station.enabled else { return false }
            switch scope {
            case .favorites: guard station.favorite else { return false }
            case .group: guard members.contains(station.id) else { return false }
            case .ungrouped: guard !members.contains(station.id) else { return false }
            case .all: break
            }
            let text = station.name + "\n" + station.url
            return terms.allSatisfy {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                           locale: Locale(identifier: "en_US_POSIX")) != nil
            }
        }
    }
}

import Foundation

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case all, today, week, month, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "Jeder Zeitraum")
        case .today: return String(localized: "Heute")
        case .week: return String(localized: "Letzte 7 Tage")
        case .month: return String(localized: "Letzte 30 Tage")
        case .custom: return String(localized: "Eigener Zeitraum")
        }
    }
}

struct HistoryFilter: Equatable {
    var query = ""
    var station: String?
    var period: HistoryPeriod = .all
    // Unsichtbare Uhrzeiten dürfen die Auswahl desselben Kalendertages nicht sperren.
    var firstDay = Calendar.current.startOfDay(for: Date())
    var lastDay = Calendar.current.startOfDay(for: Date())

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || station != nil || period != .all
    }

    func apply(to entries: [SongEntry], now: Date = Date(), calendar: Calendar = .current) -> [SongEntry] {
        let terms = Self.searchText(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let range = dateRange(now: now, calendar: calendar)
        return entries.filter { entry in
            if let station, entry.station != station { return false }
            if let range {
                let end = max(entry.start, entry.end ?? now)
                // Tagesende ist exklusiv. Ein Song, der genau am Anfang endet,
                // wurde in diesem Zeitraum nicht mehr gehört.
                if entry.start == end {
                    guard entry.start >= range.start, entry.start < range.end else { return false }
                } else {
                    guard entry.start < range.end, end > range.start else { return false }
                }
            }
            guard !terms.isEmpty else { return true }
            let text = Self.searchText([entry.raw, entry.artist, entry.title].compactMap { $0 }.joined(separator: "\n"))
            return terms.allSatisfy { text.contains($0) }
        }
    }

    func dateRange(now: Date, calendar: Calendar) -> DateInterval? {
        guard period != .all else { return nil }
        let today = calendar.startOfDay(for: now)
        let first: Date
        let last: Date
        switch period {
        case .all: return nil
        case .today: first = today; last = today
        case .week: first = calendar.date(byAdding: .day, value: -6, to: today) ?? today; last = today
        case .month: first = calendar.date(byAdding: .day, value: -29, to: today) ?? today; last = today
        case .custom:
            first = calendar.startOfDay(for: min(firstDay, lastDay))
            last = calendar.startOfDay(for: max(firstDay, lastDay))
        }
        guard let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return DateInterval(start: first, end: end)
    }

    static func stations(in entries: [SongEntry]) -> [String] {
        Array(Set(entries.map(\.station))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Bleibt die bisherige Lesestelle nicht im Ergebnis, den zeitlich nächsten
    // Treffer wählen. Die Auswahl selbst bleibt davon unabhängig erhalten.
    static func retainedAnchor(_ previous: UUID?, entries: [SongEntry], visible: [SongEntry]) -> UUID? {
        guard let previous else { return visible.first?.id }
        if visible.contains(where: { $0.id == previous }) { return previous }
        guard let prior = entries.first(where: { $0.id == previous }) else { return visible.first?.id }
        return visible.first(where: { $0.start >= prior.start })?.id ?? visible.last?.id
    }

    private static func searchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}

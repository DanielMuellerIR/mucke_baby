import SwiftUI

struct HistoryFilterControls: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiFontScale) private var uiFontScale

    @Binding var filter: HistoryFilter
    let entries: [SongEntry]
    let resultCount: Int
    let onRefreshDate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.songListSecondary)
                TextField("Titel oder Interpret suchen", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("history-search")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(theme.palette.songListSecondary)
                        .help("Suche löschen").accessibilityLabel("Suche löschen")
                }
            }
            .padding(7)
            .background(theme.palette.songListText.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Menu {
                    Button("Alle Sender") { filter.station = nil }
                    Divider()
                    ForEach(HistoryFilter.stations(in: entries), id: \.self) { station in
                        Button { filter.station = station } label: {
                            if filter.station == station { Label(station, systemImage: "checkmark") }
                            else { Text(station) }
                        }
                    }
                } label: {
                    filterLabel(filter.station ?? String(localized: "Alle Sender"), image: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel("Verlauf nach Sender filtern")
                .accessibilityIdentifier("history-station-filter")
                Menu {
                    ForEach(HistoryPeriod.allCases) { period in
                        Button {
                            filter.period = period
                            onRefreshDate()
                        } label: {
                            if filter.period == period { Label(period.title, systemImage: "checkmark") }
                            else { Text(period.title) }
                        }
                    }
                } label: { filterLabel(filter.period.title, image: "calendar") }
                    .accessibilityLabel("Verlauf nach Zeitraum filtern")
                    .accessibilityIdentifier("history-period-filter")
            }
            .menuStyle(.borderlessButton)
            if filter.period == .custom {
                DatePicker("Von", selection: $filter.firstDay, in: ...filter.lastDay, displayedComponents: .date)
                DatePicker("Bis", selection: $filter.lastDay, in: filter.firstDay..., displayedComponents: .date)
            }
            HStack {
                Text("\(resultCount) von \(entries.count) Titeln")
                    .foregroundStyle(theme.palette.songListSecondary)
                    .accessibilityIdentifier("history-result-count")
                Spacer(minLength: 4)
                Button("Zurücksetzen") {
                    filter = HistoryFilter()
                    onRefreshDate()
                }
                    .buttonStyle(.plain)
                    .disabled(!filter.isActive)
                    .help("Alle Verlaufsfilter zurücksetzen")
                    .accessibilityIdentifier("history-reset-filters")
            }
        }
        .font(theme.font(.label, size: 11 * uiFontScale))
        .foregroundStyle(theme.palette.songListText)
        .environment(\.colorScheme, theme.palette.parchment == nil ? colorScheme : .light)
        .padding(10)
        .help("Suchwörter werden gemeinsam gesucht. Zeiträume umfassen ganze Kalendertage und alle darin gehörten Titel.")
    }

    private func filterLabel(_ title: String, image: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: image)
            Text(title).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .help(title)
    }

}

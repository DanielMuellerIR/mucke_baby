import SwiftUI

struct ExchangeImportView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ExchangeMergePlan.Key: ExchangeMergePlan.Choice] = [:]
    @State private var resolved: ExchangeLibrary?
    @State private var message: String?
    @State private var saved = false
    @State private var scope: Scope = .all
    @State private var expanded: Set<ExchangeMergePlan.Key>
    let request: ExchangeImportRequest
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    private enum Scope: CaseIterable { case all, conflicts, new, unchanged }

    init(request: ExchangeImportRequest, availableWidth: CGFloat = 760, availableHeight: CGFloat = 700) {
        self.request = request
        self.availableWidth = availableWidth; self.availableHeight = availableHeight
        _expanded = State(initialValue: Set(request.plan.rows.filter { $0.state == .conflict }.map(\.id)))
        do { _resolved = State(initialValue: try request.plan.resolved(selections: [:])) }
        catch { _resolved = State(initialValue: nil); _message = State(initialValue: error.localizedDescription) }
    }
    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var stale: Bool {
        LibraryExchange.snapshot(store: store, bookmarks: bookmarks) != request.plan.local || store.quickSlots != request.quickSlots
    }
    private var visible: [ExchangeMergePlan.Row] {
        request.plan.rows.filter { row in
            switch scope {
            case .all: true
            case .conflicts: row.state == .conflict
            case .new: row.state == .new
            case .unchanged: row.state == .unchanged
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Importvorschau", systemImage: "square.and.arrow.down")
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold))
                Spacer()
                Button(saved ? String(localized: "Fertig") : String(localized: "Abbrechen")) { dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("exchange-cancel")
            }
            Text("Neue Einträge werden ergänzt. Bei Konflikten bleibt zunächst der lokale Stand erhalten. Wähle Änderungen bewusst aus; bestehende Einträge werden nicht gelöscht.")
                .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true)
            if request.plan.incoming.isLegacy {
                Text("Alte Senderdatei: fehlende IDs wurden für diese Vorschau vergeben. Gleiche Streamadressen werden vorhandenen Sendern zugeordnet.")
                    .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Einträge anzeigen", selection: $scope) {
                Text("Alle").tag(Scope.all)
                Text("Konflikte").tag(Scope.conflicts)
                Text("Neu").tag(Scope.new)
                Text("Unverändert").tag(Scope.unchanged)
            }.pickerStyle(.segmented).accessibilityIdentifier("exchange-filter")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visible.isEmpty {
                        Text("Keine Einträge in dieser Auswahl.").foregroundStyle(dim).padding(.vertical, 20)
                    }
                    ForEach(visible) { row in rowView(row) }
                }.padding(.trailing, 4)
            }
            Text("Gruppen enthalten nach dem Import nur die ausgewählten Sender. Schnellplätze, Startauswahl, Audioeinstellungen, Verlauf und Aufnahmen bleiben lokal.")
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true)
            if let resolved {
                Text("Nach Übernahme: \(resolved.stations.count) Sender, \(resolved.groups.count) Gruppen, \(resolved.bookmarks.count) gemerkte Titel.")
                    .font(theme.font(.body, size: 12 * scale)).accessibilityIdentifier("exchange-result-counts")
            }
            if let message {
                Text(message).font(theme.font(.body, size: 12 * scale)).foregroundStyle(saved ? dim : ink)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("exchange-message")
            }
            if stale && !saved {
                Text("Die lokale Bibliothek wurde geändert. Bitte schließen und eine neue Vorschau öffnen.")
                    .font(theme.font(.body, size: 12 * scale)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("exchange-stale")
            }
            if resolved == request.plan.local && !saved {
                Text("Die Auswahl ändert den lokalen Bestand nicht.").font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
            }
            HStack {
                Text("\(request.plan.rows.filter { $0.state == .conflict }.count) Konflikte")
                    .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                Spacer()
                Button("Auswahl übernehmen") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(saved || stale || resolved == nil || resolved == request.plan.local || store.isReadOnly || bookmarks.isReadOnly)
                    .accessibilityIdentifier("exchange-apply")
            }
        }
        .padding(20).foregroundStyle(ink)
        .frame(width: min(760, max(580, availableWidth)), height: min(700, max(500, availableHeight)))
        .background { SongListSurface() }
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
    }
    private func rowView(_ row: ExchangeMergePlan.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(theme.font(.body, size: 13 * scale, weight: .semibold))
                        .lineLimit(2).help(row.title)
                    Text(kind(row.id.kind) + " · " + state(row.state))
                        .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if row.state != .unchanged {
                    Picker("Entscheidung", selection: Binding(get: { request.plan.choice(for: row, selections: choices) }, set: { choice in
                        choices[row.id] = choice
                        do { resolved = try request.plan.resolved(selections: choices); message = nil }
                        catch { resolved = nil; message = error.localizedDescription }
                    })) {
                        Text(row.state == .new ? String(localized: "Überspringen") : String(localized: "Lokal behalten"))
                            .tag(ExchangeMergePlan.Choice.keepLocal)
                        Text(row.state == .new ? String(localized: "Importieren") : String(localized: "Import übernehmen"))
                            .tag(ExchangeMergePlan.Choice.useIncoming)
                        if row.state == .conflict { Text("Beide behalten").tag(ExchangeMergePlan.Choice.keepBoth) }
                    }.labelsHidden().frame(width: 190)
                        .accessibilityLabel(row.title + ": " + String(localized: "Entscheidung"))
                        .accessibilityIdentifier("exchange-choice-" + row.id.kind.rawValue + "-" + row.id.id.uuidString)
                        .disabled(saved)
                }
            }
            DisclosureGroup("Details vergleichen", isExpanded: Binding(get: { expanded.contains(row.id) }, set: { open in
                if open { expanded.insert(row.id) } else { expanded.remove(row.id) }
            })) {
                HStack(alignment: .top, spacing: 16) {
                    if let local = row.localDescription { description("Lokal", local) }
                    description("Import", row.incomingDescription)
                }
                if row.id.kind == .group, let resolved,
                   let result = request.plan.resultDescription(for: row, selections: choices, library: resolved) {
                    description("Ergebnis nach Auswahl", result)
                }
            }.font(theme.font(.body, size: 12 * scale))
        }
        .padding(12).background(dim.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("exchange-row-" + row.id.kind.rawValue + "-" + row.id.id.uuidString)
    }
    private func description(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).foregroundStyle(dim)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func kind(_ kind: ExchangeMergePlan.Kind) -> String {
        switch kind {
        case .station: String(localized: "Sender")
        case .group: String(localized: "Gruppe")
        case .bookmark: String(localized: "Gemerkter Titel")
        }
    }
    private func state(_ state: ExchangeMergePlan.State) -> String {
        switch state {
        case .new: String(localized: "Neu")
        case .unchanged: String(localized: "Unverändert")
        case .conflict: String(localized: "Konflikt")
        }
    }
    private func apply() {
        do {
            let notice = try LibraryExchange.apply(request, choices: choices, store: store, bookmarks: bookmarks)
            saved = true; message = notice ?? String(localized: "Import gespeichert.")
        } catch { message = error.localizedDescription }
    }
}

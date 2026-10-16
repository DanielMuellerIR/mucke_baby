import SwiftUI

struct StationFilterControls: View {
    @EnvironmentObject var store: Store
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var fontScale
    @Binding var query: String
    @Binding var scope: StationListScope
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.textSecondary)
                TextField("Eigene Sender durchsuchen", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier(identifier + "-search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).help("Suche leeren").accessibilityLabel("Suche leeren")
                }
            }
            .font(theme.font(.body, size: 12 * fontScale)).padding(.horizontal, 7)
            .frame(height: 30)
            .background(theme.palette.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            Picker("Senderauswahl", selection: $scope) {
                Text("Alle Sender").tag(StationListScope.all)
                Text("Favoriten").tag(StationListScope.favorites)
                Text("Ohne Gruppe").tag(StationListScope.ungrouped)
                ForEach(store.groups) { group in Text(group.name).tag(StationListScope.group(group.id)) }
            }
            .labelsHidden()
            .accessibilityLabel("Senderauswahl")
            .accessibilityIdentifier(identifier + "-scope")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.palette.textPrimary)
        .onChange(of: store.groups.map(\.id)) { _, ids in
            if case .group(let id) = scope, !ids.contains(id) { scope = .all }
        }
    }
}

struct StationGroupsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sendergruppen").font(.headline)
            Text("Ein Sender kann mehreren Gruppen angehören. Gruppenlöschung entfernt nur die Zuordnung, keine Sender.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selectedID) {
                ForEach(store.groups) { group in
                    HStack {
                        Text(group.name).lineLimit(1).help(group.name)
                        Spacer()
                        Text("\(store.stations.filter { group.stationIDs.contains($0.id) }.count) Sender").foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                    .accessibilityIdentifier("station-group-" + group.id.uuidString)
                }
                .onMove { offsets, destination in perform { try store.moveGroups(from: offsets, to: destination) } }
            }
            .overlay {
                if store.groups.isEmpty { Text("Noch keine Gruppen.").foregroundStyle(.secondary) }
            }
            .frame(height: 200)
            TextField("Gruppenname", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("station-group-name")
                .onSubmit { save() }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Neue Gruppe") { selectedID = nil; name = ""; errorMessage = nil }
                    .accessibilityIdentifier("station-group-new")
                Button("Löschen", role: .destructive) {
                    guard let id = selectedID else { return }
                    perform { try store.deleteGroup(id); selectedID = nil; name = "" }
                }
                .disabled(selectedID == nil).accessibilityIdentifier("station-group-delete")
                Spacer()
                Button("Sichern") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("station-group-save")
                Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("station-groups-close")
            }
        }
        .padding(18).frame(width: 480)
        .onChange(of: selectedID) { _, id in
            name = store.groups.first { $0.id == id }?.name ?? ""
            errorMessage = nil
        }
    }

    private func save() {
        let previousIDs = Set(store.groups.map(\.id))
        perform {
            try store.saveGroup(id: selectedID, name: name)
            if selectedID == nil { selectedID = store.groups.first { !previousIDs.contains($0.id) }?.id }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch StationSaveError.invalidGroupName { errorMessage = String(localized: "Bitte einen eindeutigen, nicht leeren Gruppennamen eingeben.") }
        catch { errorMessage = String(localized: "Die Änderung konnte nicht gespeichert werden. Die bisherige Auswahl bleibt erhalten.") }
    }
}

private struct QuickSelectionActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openStationQuickSelection: (() -> Void)? {
        get { self[QuickSelectionActionKey.self] }
        set { self[QuickSelectionActionKey.self] = newValue }
    }
}

struct StationCommands: Commands {
    @ObservedObject var store: Store
    @ObservedObject var player: RadioPlayer
    @FocusedValue(\.openStationQuickSelection) private var openQuickSelection

    var body: some Commands {
        CommandMenu("Sender") {
            Button("Sender schnell auswählen …") { openQuickSelection?() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(openQuickSelection == nil)
            Divider()
            ForEach(0..<5, id: \.self) { index in
                Button {
                    if let station = store.quickStation(at: index) { player.play(station) }
                } label: {
                    Text("\(index + 1): \(store.quickStation(at: index)?.name ?? String(localized: "Nicht verfügbar"))")
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.option, .command])
                .disabled(store.quickStation(at: index) == nil)
            }
        }
    }
}

struct StationQuickSelectionView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope = StationListScope.all
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    private var matches: [Station] { StationSelection.filtered(store.stations, groups: store.groups, query: query, scope: scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sender schnell auswählen").font(.headline)
            TextField("Eigene Sender durchsuchen", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityIdentifier("quick-station-search")
                .onSubmit { playSelection() }
            Picker("Senderauswahl", selection: $scope) {
                Text("Alle Sender").tag(StationListScope.all)
                Text("Favoriten").tag(StationListScope.favorites)
                Text("Ohne Gruppe").tag(StationListScope.ungrouped)
                ForEach(store.groups) { group in Text(group.name).tag(StationListScope.group(group.id)) }
            }
            .accessibilityIdentifier("quick-station-scope")
            List(selection: $selectedID) {
                ForEach(matches) { station in
                    Text(station.name).lineLimit(1).help(station.name).tag(station.id)
                        .accessibilityIdentifier("quick-station-" + station.id.uuidString)
                }
            }
            .frame(height: 260)
            .overlay { if matches.isEmpty { Text("Keine passenden Sender.").foregroundStyle(.secondary) } }
            Text("Suchen und Return drücken. Mit Tab zur Liste wechseln und mit den Pfeiltasten auswählen.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Wiedergabe") { playSelection() }.keyboardShortcut(.defaultAction)
                    .disabled(!matches.contains { $0.id == selectedID })
                    .accessibilityIdentifier("quick-station-play")
            }
        }
        .padding(18).frame(width: 460)
        .onAppear { selectedID = matches.first?.id; searchFocused = true }
        .onChange(of: matches.map(\.id)) { _, ids in if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first } }
    }

    private func playSelection() {
        guard let station = matches.first(where: { $0.id == selectedID }) else { return }
        player.play(station)
        dismiss()
    }
}

struct StationQuickSlots: View {
    @EnvironmentObject var store: Store
    @State private var errorMessage: String?
    var body: some View {
        Section("Schnellplätze") {
            ForEach(0..<5, id: \.self) { index in
                Picker("⌥⌘\(index + 1)", selection: Binding(
                    get: { store.quickSlots[index] },
                    set: { id in
                        do { try store.setQuickSlot(index, stationID: id); errorMessage = nil }
                        catch { errorMessage = String(localized: "Die Änderung konnte nicht gespeichert werden. Die bisherige Auswahl bleibt erhalten.") }
                    }
                )) {
                    Text("Nicht belegt").tag(UUID?.none)
                    if let id = store.quickSlots[index], !store.enabledStations.contains(where: { $0.id == id }) {
                        Text("Nicht verfügbar").tag(Optional(id))
                    }
                    ForEach(store.enabledStations) { station in Text(station.name).tag(Optional(station.id)) }
                }
                .accessibilityIdentifier("station-quick-slot-\(index + 1)")
            }
            Text("Die Tastenkürzel starten den gewählten Sender. Fehlende oder ausgeblendete Ziele bleiben deaktiviert.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
    }
}

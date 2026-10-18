import SwiftUI
import UniformTypeIdentifiers   // .json fuer Datei-Dialoge

// MARK: - Sender hinzufuegen / bearbeiten

struct StationEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let station: Station?          // nil = neuer Sender
    @State private var name = ""
    @State private var url = ""
    @State private var enabled = true
    @State private var favorite = false
    @State private var selectedGroupIDs: Set<UUID> = []
    @State private var saveError: StationSaveError?
    @State private var showingRepair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(station == nil ? "Sender hinzufügen" : "Sender bearbeiten")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Stream-URL", text: $url)
                    .textContentType(.URL)
                if let station {
                    Section("Senderherkunft") {
                        if let origin = station.radioBrowserID {
                            Text("Radio-Browser").font(.subheadline.bold())
                            Text(origin.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Katalogadresse prüfen …") { showingRepair = true }
                                .accessibilityIdentifier("station-repair")
                            Text("Die Reparatur speichert nur die Katalogadresse. Andere Änderungen im Editor erst mit Sichern übernehmen.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Keine Katalogherkunft gespeichert. Die Adresse kann manuell im Editor geändert werden.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Toggle("In Liste anzeigen", isOn: $enabled)
                Toggle("Favorit", isOn: $favorite)
                    .accessibilityIdentifier("station-favorite")
                if !store.groups.isEmpty {
                    Section("Gruppen") {
                        ForEach(store.groups) { group in
                            Toggle(isOn: Binding(
                                get: { selectedGroupIDs.contains(group.id) },
                                set: { selected in
                                    if selected { selectedGroupIDs.insert(group.id) }
                                    else { selectedGroupIDs.remove(group.id) }
                                }
                            )) { Text(group.name).lineLimit(1).help(group.name) }
                            .accessibilityIdentifier("station-membership-" + group.id.uuidString)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let saveError {
                Text(LocalizedStringKey(saveError == .invalidURL
                     ? "Bitte eine gültige HTTP- oder HTTPS-URL mit Hostnamen eingeben."
                     : saveError == .persistenceFailed
                     ? "Die Senderliste konnte nicht gespeichert werden. Bitte den Speicherzugriff prüfen und erneut versuchen."
                     : "Der Sender ist nicht mehr vorhanden. Bitte den Editor erneut öffnen."))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if station != nil {
                    Button(role: .destructive) {
                        if let s = station, store.delete(s) { dismiss() }
                        else {
                            store.persistenceFailed = false
                            saveError = .persistenceFailed
                        }
                    } label: { Text("Löschen") }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .sheet(isPresented: $showingRepair) {
            if let current = store.stations.first(where: { $0.id == station?.id }) {
                StationRepairView(station: current) { newURL in url = newURL }
            }
        }
        .onChange(of: url) { _, _ in saveError = nil }
        .onAppear {
            if let s = station {
                name = s.name; url = s.url; enabled = s.enabled; favorite = s.favorite
                selectedGroupIDs = Set(store.groups.filter { $0.stationIDs.contains(s.id) }.map(\.id))
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        do {
            var s = store.stations.first(where: { $0.id == station?.id })
                ?? station ?? Station(name: trimmedName, url: trimmedURL)
            s.name = trimmedName; s.url = trimmedURL; s.enabled = enabled; s.favorite = favorite
            if station != nil {
                try store.update(s, groupIDs: selectedGroupIDs)
            } else {
                try store.add(s, groupIDs: selectedGroupIDs)
            }
            dismiss()
        } catch let error as StationSaveError {
            saveError = error
        } catch {
            saveError = .persistenceFailed
        }
    }
}

// MARK: - Einstellungen

struct PreferencesView: View {
    @EnvironmentObject var startup: StartupSettings
    @EnvironmentObject var store: Store
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("menuBarMode") private var menuBarMode = false
    @EnvironmentObject private var player: RadioPlayer
    @State private var ioMessage = ""
    @State private var importRequest: ExchangeImportRequest?

    private var recordingsDir: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby/Aufnahmen", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Einstellungen").font(.headline)

            Form {
                Section("Start") {
                    Picker("Wiedergabe beim Start", selection: Binding(
                        get: { startup.configuration.mode }, set: { startup.setMode($0) }
                    )) {
                        ForEach(StartupMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .accessibilityIdentifier("startup-mode")
                    .disabled(startup.isReadOnly)
                    if startup.configuration.mode == .selectedStation {
                        Picker("Startsender", selection: Binding(
                            get: { startup.configuration.selectedStationID }, set: { startup.selectStation($0) }
                        )) {
                            Text("Bitte Sender auswählen").tag(UUID?.none)
                            if let id = startup.configuration.selectedStationID,
                               !store.enabledStations.contains(where: { $0.id == id }) {
                                Text("Nicht verfügbar").tag(Optional(id))
                            }
                            ForEach(store.enabledStations) { station in Text(station.name).tag(Optional(station.id)) }
                        }
                        .accessibilityIdentifier("startup-station")
                        .disabled(startup.isReadOnly)
                    }
                    if startup.configuration.mode != .none {
                        if let target = startup.configuration.target(in: store.stations) {
                            Text("Startsender: \(target.name)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Kein verfügbarer Startsender. Die App startet ohne Wiedergabe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Favoriten sind unabhängig von der Startauswahl. Fehlende oder ausgeblendete Startsender werden nicht ersetzt.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice = startup.notice {
                        Text(notice).font(.caption).foregroundStyle(.red)
                    }
                }
                StationQuickSlots()
                Section("Menüleiste") {
                    Toggle("Zusätzlich Symbol in der Menüleiste anzeigen", isOn: $menuBarMode)
                    Text("Optional — Standard ist nur das normale Fenster.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Aufnahme") {
                    Toggle("Laufende Streams mitschneiden", isOn: Binding(get: { player.recordingRequested }, set: player.setRecordingRequested))
                    Text("Standardmäßig AUS. Der Schalter wirkt sofort während der Wiedergabe. Aufnahme stoppt unter 10 GiB freiem Speicher. Ablage: ~/Music/MuckeBaby/Aufnahmen/. Der tatsächliche Status steht unten im Hauptfenster.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Aufnahmen im Finder zeigen") {
                        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([recordingsDir])
                    }
                }
                Section("Bibliothek austauschen (JSON)") {
                    HStack {
                        Button("Exportieren …") { exportStations() }.accessibilityIdentifier("exchange-export")
                        Button("Importieren …") { importStations() }.accessibilityIdentifier("exchange-import")
                    }
                    Text("Sender mit Favoriten und Katalogherkunft, Gruppen und gemerkte Titel austauschen. Vor dem Import erscheint eine Vorschau mit Konfliktwahl. Rohaufnahmen und Verlauf werden nicht exportiert.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !ioMessage.isEmpty {
                        Text(ioMessage).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                Section("Daten") {
                    Text(store.stationsURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.stationsURL])
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .sheet(item: $importRequest) { request in
            ExchangeImportView(request: request, availableWidth: (PlayerWindowRouter.mainWindow?.frame.width ?? 840) - 80,
                               availableHeight: (PlayerWindowRouter.mainWindow?.frame.height ?? 780) - 80)
        }
    }

    // Die portable Bibliothek enthält keine Aufnahmen und keine lokalen Einstellungen.
    private func exportStations() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "muckebaby-bibliothek.json"
        if bookmarks.entries.contains(where: { $0.recognition != nil }) {
            panel.message = String(localized: "Enthält erkannte Titel. Der Import erfordert eine App-Version, die Shazam-Herkunft unterstützt.")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryExchange.export(store: store, bookmarks: bookmarks, to: url, recordingDirectory: recordingsDir)
            ioMessage = String(localized: "Bibliothek exportiert.")
        } catch {
            ioMessage = String(localized: "Export fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // Einlesen allein verändert weder Sender noch Merkliste.
    private func importStations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try ExchangeTransaction.read(url, limit: ExchangeCodec.byteLimit) else { throw ExchangeFormatError.invalidData }
            importRequest = try LibraryExchange.prepare(data, store: store, bookmarks: bookmarks)
            ioMessage = ""
        } catch { ioMessage = error.localizedDescription }
    }
}

// MARK: - Willkommen (einmaliger Hinweis beim ersten Start)

// Wird genau einmal gezeigt (UserDefaults-Key "didShowWelcome", gesetzt in ContentView).
// Erklaert die zwei Dinge, die beim ersten Start sonst ueberraschen:
//  1) macOS fragt evtl. nach der Berechtigung „Audio aufnehmen" — die App tappt dafuer
//     NUR die eigene Tonausgabe, damit die Visualizer reagieren (kein Mikrofon).
//  2) Der Mitschnitt ist ab Werk AUS und kann hier bewusst aktiviert werden.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    // Dieselbe Aufnahmesteuerung wie im Hauptfenster und in den Einstellungen.
    @EnvironmentObject private var player: RadioPlayer

    private var recordingsDir: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby/Aufnahmen", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Willkommen bei Mucke, Baby!").font(.title2.bold())
            Text("Zwei Dinge kurz vorab — danach läuft alles ohne Nachfragen.")
                .font(.subheadline).foregroundStyle(.secondary)

            Form {
                Section("Visualizer & Audio-Berechtigung") {
                    Text("Die Visualizer tanzen zur Musik. Dafür „hört“ die App ihre eigene Tonausgabe ab (System-Audio-Tap). Beim ersten Mal fragt macOS deshalb einmalig nach der Berechtigung, Audio aufzunehmen. Es wird kein Mikrofon verwendet und nichts mitgehört außer der eigenen Wiedergabe.")
                        .font(.callout)
                }
                Section("Mitschnitt der Streams") {
                    Toggle("Laufende Streams mitschneiden", isOn: Binding(get: { player.recordingRequested }, set: player.setRecordingRequested))
                    Text("Standardmäßig AUS. Wenn aktiviert, wird der Stream während des Hörens als Audiodatei abgelegt, damit nichts verloren geht. Ablage: ~/Music/MuckeBaby/Aufnahmen/. Stoppt automatisch bei weniger als 10 GB freiem Speicher. Jederzeit hier oder unter Einstellungen → Aufnahme umschaltbar.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Aufnahme-Ordner zeigen") {
                        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([recordingsDir])
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Los geht's") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}

// Die frühere einfache Namenssuche (SearchView) ist im Sender-Katalog
// aufgegangen: StationBrowser.swift (Genres + Suche + Probehören).

// MARK: - Menueleisten-Inhalt (optionaler Modus)

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer
    @State private var query = ""
    @State private var scope = StationListScope.all
    private var matches: [Station] {
        StationSelection.filtered(store.stations, groups: store.groups, query: query, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.currentStation?.name ?? "Kein Sender")
                .fontWeight(.semibold).lineLimit(1)
            if !player.nowPlayingTitle.isEmpty {
                Text(player.nowPlayingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(player.statusText).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            StationFilterControls(query: $query, scope: $scope, identifier: "menu-stations")
            if matches.isEmpty {
                Text("Keine passenden Sender.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { st in
                            HStack(spacing: 8) {
                                Button {
                                    player.toggle(st)
                                } label: {
                                    HStack {
                                        Image(systemName: player.currentStation?.id == st.id && (player.isPlaying || player.isLoading)
                                              ? "stop.fill" : "play.fill")
                                            .font(.caption).frame(width: 14)
                                        Text(st.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                StationFavoriteButton(station: st)
                            }
                        }
                    }
                }
                .frame(height: min(280, CGFloat(matches.count) * 32))
            }

            Divider()
            HStack {
                RecordingControl(identifier: "menu-recording")
                Spacer()
                SleepTimerButton(identifier: "menu-sleep-timer")
            }
            HStack {
                Button((player.isPlaying || player.isLoading) ? "Stop" : "Play") {
                    if let s = player.currentStation {
                        player.toggle(store.stations.first(where: { $0.id == s.id }) ?? s)
                    }
                }
                .disabled(player.currentStation == nil)
                Spacer()
                Button("Beenden") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct StationFavoriteButton: View {
    @EnvironmentObject var store: Store
    let station: Station
    private var label: String {
        station.favorite ? String(localized: "Aus Favoriten entfernen") : String(localized: "Zu Favoriten hinzufügen")
    }
    var body: some View {
        Button { store.toggleFavorite(station) } label: {
            Image(systemName: station.favorite ? "star.fill" : "star")
                .foregroundStyle(station.favorite ? Color.yellow : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("station-favorite-" + station.id.uuidString)
    }
}

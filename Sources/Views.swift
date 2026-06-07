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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(station == nil ? "Sender hinzufügen" : "Sender bearbeiten")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Stream-URL", text: $url)
                    .textContentType(.URL)
                Toggle("In Liste anzeigen", isOn: $enabled)
                Toggle("Favorit (Autostart)", isOn: $favorite)
            }
            .formStyle(.grouped)

            HStack {
                if station != nil {
                    Button(role: .destructive) {
                        if let s = station { store.delete(s) }
                        dismiss()
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
        .onAppear {
            if let s = station {
                name = s.name; url = s.url; enabled = s.enabled; favorite = s.favorite
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if var s = station {
            s.name = trimmedName; s.url = trimmedURL; s.enabled = enabled; s.favorite = favorite
            store.update(s)
            if favorite { store.setFavorite(s) }   // sorgt fuer Eindeutigkeit
        } else {
            let s = Station(name: trimmedName, url: trimmedURL, enabled: enabled, favorite: favorite)
            store.add(s)
            if favorite { store.setFavorite(s) }
        }
        dismiss()
    }
}

// MARK: - Einstellungen

struct PreferencesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("autoplayOnLaunch") private var autoplay = true
    @AppStorage("menuBarMode") private var menuBarMode = false
    @AppStorage("recordStreams") private var recordStreams = true
    @State private var ioMessage = ""

    private var recordingsDir: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby/Aufnahmen", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Einstellungen").font(.headline)

            Form {
                Section("Start") {
                    Toggle("Beim Start Favorit sofort abspielen", isOn: $autoplay)
                    if let fav = store.favorite {
                        Text("Favorit: \(fav.name)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Kein Favorit gesetzt (Stern in der Bearbeiten-Ansicht).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Menüleiste") {
                    Toggle("Zusätzlich Symbol in der Menüleiste anzeigen", isOn: $menuBarMode)
                    Text("Optional — Standard ist nur das normale Fenster.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Aufnahme") {
                    Toggle("Laufende Streams mitschneiden", isOn: $recordStreams)
                    Text("⚠️ Standardmäßig AN: zeichnet durchgehend auf (Roh-Audio). Stoppt automatisch bei < 10 GB frei. Ablage: ~/Music/MuckeBaby/Aufnahmen/. Greift ab dem nächsten Senderstart.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Aufnahmen im Finder zeigen") {
                        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([recordingsDir])
                    }
                }
                Section("Sender Im-/Export (JSON)") {
                    HStack {
                        Button("Exportieren …") { exportStations() }
                        Button("Importieren …") { importStations() }
                    }
                    Text("Export schreibt die ganze Liste; Import fügt neue Sender hinzu (Dubletten per URL übersprungen).")
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
    }

    // Ganze Senderliste als JSON-Datei sichern.
    private func exportStations() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "muckebaby-sender.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        do {
            try data.write(to: url)
            ioMessage = String(localized: "\(store.stations.count) Sender exportiert.")
        } catch {
            ioMessage = String(localized: "Export fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // JSON-Datei einlesen und neue Sender hinzufuegen.
    private func importStations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let n = store.importData(data)
        ioMessage = n >= 0
            ? String(localized: "\(n) neue Sender importiert.")
            : String(localized: "Datei nicht lesbar (erwartet: JSON-Array mit {name,url}).")
    }
}

// MARK: - Willkommen (einmaliger Hinweis beim ersten Start)

// Wird genau einmal gezeigt (UserDefaults-Key "didShowWelcome", gesetzt in ContentView).
// Erklaert die zwei Dinge, die beim ersten Start sonst ueberraschen:
//  1) macOS fragt evtl. nach der Berechtigung „Audio aufnehmen" — die App tappt dafuer
//     NUR die eigene Tonausgabe, damit die Visualizer reagieren (kein Mikrofon).
//  2) Der Mitschnitt der laufenden Streams ist ab Werk AN. Hier sofort abschaltbar.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    // Selber Key wie in den Einstellungen — Aenderung hier wirkt sofort dort und umgekehrt.
    @AppStorage("recordStreams") private var recordStreams = true

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
                    Toggle("Laufende Streams mitschneiden", isOn: $recordStreams)
                    Text("Ab Werk AN: Während des Hörens wird der Stream als Audiodatei abgelegt, damit nichts verloren geht. Ablage: ~/Music/MuckeBaby/Aufnahmen/. Stoppt automatisch bei weniger als 10 GB freiem Speicher. Jederzeit abschaltbar — hier oder unter Einstellungen → Aufnahme.")
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

// MARK: - Radio-Browser-Suche

struct RBStation: Decodable, Identifiable {
    var id: String { stationuuid }
    let stationuuid: String
    let name: String
    let url: String
    let url_resolved: String?
    let codec: String?
    let bitrate: Int?
    let country: String?

    var streamURL: String {
        if let r = url_resolved, !r.isEmpty { return r }
        return url
    }
    var detail: String {
        [codec, bitrate.map { "\($0) kbps" }, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct SearchView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [RBStation] = []
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sender suchen").font(.headline)

            HStack {
                TextField("Name, z. B. Hardstyle", text: $query)
                    .onSubmit { Task { await search() } }
                Button("Suchen") { Task { await search() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }

            List(results) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).lineLimit(1)
                        Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        store.add(Station(name: r.name, url: r.streamURL))
                    } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain)
                    .help("Zur Liste hinzufügen")
                }
            }
            .frame(minHeight: 260)

            HStack {
                Spacer()
                Button("Schließen") { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 520, height: 460)
    }

    // radio-browser.info: kostenlose, offene Radio-API.
    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true; error = ""; results = []
        defer { loading = false }

        var c = URLComponents(string: "https://de1.api.radio-browser.info/json/stations/search")!
        c.queryItems = [
            .init(name: "name", value: q),
            .init(name: "limit", value: "40"),
            .init(name: "hidebroken", value: "true"),
            .init(name: "order", value: "votes"),
            .init(name: "reverse", value: "true"),
        ]
        guard let url = c.url else { error = String(localized: "Ungültige Anfrage"); return }
        var req = URLRequest(url: url)
        req.setValue("MuckeBaby/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            results = try JSONDecoder().decode([RBStation].self, from: data)
            if results.isEmpty { error = String(localized: "Keine Treffer.") }
        } catch {
            self.error = String(localized: "Suche fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

// MARK: - Menueleisten-Inhalt (optionaler Modus)

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer

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

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.enabledStations) { st in
                        Button {
                            player.toggle(st)
                        } label: {
                            HStack {
                                Image(systemName: player.currentStation?.id == st.id && player.isPlaying
                                      ? "pause.fill" : "play.fill")
                                    .font(.caption).frame(width: 14)
                                Text(st.name).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)

            Divider()
            HStack {
                Button(player.isPlaying ? "Stop" : "Play") {
                    if let s = player.currentStation { player.toggle(s) }
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

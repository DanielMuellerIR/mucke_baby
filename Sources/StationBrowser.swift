import SwiftUI
import VLCKit

// Sender-Katalog: Stöbern in der freien Community-Datenbank radio-browser.info
// (über 50.000 Sender, nach Genre-Tags strukturiert). Rechtslage siehe
// THIRD-PARTY.md §4: Daten frei nutzbar, Stream-URLs sind Fakten; einzige Bitte
// der Betreiber ist ein beschreibender User-Agent — den senden wir mit.
//
// Drei Bausteine in dieser Datei:
//  - RadioBrowserAPI:   dünner HTTP-Client mit Spiegel-Server-Failover.
//  - PreviewPlayer:     eigener kleiner VLC-Player NUR fürs Probehören
//                       (kein Verlauf, keine Aufnahme, kein ICY-Reader).
//  - StationBrowserView: das Sheet — Genres links, Sender rechts,
//                       Probehören + „Zur Liste hinzufügen" pro Zeile.

// MARK: - API-Datentypen

/// Genre-Tag aus der radio-browser-Datenbank (Name + Anzahl Sender).
struct RBTag: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let stationcount: Int
}

/// Sender-Eintrag aus der radio-browser-Datenbank. Wir dekodieren nur die
/// Felder, die die App anzeigt/braucht — alles andere ignoriert JSONDecoder.
struct RBStation: Decodable, Identifiable {
    var id: String { stationuuid }
    let stationuuid: String
    let name: String
    let url: String
    let url_resolved: String?
    let codec: String?
    let bitrate: Int?
    let country: String?
    let votes: Int?

    /// Bevorzugt die vom Server bereits aufgelöste Direkt-URL (Playlists wie
    /// .m3u/.pls sind dort schon zur Stream-URL verfolgt).
    var streamURL: String {
        if let r = url_resolved, !r.isEmpty { return r }
        return url
    }

    /// Kompakte Detailzeile: Codec · Bitrate · Land · Stimmen.
    var detail: String {
        [codec,
         bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil },
         country,
         votes.map { "▲ \($0)" }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - API-Client

/// Minimaler Client für die offene radio-browser-API. Die Datenbank läuft auf
/// mehreren Community-Spiegeln; fällt einer aus, probieren wir den nächsten.
enum RadioBrowserAPI {
    /// Bekannte öffentliche Spiegel (Stand 2026-07; die Liste kann sich ändern —
    /// offiziell wird sie per DNS unter all.api.radio-browser.info verteilt).
    /// Reihenfolge = Versuchsreihenfolge beim Failover.
    static let mirrors = [
        "https://de2.api.radio-browser.info",
        "https://de1.api.radio-browser.info",
        "https://fi1.api.radio-browser.info",
    ]

    /// Die Betreiber bitten um einen beschreibenden User-Agent (appname/version),
    /// damit sie Entwickler bei Problemen erreichen können.
    static var userAgent: String { "MuckeBaby/\(AppInfo.version)" }

    /// Häufigste Genre-Tags, absteigend nach Senderzahl.
    static func topTags(limit: Int = 200) async throws -> [RBTag] {
        try await get("/json/tags", [
            .init(name: "order", value: "stationcount"),
            .init(name: "reverse", value: "true"),
            .init(name: "hidebroken", value: "true"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Sender eines Genres, die beliebtesten zuerst.
    static func stations(tag: String, limit: Int = 100) async throws -> [RBStation] {
        // Tag steht im URL-Pfad -> encodieren (Tags können Leerzeichen/Umlaute enthalten).
        let enc = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedStrict) ?? tag
        return try await get("/json/stations/bytagexact/\(enc)", [
            .init(name: "order", value: "votes"),
            .init(name: "reverse", value: "true"),
            .init(name: "hidebroken", value: "true"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Freitextsuche über Sendernamen.
    static func stations(name: String, limit: Int = 100) async throws -> [RBStation] {
        try await get("/json/stations/search", [
            .init(name: "name", value: name),
            .init(name: "order", value: "votes"),
            .init(name: "reverse", value: "true"),
            .init(name: "hidebroken", value: "true"),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// „Klick" melden, wenn der Nutzer einen Sender wirklich anspielt — so bittet
    /// es die API-Doku (speist die Beliebtheits-Statistik). Fire-and-forget:
    /// Fehler sind egal, das Hören darf daran nie scheitern.
    static func countClick(stationUUID: String) {
        // UUID kommt aus der API, trotzdem defensiv encodieren (untrusted Input).
        guard let enc = stationUUID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedStrict) else { return }
        Task.detached(priority: .utility) {
            var req = URLRequest(url: URL(string: mirrors[0] + "/json/url/\(enc)")!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// GET mit Spiegel-Failover: erster Server, der antwortet UND dekodierbar
    /// liefert, gewinnt. Erst wenn alle scheitern, fliegt der letzte Fehler.
    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var lastError: Error = URLError(.badURL)
        for mirror in mirrors {
            guard var comps = URLComponents(string: mirror + path) else { continue }
            comps.queryItems = query
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error   // nächsten Spiegel probieren
            }
        }
        throw lastError
    }
}

extension CharacterSet {
    /// Wie .urlPathAllowed, aber ohne "/" — ein Tag wie "drum/bass" darf kein
    /// zusätzliches Pfadsegment aufmachen (Pfad-Injection in die API-URL).
    static let urlPathAllowedStrict: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()
}

// MARK: - Probehör-Player

/// Kleiner, eigenständiger VLC-Player NUR fürs Probehören im Katalog.
/// Bewusst getrennt vom Haupt-RadioPlayer: kein Verlauf, keine Aufnahme,
/// kein ICY-Reader — beim Schließen des Sheets ist alles wieder weg.
@MainActor
final class PreviewPlayer: ObservableObject {
    /// stationuuid des gerade spielenden/ladenden Senders (nil = still).
    @Published private(set) var currentID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failedID: String?   // letzter Sender, der nicht spielte

    private let player = VLCMediaPlayer()
    private let shim = PlayerDelegateShim()
    private var resolveTask: Task<Void, Never>?
    private var switches = PreviewSwitchCoordinator()

    init() {
        player.delegate = shim
        // Erstes Zeit-Event = spielt hörbar (state kann bei Live-Streams auf
        // .buffering hängen bleiben — gleiche Invariante wie im RadioPlayer).
        shim.onTime = { [weak self] in self?.isLoading = false }
        shim.onState = { [weak self] in self?.handleState() }
    }

    /// Probehören starten/stoppen (Klick auf denselben Sender = Stopp).
    func toggle(_ station: RBStation, volume: Float) {
        let action = switches.toggle(stationID: station.stationuuid)
        if case .stop = action {
            stop(invalidateGeneration: false)
            return
        }
        guard case let .replace(generation) = action else { return }

        // A -> B ersetzt das Medium direkt. Ein asynchroner stop() von A koennte
        // sonst erst nach B.play() eintreffen und die neue Vorschau abwuergen.
        resolveTask?.cancel()
        resolveTask = nil
        currentID = station.stationuuid
        failedID = nil
        isLoading = true
        let stationID = station.stationuuid
        guard let rawURL = StreamURLPolicy.validatedURL(station.streamURL) else {
            markFailed(generation: generation, stationID: stationID)
            return
        }
        resolveTask = Task { [weak self] in
            // Auch Katalog-URLs können Playlist-Container sein -> auflösen.
            let resolved = await PlaylistResolver.resolve(rawURL.absoluteString)
            guard let self, !Task.isCancelled else { return }
            guard self.switches.accepts(generation, stationID: stationID) else { return }
            guard let url = resolved else {
                self.markFailed(generation: generation, stationID: stationID)
                return
            }
            RadioBrowserAPI.countClick(stationUUID: stationID)
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=1500")
            self.player.media = media
            self.player.audio?.volume = Int32(max(0, min(1, volume)) * 100)
            self.player.play()
        }
    }

    func setVolume(_ v: Float) {
        player.audio?.volume = Int32(max(0, min(1, v)) * 100)
    }

    func stop() {
        stop(invalidateGeneration: true)
    }

    private func stop(invalidateGeneration: Bool) {
        if invalidateGeneration { switches.stop() }
        resolveTask?.cancel()
        resolveTask = nil
        if player.isPlaying || player.media != nil { player.stop() }
        currentID = nil
        isLoading = false
    }

    private func handleState() {
        switch player.state {
        case .error:
            markFailed()
        case .ended, .stopped:
            // Stream selbst zu Ende/abgerissen -> Zustand aufräumen. Ein manueller
            // stop() hat currentID schon genullt, dann ist das hier ein No-Op.
            if currentID != nil && !isLoading { currentID = nil }
        default:
            break
        }
    }

    private func markFailed(generation: UInt64? = nil, stationID: String? = nil) {
        if let generation, let stationID,
           !switches.accepts(generation, stationID: stationID) { return }
        failedID = currentID
        switches.stop()
        currentID = nil
        isLoading = false
        player.stop()
    }
}

// MARK: - Katalog-Sheet

/// Sender-Katalog: links die Genre-Liste (radio-browser-Tags, nach Senderzahl),
/// rechts die Sender des gewählten Genres bzw. die Namenssuche. Jede Zeile kann
/// probegehört und in die eigene Senderliste übernommen werden.
struct StationBrowserView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("volume") private var volume: Double = 0.77

    @StateObject private var preview = PreviewPlayer()

    @State private var tags: [RBTag] = []
    @State private var tagFilter = ""
    @State private var selectedTag: String?
    @State private var query = ""
    @State private var results: [RBStation] = []
    @State private var loading = false
    @State private var error = ""
    @State private var stationRequestTask: Task<Void, Never>?
    @State private var stationRequests = LatestRequestGeneration()
    /// Merkt in dieser Sitzung hinzugefügte Sender (sofortiges ✓ in der Zeile).
    @State private var addedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sender-Katalog").font(.headline)
            Text("Über 50.000 Sender aus der freien Community-Datenbank radio-browser.info — nach Genre stöbern oder per Name suchen, probehören und übernehmen.")
                .font(.caption).foregroundStyle(.secondary)

            // Freitextsuche (durchsucht alle Genres).
            HStack {
                TextField("Sendername, z. B. Hardstyle", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { searchByName() }
                Button("Suchen") { searchByName() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 0) {
                // Linke Spalte: Genres (Tags), gefiltert über das Suchfeld darüber.
                VStack(spacing: 6) {
                    TextField("Genre filtern …", text: $tagFilter)
                        .textFieldStyle(.roundedBorder)
                    List(filteredTags, selection: $selectedTag) { tag in
                        HStack {
                            Text(tag.name).lineLimit(1)
                            Spacer()
                            Text("\(tag.stationcount)")
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(tag.name)
                    }
                    .listStyle(.inset)
                }
                .frame(width: 210)

                Divider().padding(.horizontal, 8)

                // Rechte Spalte: Senderliste (Genre-Auswahl oder Suchtreffer).
                VStack(alignment: .leading, spacing: 6) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(.red).font(.caption)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if results.isEmpty {
                        Text("Links ein Genre wählen — oder oben nach Namen suchen.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        List(results) { st in
                            StationBrowserRow(
                                station: st,
                                inList: addedIDs.contains(st.stationuuid) || store.containsURL(st.streamURL),
                                preview: preview,
                                onPreview: { startPreview(st) },
                                onAdd: { add(st) }
                            )
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("Probehören stoppt die laufende Wiedergabe.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 780, height: 560)
        .task { await loadTags() }
        .onChange(of: selectedTag) { _, tag in
            if let tag { loadStations(tag: tag) }
        }
        // Probehör-Lautstärke folgt dem App-Regler live.
        .onChange(of: volume) { _, v in preview.setVolume(Float(v)) }
        // Sheet zu -> Probehören sicher beenden (nichts darf weiterlaufen).
        .onDisappear {
            stationRequestTask?.cancel()
            stationRequests.invalidate()
            preview.stop()
        }
    }

    private var filteredTags: [RBTag] {
        let f = tagFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(f) }
    }

    // MARK: Aktionen

    private func startPreview(_ st: RBStation) {
        // Nur EIN Ton zur Zeit: Hauptwiedergabe stoppen, dann Vorschau starten.
        if preview.currentID != st.stationuuid, player.isPlaying || player.isLoading {
            player.stop()
        }
        preview.toggle(st, volume: Float(volume))
    }

    private func add(_ st: RBStation) {
        guard let url = StreamURLPolicy.validatedURL(st.streamURL) else { return }
        if store.addIfNew(name: st.name, url: url.absoluteString) {
            addedIDs.insert(st.stationuuid)
        }
    }

    // MARK: Laden

    private func loadTags() async {
        guard tags.isEmpty else { return }
        do {
            // Mini-Tags (unter 5 Sendern) sind fast immer Tippfehler/Rauschen.
            tags = try await RadioBrowserAPI.topTags().filter { $0.stationcount >= 5 }
        } catch {
            self.error = String(localized: "Katalog nicht erreichbar: \(error.localizedDescription)")
        }
    }

    private func loadStations(tag: String) {
        startStationRequest { try await RadioBrowserAPI.stations(tag: tag) }
    }

    private func searchByName() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        selectedTag = nil
        startStationRequest { try await RadioBrowserAPI.stations(name: q) }
    }

    private func startStationRequest(
        _ operation: @escaping @MainActor () async throws -> [RBStation]
    ) {
        stationRequestTask?.cancel()
        let generation = stationRequests.begin()
        loading = true; error = ""; results = []
        stationRequestTask = Task {
            do {
                let loaded = try await operation()
                guard !Task.isCancelled, stationRequests.accepts(generation) else { return }
                results = loaded
                if loaded.isEmpty { error = String(localized: "Keine Treffer.") }
            } catch {
                guard !Task.isCancelled, stationRequests.accepts(generation) else { return }
                self.error = String(localized: "Suche fehlgeschlagen: \(error.localizedDescription)")
            }
            guard stationRequests.accepts(generation) else { return }
            loading = false
            stationRequestTask = nil
        }
    }
}

/// Eine Katalog-Zeile: Probehör-Knopf, Name + Details, Hinzufügen-Knopf.
private struct StationBrowserRow: View {
    let station: RBStation
    let inList: Bool
    @ObservedObject var preview: PreviewPlayer
    let onPreview: () -> Void
    let onAdd: () -> Void

    private var isPreviewing: Bool { preview.currentID == station.stationuuid }

    var body: some View {
        HStack(spacing: 10) {
            // Probehören (Klick auf denselben Sender stoppt wieder).
            Button(action: onPreview) {
                if isPreviewing && preview.isLoading {
                    ProgressView().controlSize(.small).frame(width: 18)
                } else {
                    Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isPreviewing ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(isPreviewing ? "Probehören stoppen" : "Probehören")

            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(station.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if preview.failedID == station.stationuuid {
                        Text("Stream nicht abspielbar").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()

            // Übernehmen in die eigene Senderliste (Dubletten per URL erkannt).
            Button(action: onAdd) {
                Image(systemName: inList ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(inList ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(inList)
            .help(inList ? "Bereits in der Senderliste" : "Zur Senderliste hinzufügen")
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI
import VLCKit

// Sender-Katalog: Stöbern in der freien Community-Datenbank radio-browser.info
// (nach Genre-Tags strukturiert). Rechtslage siehe
// THIRD-PARTY.md §4: Daten frei nutzbar, Stream-URLs sind Fakten; einzige Bitte
// der Betreiber ist ein beschreibender User-Agent — den senden wir mit.
//
// Katalogmodelle, HTTP-Client und Cache liegen in RadioBrowser.swift und CatalogCache.swift.
// Diese Datei enthält:
//  - PreviewPlayer:     eigener kleiner VLC-Player NUR fürs Probehören
//                       (kein Verlauf, keine Aufnahme, kein ICY-Reader).
//  - StationBrowserView: das Sheet — Genres links, Sender rechts,
//                       Probehören + „Zur Liste hinzufügen" pro Zeile.

// MARK: - Probehör-Player

/// Kleiner, eigenständiger VLC-Player NUR fürs Probehören im Katalog.
/// Bewusst getrennt vom Haupt-RadioPlayer: kein Verlauf, keine Aufnahme,
/// kein ICY-Reader — beim Schließen des Sheets ist alles wieder weg.
@MainActor
final class PreviewPlayer: ObservableObject {
    /// stationuuid des gerade spielenden/ladenden Senders (nil = still).
    /// Abgeleitet aus dem PreviewSwitchCoordinator als einzige Wahrheitsquelle.
    var currentID: String? { switches.currentID }
    @Published private(set) var isLoading = false
    @Published private(set) var failedID: String?   // letzter Sender, der nicht spielte

    private var player = VLCMediaPlayer()
    private var shim: PlayerDelegateShim?
    private var resolveTask: Task<Void, Never>?
    private var switches = PreviewSwitchCoordinator()

    /// Probehören starten/stoppen (Klick auf denselben Sender = Stopp).
    func toggle(_ station: RBStation, volume: Float) {
        objectWillChange.send()
        let action = switches.toggle(stationID: station.stationuuid)
        if case .stop = action {
            stop(invalidateGeneration: false)
            return
        }
        guard case let .replace(generation) = action else { return }

        // A bleibt waehrend der Aufloesung aktiv; B erhaelt anschliessend eine
        // eigene VLC-Instanz, damit spaete Ereignisse eindeutig A gehoeren.
        resolveTask?.cancel()
        resolveTask = nil
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
            let previous = self.player
            previous.delegate = nil
            self.player = VLCMediaPlayer()
            let nextShim = PlayerDelegateShim(
                onState: { [weak self] state in
                    guard let self, self.switches.accepts(generation, stationID: stationID),
                          self.switches.hasInstalledMedia else { return }
                    self.handleState(state)
                },
                onTime: { [weak self] in
                    guard let self, self.switches.accepts(generation, stationID: stationID),
                          self.switches.hasInstalledMedia else { return }
                    self.isLoading = false
                })
            self.shim = nextShim
            self.player.delegate = nextShim
            previous.stop()  // ein spaeter Stop erreicht niemals die neue Instanz
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=1500")
            self.player.media = media
            self.player.audio?.volume = Int32(max(0, min(1, volume)) * 100)
            // Ab hier gehoeren Player-Ereignisse zu DIESER Vorschau (siehe
            // hasInstalledMedia im Koordinator).
            self.switches.mediaInstalled(generation: generation, stationID: stationID)
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
        objectWillChange.send()
        if invalidateGeneration { switches.stop() }
        resolveTask?.cancel()
        resolveTask = nil
        if player.isPlaying || player.media != nil { player.stop() }
        isLoading = false
    }

    private func handleState(_ state: VLCMediaPlayerState) {
        switch state {
        case .error:
            // Nur ein Fehler des eigenen installierten Mediums zaehlt. Instanz
            // und Generation wurden bereits in der Delegate-Closure geprueft.
            guard switches.hasInstalledMedia else { return }
            markFailed()
        case .ended, .stopped:
            // Stream selbst zu Ende/abgerissen -> Zustand aufräumen. Ein manueller
            // stop() hat currentID schon genullt, dann ist das hier ein No-Op.
            // Den Übergang entscheidet der Koordinator (VLC-frei und im Harness
            // getestet), damit der Neustart desselben Senders funktioniert.
            if switches.finishTerminal() {
                objectWillChange.send()
                isLoading = false
            }
        default:
            break
        }
    }

    private func markFailed(generation: UInt64? = nil, stationID: String? = nil) {
        if let generation, let stationID,
           !switches.accepts(generation, stationID: stationID) { return }
        objectWillChange.send()
        failedID = switches.currentID
        switches.stop()
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
    @StateObject private var catalog = CatalogModel()
    @State private var tagFilter = ""
    @State private var addError = ""
    @State private var addedIDs: Set<String> = []
    var availableWidth: CGFloat = 780

    private var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "de") }
    private var dirty: Bool { catalog.draft.normalized != catalog.selection.query }
    private var selectedTag: Binding<String?> {
        Binding(get: { catalog.draft.tag.isEmpty ? nil : catalog.draft.tag }, set: { tag in
            catalog.draft.tag = tag ?? ""; catalog.search()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sender-Katalog").font(.headline)
            Text("Radio-Browser: Name, Land, Sprache, Genre und Katalogqualität gemeinsam filtern.")
                .font(.caption).foregroundStyle(.secondary)
            filters
            if catalog.facetsLoading {
                Text("Filterlisten werden geladen …").font(.caption).foregroundStyle(.secondary)
            } else if catalog.facetsUnavailable {
                Text("Einige Filterlisten sind derzeit nicht verfügbar. Gespeicherte Auswahl bleibt erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if catalog.loading { ProgressView().controlSize(.small) }
                Text(catalog.selection.query.summary).lineLimit(1).help(catalog.selection.query.summary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !catalog.cache.pages.isEmpty {
                    Menu("Gespeicherte Seiten") {
                        ForEach(catalog.cache.pages.reversed(), id: \.selection) { saved in
                            Button("\(saved.selection.query.summary) — Seite \(saved.selection.page + 1)") {
                                preview.stop(); catalog.showSaved(saved)
                            }
                        }
                    }
                    .accessibilityIdentifier("catalog-saved-pages")
                }
            }
            if dirty { Text("Suchauswahl geändert. Suchen übernimmt die Filter.").font(.caption).foregroundStyle(.secondary) }
            if let page = catalog.page, catalog.cached {
                Text("Gespeicherte Treffer vom \(page.fetchedAt.formatted(date: .abbreviated, time: .shortened)). Erreichbarkeit nicht geprüft.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalog-cache-status")
                if page.isStale(at: Date()) || catalog.unavailable {
                    Text("Diese Ergebnisse sind veraltet.").font(.caption).foregroundStyle(.orange)
                }
            }
            if let message = catalog.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let notice = catalog.cache.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if !addError.isEmpty { Text(addError).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    TextField("Genre filtern …", text: $tagFilter).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("catalog-genre-search")
                    List(filteredTags, selection: selectedTag) { tag in
                        HStack {
                            Text(tag.name).lineLimit(1)
                            Spacer()
                            Text("\(tag.stationcount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.tag(tag.name)
                    }.listStyle(.inset)
                }.frame(width: availableWidth < 700 ? 150 : 195)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let page = catalog.page, !page.stations.isEmpty {
                        List(page.stations) { station in
                            StationBrowserRow(station: station,
                                inList: addedIDs.contains(station.stationuuid) || store.containsURL(station.streamURL),
                                preview: preview, onPreview: { startPreview(station) }, onAdd: { add(station) })
                        }.listStyle(.inset)
                    } else {
                        Text(catalog.loading ? "Suche läuft …" : "Keine Treffer für diese Auswahl.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    HStack {
                        Button("Zurück") { changePage(-1) }
                            .disabled(catalog.loading || dirty || catalog.selection.page == 0)
                            .accessibilityIdentifier("catalog-previous-page")
                        Text("Seite \(catalog.selection.page + 1)").font(.caption)
                            .accessibilityIdentifier("catalog-page-number")
                        Spacer()
                        Button("Weiter") { changePage(1) }
                            .disabled(catalog.loading || dirty || catalog.page?.hasNext != true || catalog.selection.page >= 10_000)
                            .accessibilityIdentifier("catalog-next-page")
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
            Text("Die letzten 20 Suchseiten werden bis zu 2 MiB lokal gespeichert. Bitraten sind Katalogangaben; Mindestbitrate schließt unbekannte Werte aus.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Probehören stoppt die laufende Wiedergabe.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if preview.currentID != nil { Button("Probehören stoppen") { preview.stop() } }
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("catalog-close")
            }
        }
        .padding(18).frame(width: max(620, min(820, availableWidth)), height: 600)
        .task {
            catalog.load(catalog.selection)
            await catalog.loadFacets()
        }
        .onChange(of: volume) { _, value in preview.setVolume(Float(value)) }
        .onChange(of: catalog.page) { _, _ in preview.stop() }
        .onDisappear { catalog.cancel(); preview.stop() }
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Sendername", text: $catalog.draft.name).textFieldStyle(.roundedBorder)
                    .onSubmit { search() }.accessibilityIdentifier("catalog-name")
                Button("Suchen") { search() }.accessibilityIdentifier("catalog-search")
                Button("Zurücksetzen") { catalog.draft = CatalogQuery(); search() }
                    .accessibilityIdentifier("catalog-reset")
            }
            HStack {
                Picker("Land", selection: $catalog.draft.countryCode) {
                    Text("Alle Länder").tag("")
                    if !catalog.draft.countryCode.isEmpty, !catalog.facets.countries.contains(where: { $0.iso_3166_1 == catalog.draft.countryCode }) {
                        Text(catalog.draft.countryCode).tag(catalog.draft.countryCode)
                    }
                    ForEach(catalog.facets.countries.filter { facet in facet.iso_3166_1.map { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } } ?? false }) { country in
                        Text(locale.localizedString(forRegionCode: country.iso_3166_1!) ?? country.name).tag(country.iso_3166_1!)
                    }
                }.accessibilityIdentifier("catalog-country")
                Picker("Sprache", selection: $catalog.draft.language) {
                    Text("Alle Sprachen").tag("")
                    if !catalog.draft.language.isEmpty, !catalog.facets.languages.contains(where: { $0.name == catalog.draft.language }) {
                        Text(catalog.draft.language).tag(catalog.draft.language)
                    }
                    ForEach(catalog.facets.languages) { language in
                        Text(language.iso_639.flatMap { locale.localizedString(forLanguageCode: $0) } ?? language.name).tag(language.name)
                    }
                }.accessibilityIdentifier("catalog-language")
            }
            HStack {
                Picker("Codec", selection: $catalog.draft.codec) {
                    Text("Alle Codecs").tag("")
                    if !catalog.draft.codec.isEmpty, !catalog.facets.codecs.contains(where: { $0.name == catalog.draft.codec }) {
                        Text(catalog.draft.codec).tag(catalog.draft.codec)
                    }
                    ForEach(catalog.facets.codecs) { Text($0.name).tag($0.name) }
                }.accessibilityIdentifier("catalog-codec")
                Picker("Bitrate", selection: $catalog.draft.minimumBitrate) {
                    Text("Alle Bitraten").tag(0)
                    if ![0, 64, 128, 192, 256, 320].contains(catalog.draft.minimumBitrate) {
                        Text("≥ \(catalog.draft.minimumBitrate) kbps").tag(catalog.draft.minimumBitrate)
                    }
                    ForEach([64, 128, 192, 256, 320], id: \.self) { Text("≥ \($0) kbps").tag($0) }
                }.accessibilityIdentifier("catalog-bitrate")
                Picker("Sortierung", selection: $catalog.draft.sort) {
                    Text("Stimmen").tag(CatalogSort.votes)
                    Text("Name").tag(CatalogSort.name)
                }.accessibilityIdentifier("catalog-sort")
            }
            if !catalog.draft.tag.isEmpty {
                HStack {
                    Text("Genre: \(catalog.draft.tag)").font(.caption).lineLimit(1)
                    Button { catalog.draft.tag = ""; search() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Genrefilter entfernen").accessibilityLabel("Genrefilter entfernen")
                    Spacer()
                }
            }
        }
    }
    private var filteredTags: [RBTag] {
        catalog.facets.tags.filter { $0.stationcount >= 5 && (tagFilter.isEmpty || $0.name.range(of: tagFilter, options: [.caseInsensitive, .diacriticInsensitive]) != nil) }
    }
    private func search() { preview.stop(); catalog.search() }
    private func changePage(_ delta: Int) {
        preview.stop(); catalog.load(CatalogSelection(query: catalog.selection.query, page: catalog.selection.page + delta))
    }
    private func startPreview(_ station: RBStation) {
        if preview.currentID != station.stationuuid, player.isPlaying || player.isLoading { player.stop() }
        preview.toggle(station, volume: Float(volume))
    }
    private func add(_ station: RBStation) {
        addError = ""
        guard let url = StreamURLPolicy.validatedURL(station.streamURL) else { return }
        if store.addIfNew(name: station.name, url: url.absoluteString,
                          radioBrowserID: UUID(uuidString: station.stationuuid)) { addedIDs.insert(station.stationuuid) }
        else if store.persistenceFailed { store.persistenceFailed = false; addError = String(localized: "Die Senderliste konnte nicht gespeichert werden. Bitte den Speicherzugriff prüfen und erneut versuchen.") }
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
                ZStack {
                if isPreviewing && preview.isLoading {
                    ProgressView().controlSize(.small).frame(width: 18)
                } else {
                    Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle())
                        .foregroundStyle(isPreviewing ? Color.accentColor : Color.secondary)
                }
                }.frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPreviewing ? "Probehören stoppen" : "Probehören")
            .accessibilityLabel(isPreviewing ? "Probehören stoppen" : "Probehören")
            .accessibilityIdentifier("catalog-preview-" + station.stationuuid)

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
                    .font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
                    .foregroundStyle(inList ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(inList)
            .help(inList ? "Bereits in der Senderliste" : "Zur Senderliste hinzufügen")
            .accessibilityLabel(inList ? "Bereits in der Senderliste" : "Zur Senderliste hinzufügen")
            .accessibilityIdentifier("catalog-add-" + station.stationuuid)
        }
        .padding(.vertical, 2)
    }
}

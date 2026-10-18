import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreTransferable

// Rechtes Panel: "Verlauf" — gehoerte Titel mit Zeitspanne. Eintraege sind
// selektierbar; darunter Buttons, die den Song in Apple Music / Spotify oeffnen
// (bzw. im Web, falls die App fehlt). Neueste unten.
struct HistoryPanel: View {
    @EnvironmentObject var history: SongHistory
    @EnvironmentObject var player: RadioPlayer
    var onClose: () -> Void
    var onOpenRecordings: () -> Void = {}

    // Theme liefert Farben/Fonts/Texturen. `schlicht` (classic) loest exakt auf das
    // bisherige native Aussehen auf — alle Tokens sind dort semantisch
    // (textPrimary = .primary, panelBackground = windowBackgroundColor usw.).
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    // UI-Schriftfaktor (1.0 = normal). Wird hier durchgereicht, damit die
    // Theme-Fonts genauso mitzoomen wie das frueher per `scaledFont` der Fall war.
    @Environment(\.uiFontScale) private var uiFontScale

    @State private var selection: SongEntry.ID?
    @State private var lyricsFor: SongEntry?
    @State private var exportMsg = ""
    @State private var exportRequest: ExportEditorRequest?
    @State private var showDeleteAllRecordingsConfirmation = false
    @State private var filter = HistoryFilter()
    @State private var filterNow = Date()
    @State private var scrollAnchor: UUID?
    @State private var lastVisibleAnchor: UUID?
    @State private var followsLatest = true
    @State private var filterAnchor: UUID?
    @State private var filterRevision = 0
    @State private var isRestoringFilter = false
    @State private var displayedEntries: [SongEntry] = []
    @State private var recordings: RecordingLibrarySnapshot?

    // Verlauf-Tinte: auf der hellen Pergament-Textur (retro) waere der dunkle
    // Theme-Text unlesbar -> dort eine dunkle Tinte erzwingen. Sonst der normale
    // Haupt-/Nebentext aus der Palette.
    private var historyInk: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var historyInkDim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var historyActionInk: Color { theme.id == .retro ? Color(hex: "#6B5432") : theme.palette.textSecondary }

    /// Beschriftung eines Verlauf-Aktions-Buttons: Icon oben, kurzer Text darunter.
    /// Vertikal, damit die vier Buttons auch in der schmalen Verlauf-Spalte nebeneinander passen.
    @ViewBuilder
    private func historyActionLabel(_ system: String, _ text: String) -> some View {
        VStack(spacing: 2) {
            // Feste Icon-Box: SF-Symbole haben unterschiedliche Glyphenhoehen (z.B. „text.quote"
            // ist niedriger als „music.note") -> ohne fixe Hoehe sitzt der Text je Button anders.
            // Gleich hohe Box + .bottom-Ausrichtung der Reihe -> alle Labels exakt unten buendig.
            Image(systemName: system).font(.system(size: 13))
                .frame(height: 15)
            Text(text)
                .themedFont(theme, .label, size: 9 * uiFontScale)
                .lineLimit(1)
        }
        .foregroundStyle(historyActionInk)
        .frame(minWidth: 38)
        .contentShape(Rectangle())
    }

    private func clean(_ comp: Calendar.Component, _ value: Int) {
        let cutoff = Calendar.current.date(byAdding: comp, value: -value, to: Date()) ?? Date()
        player.cleanupHistory(olderThan: cutoff)
    }

    // Nur die Aufnahme-Dateien (+ Index) aelter als der Cutoff loeschen — der
    // Verlauf bleibt vollstaendig erhalten. Man sieht also weiter, welche Songs
    // liefen; nur der Export ("Keine Aufnahme zu diesem Titel.") geht dann nicht mehr.
    private func cleanRecordings(_ comp: Calendar.Component, _ value: Int) {
        let cutoff = Calendar.current.date(byAdding: comp, value: -value, to: Date()) ?? Date()
        player.recorder.prune(olderThan: cutoff)
    }

    private var selectedEntry: SongEntry? {
        guard let entry = history.entries.first(where: { $0.id == selection }) else { return nil }
        return filter.apply(to: [entry], now: filterNow).first
    }
    // Bei einem Mitschnitt-Platzhalter gibt es keinen Songtitel -> Musik-/
    // Songtext-Suche sinnlos; nur der Export bleibt aktiv.
    private var selectedIsLookup: Bool {
        guard let e = selectedEntry else { return false }
        return !e.isPlaceholder
    }

    // Titel des Panels. midi spricht Terminal: "PLAYBACK_HISTORY"; sonst "Verlauf".
    // `SectionHeader` uebernimmt Tracking/Uppercase/Titel-Font/textSecondary aus dem Theme.
    private var headerTitle: String { theme.id == .midi ? "PLAYBACK_HISTORY" : "Verlauf" }

    var body: some View {
        let visible = filter.apply(to: history.entries, now: filterNow)
        return VStack(spacing: 0) {
            HStack {
                // classic (schlicht): wie bisher der schlichte Headline-Text.
                // console: stilisierter SectionHeader (Tracking/Uppercase je Theme).
                if theme.isConsole {
                    SectionHeader(headerTitle)
                } else {
                    Text("Verlauf").themedFont(theme, .title, size: 13 * uiFontScale, weight: .semibold)
                        .foregroundColor(theme.palette.textPrimary)
                }
                Spacer()
                Button(action: onOpenRecordings) { Image(systemName: "waveform") }
                    .buttonStyle(.plain).help("Aufnahmebibliothek")
                    .accessibilityLabel("Aufnahmebibliothek")
                    .accessibilityIdentifier("recordings-open")
                Menu {
                    // Erster Satz: Verlauf-Eintraege UND die zugehoerigen Aufnahmen
                    // bis zum Cutoff loeschen (bisheriges Verhalten, cleanupHistory).
                    Section("Verlauf und Aufnahmen") {
                        Button("Älter als 1 Tag löschen") { clean(.day, 1) }
                        Button("Älter als 1 Woche löschen") { clean(.day, 7) }
                        Button("Älter als 1 Monat löschen") { clean(.month, 1) }
                    }
                    // Zweiter Satz: NUR die lokalen Aufnahme-Dateien loeschen,
                    // der Verlauf (welche Songs liefen) bleibt komplett stehen.
                    Section("Nur Aufnahmen (Verlauf bleibt)") {
                        Button("Älter als 1 Tag löschen") { cleanRecordings(.day, 1) }
                        Button("Älter als 1 Woche löschen") { cleanRecordings(.day, 7) }
                        Button("Älter als 1 Monat löschen") { cleanRecordings(.month, 1) }
                        // .distantFuture als Cutoff = jede abgeschlossene Aufnahme ist
                        // "aelter" -> alle weg. Eine gerade LAUFENDE Aufnahme (end == nil,
                        // offenes FileHandle) bleibt bewusst bestehen.
                        Button("Alle Aufnahmen löschen", role: .destructive) {
                            showDeleteAllRecordingsConfirmation = true
                        }
                    }
                    Divider()
                    Button("Gesamten Verlauf löschen", role: .destructive) { history.clear() }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(historyActionInk) }
                    .menuStyle(.borderlessButton).fixedSize().help("Verlauf-Optionen")
                Button { onClose() } label: { Image(systemName: "sidebar.trailing").foregroundStyle(historyActionInk) }
                    .buttonStyle(.plain).help("Verlauf ausblenden")
            }
            .padding(10)
            Divider()
            filterControls(count: visible.count)
            Divider()
            historyList(visible)

            Divider()
            // Aktionen fuer den ausgewaehlten Titel — Icon UND Text.
            // Vertikal (Icon oben, Label unten) bleibt schmal genug fuer die enge Spalte.
            // .bottom: alle Labels liegen unten buendig (Icon-Box gleicht Glyphenhoehen aus).
            HStack(alignment: .bottom, spacing: 4) {
                // Apple Music: das Apple-Logo-Zeichen (U+F8FF) statt des Wortes „Apple".
                Button { if let e = selectedEntry { SongActions.openInMusic(e) } } label: {
                    historyActionLabel("music.note", "\u{F8FF} Music")
                }.buttonStyle(.plain).help("In Apple Music suchen").disabled(!selectedIsLookup)
                Button { if let e = selectedEntry { SongActions.openInSpotify(e) } } label: {
                    historyActionLabel("music.note.list", "Spotify")
                }.buttonStyle(.plain).help("In Spotify / im Web suchen").disabled(!selectedIsLookup)
                Button { lyricsFor = selectedEntry } label: {
                    historyActionLabel("text.quote", "Lyrics")
                }.buttonStyle(.plain).help("Songtext anzeigen").disabled(!selectedIsLookup)
                // Derselbe Dialog behandelt Vorschau, Schnittgrenzen und Übergänge.
                Button { openExportEditor() } label: {
                    historyActionLabel("square.and.arrow.up", "Export")
                }
                .buttonStyle(.plain)
                .help(canExportSelection ? String(localized: "Song vorhören, Schnittgrenzen korrigieren und exportieren")
                      : String(localized: "Für diesen Titel ist kein verfügbares Audio vorhanden."))
                .disabled(!canExportSelection).accessibilityIdentifier("history-export")
                Spacer(minLength: 0)
                if !exportMsg.isEmpty {
                    Text(exportMsg)
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.textSecondary).lineLimit(1)
                }
            }
            .disabled(selectedEntry == nil)
            .padding(8)
        }
        // Panel-Hintergrund aus dem Theme.
        // retro: echte paper.png-Textur mit leichtem Creme-Scrim (Gleichmäßigkeit),
        //        damit die dunkle Tinte (#2A2018) gut lesbar bleibt.
        //        Fallback: prozedurales Pergament wenn paper.png fehlt.
        //        Alle anderen Themes: ThemedSurface(.panel).
        .background {
            SongListSurface()
        }
        .confirmationDialog(
            "Alle Aufnahmen endgültig löschen?",
            isPresented: $showDeleteAllRecordingsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                player.recorder.deleteAllCompleted()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle abgeschlossenen Aufnahme-Dateien werden endgültig gelöscht. Der Verlauf bleibt erhalten. Eine laufende Aufnahme wird nicht gelöscht.")
        }
        .sheet(item: $lyricsFor) { e in
            LyricsView(artist: e.artist ?? "", title: e.title ?? e.raw)
        }
        .sheet(item: $exportRequest) { request in ExportEditorView(request: request) }
        .onChange(of: history.entries.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            if filter.period != .all { filterNow = date }
        }
        .task {
            while !Task.isCancelled {
                let next = await player.recorder.librarySnapshot()
                guard !Task.isCancelled else { return }
                recordings = next
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var filterBinding: Binding<HistoryFilter> {
        Binding(get: { filter }, set: { value in updateFilter { $0 = value } })
    }

    private func updateFilter(_ change: (inout HistoryFilter) -> Void) {
        var value = filter
        change(&value)
        guard value != filter else { return }
        if !isRestoringFilter { filterAnchor = scrollAnchor ?? lastVisibleAnchor }
        isRestoringFilter = true
        filter = value
        filterRevision += 1
    }

    private func filterControls(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(historyInkDim)
                TextField("Titel oder Interpret suchen", text: filterBinding.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("history-search")
                if !filter.query.isEmpty {
                    Button { updateFilter { $0.query = "" } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(historyInkDim)
                        .help("Suche löschen").accessibilityLabel("Suche löschen")
                }
            }
            .padding(7)
            .background(historyInk.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Menu {
                    Button("Alle Sender") { updateFilter { $0.station = nil } }
                    Divider()
                    ForEach(HistoryFilter.stations(in: history.entries), id: \.self) { station in
                        Button { updateFilter { $0.station = station } } label: {
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
                        Button { updateFilter { $0.period = period }; filterNow = Date() } label: {
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
                DatePicker("Von", selection: filterBinding.firstDay, in: ...filter.lastDay, displayedComponents: .date)
                DatePicker("Bis", selection: filterBinding.lastDay, in: filter.firstDay..., displayedComponents: .date)
            }
            HStack {
                Text("\(count) von \(history.entries.count) Titeln")
                    .foregroundStyle(historyInkDim)
                    .accessibilityIdentifier("history-result-count")
                Spacer(minLength: 4)
                Button("Zurücksetzen") { updateFilter { $0 = HistoryFilter() }; filterNow = Date() }
                    .buttonStyle(.plain)
                    .disabled(!filter.isActive)
                    .help("Alle Verlaufsfilter zurücksetzen")
                    .accessibilityIdentifier("history-reset-filters")
            }
        }
        .font(theme.font(.label, size: 11 * uiFontScale))
        .foregroundStyle(historyInk)
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
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

    private func historyList(_ visible: [SongEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Button { selection = entry.id } label: {
                                    SongRow(entry: entry, audioLabel: recordings?.audio(for: entry).label)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection == entry.id ? [.isSelected] : [])
                                .accessibilityIdentifier("history-song-\(entry.id)")
                                // Der Export beginnt erst beim Drop und blockiert die Auswahl nicht.
                                .draggable(DraggableSong(entry: entry, recorder: player.recorder))
                                if !entry.isPlaceholder {
                                    BookmarkButton(song: entry, identifier: "bookmark-history-\(entry.id)",
                                                   tint: theme.id == .retro ? historyActionInk : nil)
                                }
                            }
                            .background(selection == entry.id ? theme.palette.selection : Color.clear)
                            Rectangle().fill(theme.palette.divider.opacity(0.5)).frame(height: 1)
                        }
                        .id(entry.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    HistoryScrollObserver { atEnd in
                        if displayedEntries == history.entries, followsLatest != atEnd { followsLatest = atEnd }
                    }
                }
            }
            .scrollPosition(id: Binding(get: { scrollAnchor }, set: { id in
                // Ein neues Layout darf den Leseanker nicht überschreiben,
                // bevor eine entfallene Lesestelle ersetzt wurde.
                guard !isRestoringFilter, displayedEntries == history.entries else { return }
                scrollAnchor = id
                if let id { lastVisibleAnchor = id }
            }), anchor: .top)
            .overlay {
                if visible.isEmpty {
                    VStack(spacing: 10) {
                        Text(history.entries.isEmpty ? String(localized: "Noch nichts gehört.")
                             : String(localized: "Keine Titel für diese Filter."))
                            .multilineTextAlignment(.center)
                        if filter.isActive {
                            Button("Filter zurücksetzen") { updateFilter { $0 = HistoryFilter() } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .themedFont(theme, .body, size: 12 * uiFontScale)
                    .foregroundStyle(historyInkDim)
                    .padding(16)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest && !visible.isEmpty {
                    Button {
                        if let last = visible.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    } label: { Label("Neueste anzeigen", systemImage: "arrow.down.to.line") }
                        .font(theme.font(.label, size: 10 * uiFontScale))
                        .buttonStyle(.bordered)
                        .padding(8)
                }
            }
            .onChange(of: filterRevision) { _, revision in
                let retained = HistoryFilter.retainedAnchor(filterAnchor, entries: history.entries, visible: visible)
                // SwiftUI muss die neue LazyVStack erst einsetzen, bevor scrollTo
                // ihre IDs auflösen kann. Währenddessen den alten Leseanker behalten.
                DispatchQueue.main.async {
                    guard revision == filterRevision else { return }
                    if let retained {
                        scrollAnchor = retained
                        proxy.scrollTo(retained, anchor: .top)
                        lastVisibleAnchor = retained
                    }
                    isRestoringFilter = false
                }
            }
            .onChange(of: visible.map(\.id)) { _, ids in
                guard !isRestoringFilter, displayedEntries == history.entries,
                      !ids.isEmpty, filter.isActive || !followsLatest,
                      let previous = lastVisibleAnchor, !ids.contains(previous) else { return }
                if let retained = HistoryFilter.retainedAnchor(lastVisibleAnchor, entries: history.entries, visible: visible) {
                    proxy.scrollTo(retained, anchor: .top)
                }
            }
            .onChange(of: history.entries) { old, entries in
                let follow = !filter.isActive && followsLatest && old.last?.id != entries.last?.id
                let retained = HistoryFilter.retainedAnchor(lastVisibleAnchor, entries: entries, visible: visible)
                DispatchQueue.main.async {
                    guard entries == history.entries else { return }
                    if follow, let last = visible.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    // Erhaltene Zeilen behalten ihren Pixeloffset; scrollTo würde
                    // auch bei bloßem Anhängen oder einer Endzeitänderung einrasten.
                    } else if let previous = lastVisibleAnchor,
                              !visible.contains(where: { $0.id == previous }), let retained {
                        scrollAnchor = retained
                        proxy.scrollTo(retained, anchor: .top)
                        lastVisibleAnchor = retained
                    }
                    displayedEntries = entries
                }
            }
            .onAppear {
                displayedEntries = history.entries
                if let last = visible.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Export (Aufnahme -> Song-Datei)

    // Quelldatei + Offset/Dauer fuer einen Verlauf-Eintrag bestimmen.
    private func sourceInfo(_ e: SongEntry) -> (url: URL, offset: Double, duration: Double)? {
        player.recorder.exportSource(for: e)
    }

    private var canExportSelection: Bool {
        guard let entry = selectedEntry else { return false }
        return recordings?.audio(for: entry).source != nil
    }

    // Dateiname aus untrustwuerdigem ICY-Titel: gleiche Whitelist wie Recorder.fileName.
    // Reines "/"-Ersetzen liess NUL (bricht den Zielpfad), fuehrendes "." (versteckte
    // Datei) und ":" (Finder zeigt es als "/") durch. Leeres/punkt-fuehrendes Ergebnis
    // mit "Song_" praefixen.
    static func safeFileBase(_ raw: String) -> String {
        SongExporter.safeFileBase(raw)
    }

    private func openExportEditor() {
        guard let e = selectedEntry, let info = sourceInfo(e) else {
            exportMsg = String(localized: "Keine Aufnahme zu diesem Titel."); return
        }
        exportMsg = ""
        exportRequest = ExportEditorRequest(entry: e, source: info.url, offset: info.offset, duration: info.duration,
                                            availableWidth: (NSApp.keyWindow?.frame.width ?? 840) - 80,
                                            availableHeight: (NSApp.keyWindow?.frame.height ?? 760) - 80)
    }
}

struct SongListSurface: View {
    @Environment(\.theme) private var theme
    var body: some View {
        if theme.id == .retro { ParchmentBackground(texture: theme.image(theme.panelTexture)) }
        else { ThemedSurface(.panel) }
    }
}

// MARK: - ParchmentBackground

/// Heller Pergament-Hintergrund für die gemeinsamen Songlisten im Retro-Theme.
/// Wenn `texture` übergeben wird (paper.png), wird die echte PNG-Textur mit einem
/// leichten Creme-Scrim überlagert — das sorgt für gleichmäßige Helligkeit und
/// sichert die Lesbarkeit der dunklen Tinte (#2A2018).
/// Fehlt die Textur (nil), greift der prozedurale Fallback.
private struct ParchmentBackground: View {

    /// Optionale echte Papier-Textur aus dem Bundle (paper.png).
    var texture: Image?

    var body: some View {
        if let tex = texture {
            // Echte Textur + leichter Creme-Scrim für Gleichmäßigkeit.
            // WICHTIG: Creme-Farbe als Größen-Geber (füllt exakt das Angebot), Textur als
            // OVERLAY. Sonst wuchs der ZStack auf die scaledToFill-Bildgröße und das
            // History-Panel wurde breiter als sein `.frame(width:)` → drückte die Stage
            // zusammen („zu viel Rand rechts"). Gleiches Muster wie in ThemedSurface.
            Color(hex: "#E9DEC4")
                .overlay { tex.resizable().scaledToFill() }
                .overlay { Color(hex: "#E9DEC4").opacity(0.25) }
                .clipped()
        } else {
            // Prozeduraler Fallback: warmes Papiergelb + Canvas-Noise
            proceduralParchment
        }
    }

    /// Prozeduraler Fallback wenn paper.png fehlt.
    @ViewBuilder private var proceduralParchment: some View {
        // Creme-Basis: warmes Papiergelb
        Color(hex: "#E9DEC4")
            .overlay {
                Canvas { context, size in
                    // LCG-Hash für deterministische Platzierung (kein random())
                    var seed: UInt32 = 0xF7A8_B9CA
                    func next() -> Double {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        return Double(seed) / Double(UInt32.max)
                    }

                    // Feine horizontale Fasern (leicht gewellt, sehr niedrige Alpha)
                    let fiberCount = 60
                    for _ in 0..<fiberCount {
                        let y = next() * Double(size.height)
                        let alpha = 0.04 + next() * 0.06  // 0.04…0.10
                        let col: Color = next() > 0.4
                            ? Color(hex: "#A0896A").opacity(alpha)   // warme Faser
                            : Color(hex: "#C8B899").opacity(alpha)   // helle Faser
                        var path = Path()
                        // Leichte Kurve (3 Punkte) statt gerader Linie → organischer
                        let cx = next() * Double(size.width)
                        let cy = y + (next() - 0.5) * 6
                        path.move(to: CGPoint(x: 0, y: y + (next() - 0.5) * 4))
                        path.addQuadCurve(
                            to: CGPoint(x: size.width, y: y + (next() - 0.5) * 4),
                            control: CGPoint(x: cx, y: cy)
                        )
                        context.stroke(path, with: .color(col), lineWidth: 0.6)
                    }

                    // Kleine Flecken (Altersflecken / Knötchen im Papier)
                    let speckCount = 80
                    for _ in 0..<speckCount {
                        let x = next() * Double(size.width)
                        let y = next() * Double(size.height)
                        let r = 0.5 + next() * 2.5
                        let alpha = 0.03 + next() * 0.07
                        let warm = next() > 0.5
                        let col: Color = warm
                            ? Color(hex: "#8C7050").opacity(alpha)   // Dunkelbraun-Fleck
                            : Color(hex: "#D4C4A0").opacity(alpha)   // Hellbeige-Aufheller
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(col))
                    }

                    // Leichte Vignette (Randvergilbung)
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .clear, location: 0.50),
                                .init(color: Color(hex: "#B09870").opacity(0.10), location: 1.0)
                            ]),
                            center: .init(x: 0.5, y: 0.5),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.70
                        )
                    )
                }
            }
    }
}

// Eine Verlaufszeile: Zeitspanne, Titel, Sender.
struct SongRow: View {
    let entry: SongEntry
    var showsInterval = true
    var audioLabel: String? = nil

    // Theme + Schriftfaktor wie im Panel. SongRow liest beide selbst aus dem
    // Environment (kein Durchreichen noetig).
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; return f
    }()
    private var isLive: Bool { showsInterval && entry.end == nil }

    // Verlauf-Tinte: retro-Pergament ist hell -> dunkle Tinte erzwingen, sonst
    // unlesbar. Sonst die normalen Palette-Farben.
    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var inkDim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    // Zeitstempel: midi-Terminal hebt sie in Neon-Akzent (accent2/Cyan) hervor.
    private var timeColor: Color { theme.id == .midi ? theme.palette.accent2 : inkDim }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Platzhalter (Mitschnitt-Session) bekommt ein Aufnahme-Symbol,
                // ein laufender echter Titel das Funkwellen-Symbol. Farben aus
                // dem Theme: Aufnahme = alert (rot), Live = liveBadge.
                if entry.isPlaceholder {
                    Image(systemName: "record.circle")
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.alert)
                } else if isLive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.liveBadge)
                }
                Text(timeRange)
                    .themedFont(theme, .body, size: 11 * uiFontScale)
                    .foregroundColor(timeColor)
            }
            Text(songText)
                .themedFont(theme, .body, size: 12 * uiFontScale, weight: isLive ? .semibold : .regular)
                .foregroundColor(entry.isPlaceholder ? inkDim : ink)
                .lineLimit(2)
            Text(entry.station)
                .themedFont(theme, .body, size: 10 * uiFontScale)
                .foregroundColor(inkDim)
            if let audioLabel {
                Text(audioLabel)
                    .themedFont(theme, .label, size: 10 * uiFontScale)
                    .foregroundStyle(inkDim)
                    .accessibilityIdentifier("history-audio-" + entry.id.uuidString)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var songText: String {
        if entry.isPlaceholder { return isLive ? "Mitschnitt (läuft …)" : "Mitschnitt" }
        if let a = entry.artist, let t = entry.title { return "\(a) – \(t)" }
        return entry.title ?? entry.raw
    }
    private var timeRange: String {
        let s = Self.dayFmt.string(from: entry.start) + " · " + Self.timeFmt.string(from: entry.start)
        if !showsInterval { return s }
        if let e = entry.end { return "\(s) – \(Self.timeFmt.string(from: e))" }
        return "\(s) – …"
    }
}

// Kleiner Font-Helfer: routet einen festen Text durch den Theme-Font-Resolver
// (`theme.font(slot, size:weight:)`). Fuer schlicht liefert der Resolver
// `.system(size:weight:)` — bei gleicher Groesse also identisch zum frueheren
// `scaledFont`. Console-Themes bekommen ihre eigene Schriftfamilie (Serif/Mono/…).
// `size` schon mit dem uiFontScale multipliziert uebergeben.
private extension View {
    func themedFont(_ theme: Theme, _ slot: FontSlot, size: CGFloat,
                    weight: Font.Weight = .regular) -> some View {
        self.font(theme.font(slot, size: size, weight: weight))
    }
}

// Drag&Drop-Export eines Verlauf-Eintrags als .m4a. Der Schnitt/Export laeuft erst
// beim Drop in der (off-main) Transferable-Closure -> blockiert die Klick-Selektion
// in der Liste NICHT (anders als das alte synchrone `.onDrag` mit q.sync auf Main).
struct DraggableSong: Transferable {
    let entry: SongEntry
    let recorder: Recorder

    var fileName: String {
        fileBase + ".m4a"
    }

    private var fileBase: String {
        let base = (entry.artist.map { "\($0) - " } ?? "") + (entry.title ?? entry.raw)
        return HistoryPanel.safeFileBase(base)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { song in
            guard let info = song.recorder.exportSource(for: song.entry) else {
                throw SongExporter.ExportError.noSession
            }
            let tmp = try await SongExporter.exportTemporary(source: info.url, offset: info.offset,
                                                            duration: info.duration, name: song.fileBase)
            return SentTransferredFile(tmp)
        }
        .suggestedFileName { $0.fileName }
    }
}

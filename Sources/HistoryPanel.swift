import SwiftUI
import AppKit

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
    @State private var batchRequest: ExportBatchRequest?
    @State private var selectingMultiple = false
    @State private var batchSelection = Set<UUID>()
    @State private var showDeleteAllRecordingsConfirmation = false
    @State private var showClearHistoryConfirmation = false
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
        .foregroundStyle(theme.palette.songListActions)
        .frame(minWidth: 38)
        .contentShape(Rectangle())
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

    var body: some View {
        let visible = filter.apply(to: history.entries, now: filterNow)
        return VStack(spacing: 0) {

            HistoryPanelHeader(
                onClose: onClose,
                onOpenRecordings: onOpenRecordings,
                showDeleteAllRecordingsConfirmation: $showDeleteAllRecordingsConfirmation,
                showClearHistoryConfirmation: $showClearHistoryConfirmation
            )
            Divider()
            HistoryFilterControls(
                filter: filterBinding,
                entries: history.entries,
                resultCount: visible.count,
                onRefreshDate: { filterNow = Date() }
            )
            Divider()
            historyList(visible)

            Divider()
            if selectingMultiple {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(batchSelection.count) ausgewählt · maximal 100")
                        .font(theme.font(.label, size: 10 * uiFontScale)).foregroundStyle(theme.palette.songListSecondary)
                    HStack {
                        Button("Exportieren …") { openBatchExport() }.disabled(batchSelection.isEmpty)
                            .accessibilityIdentifier("history-batch-export")
                        Spacer(minLength: 0)
                        Button {
                            selectingMultiple = false
                            batchSelection.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle").frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain).help("Mehrfachauswahl beenden")
                            .accessibilityLabel("Mehrfachauswahl beenden").accessibilityIdentifier("history-batch-end")
                    }
                }
                .padding(8)
                .foregroundStyle(theme.palette.songListText)
                .environment(\.colorScheme, theme.palette.parchment == nil ? colorScheme : .light)
                Divider()
            }
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
                Menu {
                    Toggle("Mehrere Titel auswählen", isOn: $selectingMultiple)
                    Button(visible.count > ExportQueue.limit ? String(localized: "Erste 100 Treffer auswählen")
                           : String(localized: "Alle Treffer auswählen")) {
                        selectingMultiple = true
                        batchSelection = Set(visible.prefix(ExportQueue.limit).map(\.id))
                    }.disabled(visible.isEmpty)
                    Button("Auswahl aufheben") { batchSelection.removeAll() }.disabled(batchSelection.isEmpty)
                    Button("Auswahl exportieren …") { openBatchExport() }.disabled(batchSelection.isEmpty)
                } label: {
                    Image(systemName: "chevron.down").foregroundStyle(theme.palette.songListActions)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(width: 28, height: 28).help("Exportoptionen")
                .accessibilityLabel("Exportoptionen").accessibilityIdentifier("history-export-options")
                Spacer(minLength: 0)
                if !exportMsg.isEmpty {
                    Text(exportMsg)
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.textSecondary).lineLimit(1)
                }
            }
            .padding(8)
        }
        // Panel-Hintergrund aus dem Theme.
        // retro: echte paper.png-Textur mit leichtem Creme-Scrim (Gleichmäßigkeit),
        //        damit die dunkle Tinte gut lesbar bleibt.
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
        .confirmationDialog(
            "Gesamten Verlauf endgültig löschen?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                history.clear()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Einträge im Verlauf werden endgültig gelöscht. Aufnahmen bleiben erhalten.")
        }
        .sheet(item: $lyricsFor) { e in
            LyricsView(artist: e.artist ?? "", title: e.title ?? e.raw)
        }
        .sheet(item: $exportRequest) { request in ExportEditorView(request: request) }
        .sheet(item: $batchRequest) { request in ExportBatchView(request: request) }
        .onChange(of: selectingMultiple) { _, enabled in
            if !enabled { batchSelection.removeAll() }
        }
        .onChange(of: history.entries.map(\.id)) { _, ids in
            batchSelection.formIntersection(ids)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            if filter.period != .all { filterNow = date }
        }
        .task {
            for await next in player.recorder.libraryUpdates() {
                guard !Task.isCancelled else { return }
                recordings = next
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

    private func historyList(_ visible: [SongEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                if selectingMultiple {
                                    Toggle("Zum Stapelexport auswählen", isOn: batchSelectionBinding(for: entry.id))
                                        .labelsHidden().toggleStyle(.checkbox)
                                        .disabled(!batchSelection.contains(entry.id) && batchSelection.count >= ExportQueue.limit)
                                        .accessibilityLabel("Zum Stapelexport auswählen: \(entry.artist ?? "") \(entry.title ?? entry.raw)")
                                        .accessibilityIdentifier("history-batch-select-\(entry.id)")
                                        .padding(.leading, 4)
                                }
                                Button { selection = entry.id } label: {
                                    SongRow(entry: entry, audioLabel: recordings?.audio(for: entry).label)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection == entry.id ? [.isSelected] : [])
                                .accessibilityIdentifier("history-song-\(entry.id)")
                                // Die Dateidarstellung rendert erst auf Abruf, außerhalb des Main-Threads.
                                .onDrag { dragProvider(for: entry) }
                                if !entry.isPlaceholder {
                                    BookmarkButton(
                                        song: entry,
                                        identifier: "bookmark-history-\(entry.id)",
                                        tint: theme.palette.parchment?.actions
                                    )
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
                    .foregroundStyle(theme.palette.songListSecondary)
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
                        .foregroundStyle(theme.palette.songListText)
                        .environment(\.colorScheme, theme.palette.parchment == nil ? colorScheme : .light)
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
                var followedID: UUID?
                if !selectingMultiple, let latest = visible.last,
                   latest.id == entries.last?.id,
                   !old.contains(where: { $0.id == latest.id }),
                   selection == nil || selection == old.last?.id {
                    selection = latest.id
                    followedID = latest.id
                } else if let selection, !entries.contains(where: { $0.id == selection }) {
                    self.selection = nil
                }
                let retained = HistoryFilter.retainedAnchor(lastVisibleAnchor, entries: entries, visible: visible)
                DispatchQueue.main.async {
                    // Eine Endzeitänderung kann eintreffen, bevor der neue Titel sichtbar gescrollt wird.
                    let shouldFollow = followedID != nil && !selectingMultiple && selectedEntry?.id == followedID
                    if let followedID, shouldFollow {
                        proxy.scrollTo(followedID)
                    }
                    guard entries == history.entries else { return }
                    // Erhaltene Zeilen behalten ihren Pixeloffset; scrollTo würde
                    // auch bei bloßem Anhängen oder einer Endzeitänderung einrasten.
                    if !shouldFollow, let previous = lastVisibleAnchor,
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
                if let last = visible.last {
                    if selection == nil, last.id == history.entries.last?.id, last.end == nil {
                        selection = last.id
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func batchSelectionBinding(for id: SongEntry.ID) -> Binding<Bool> {
        Binding(
            get: { batchSelection.contains(id) },
            set: { selected in
                if !selected {
                    batchSelection.remove(id)
                } else if batchSelection.count < ExportQueue.limit {
                    batchSelection.insert(id)
                }
            }
        )
    }

    // MARK: - Export (Aufnahme -> Song-Datei)

    private var canExportSelection: Bool {
        guard let entry = selectedEntry else { return false }
        return recordings?.audio(for: entry).source != nil
    }

    // Gemeinsame Unicode- und Pfadgrenzen für Einzel-, Drag- und Stapelexport.
    static func safeFileBase(_ raw: String) -> String {
        SongExporter.safeFileBase(raw)
    }

    private func openExportEditor() {
        guard let e = selectedEntry else { return }
        let availability = player.recorder.audioAvailability(for: e)
        guard let info = availability.source else {
            exportMsg = String(localized: "Keine Aufnahme zu diesem Titel.")
            return
        }
        exportMsg = ""
        exportRequest = ExportEditorRequest(entry: e, source: info.url, offset: info.offset, duration: info.duration,
                                            partialRecording: availability.isPartial,
                                            availableWidth: (NSApp.keyWindow?.frame.width ?? 840) - 80,
                                            availableHeight: (NSApp.keyWindow?.frame.height ?? 760) - 80)
    }

    private func dragProvider(for entry: SongEntry) -> NSItemProvider {
        let recorder = player.recorder
        let metadata = SongExportMetadata(raw: entry.raw, artist: entry.artist, title: entry.title,
                                          station: entry.station, recordedAt: entry.start)
        return SongDragProvider.make(fileBase: metadata.fileBase) {
            guard let info = recorder.exportSource(for: entry) else { throw SongExporter.ExportError.noSession }
            return try await SongExporter.exportTemporary(source: info.url, offset: info.offset,
                                                          duration: info.duration, name: metadata.fileBase,
                                                          metadata: metadata)
        }
    }

    private func openBatchExport() {
        let jobs = history.entries.filter { batchSelection.contains($0.id) }.map { entry in
            let audio = player.recorder.audioAvailability(for: entry).source
            return ExportJob(id: entry.id,
                             metadata: SongExportMetadata(raw: entry.raw, artist: entry.artist, title: entry.title,
                                                          station: entry.station, recordedAt: entry.start),
                             source: audio?.url, offset: audio?.offset ?? 0, duration: audio?.duration ?? 0)
        }
        guard !jobs.isEmpty, jobs.count <= ExportQueue.limit else { return }
        batchRequest = ExportBatchRequest(jobs: jobs, availableWidth: (NSApp.keyWindow?.frame.width ?? 840) - 80,
                                          availableHeight: (NSApp.keyWindow?.frame.height ?? 760) - 80)
    }
}

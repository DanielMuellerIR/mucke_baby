import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BookmarkButton: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.theme) private var theme
    let song: SongEntry
    var identifier = "bookmark-current"
    var tint: Color?
    @State private var errorMessage: String?

    var body: some View {
        let marked = bookmarks.contains(song)
        Button {
            do { try bookmarks.toggle(song) }
            catch { errorMessage = error.localizedDescription }
        } label: {
            Image(systemName: marked ? "heart.fill" : "heart")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? theme.palette.accent)
        .disabled(bookmarks.isReadOnly || song.isPlaceholder)
        .help(marked ? String(localized: "Aus Merkliste entfernen") : String(localized: "Titel merken"))
        .accessibilityLabel(marked ? String(localized: "Aus Merkliste entfernen") : String(localized: "Titel merken"))
        .accessibilityIdentifier(identifier)
        .alert("Merkliste", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

struct BookmarkLibrary: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiFontScale) private var scale
    let onClose: () -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @State private var lyricsFor: SongEntry?
    @State private var exportMessage = ""
    @State private var errorMessage: String?

    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var secondaryInk: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var visible: [SongBookmark] {
        let songs = HistoryFilter(query: query).apply(to: bookmarks.entries.map(\.song))
        let ids = Set(songs.map(\.id))
        return bookmarks.entries.enumerated().filter { ids.contains($0.element.id) }.sorted {
            if $0.element.savedAt != $1.element.savedAt { return $0.element.savedAt > $1.element.savedAt }
            return $0.offset > $1.offset
        }.map(\.element)
    }
    private var selectedSong: SongEntry? { visible.first { $0.id == selection }?.song }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Merkliste", systemImage: "heart.fill")
                    .font(theme.font(.title, size: 17 * scale, weight: .semibold))
                Spacer()
                Button("Schließen", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("bookmarks-close")
            }
            Text("Gemerkte Titel enthalten Metadaten, keine Audiodateien.")
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(secondaryInk)
            if let notice = bookmarks.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(theme.font(.body, size: 12 * scale))
                    .accessibilityIdentifier("bookmarks-notice")
            }
            TextField("Titel oder Interpret suchen", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bookmarks-search")
            HStack {
                Group {
                    if bookmarks.isReadOnly { Text("Titel nicht geladen.") }
                    else { Text("\(visible.count) von \(bookmarks.entries.count) Titeln") }
                }
                .accessibilityIdentifier("bookmarks-result-count")
                Spacer()
                Button("Text …") { export(.text) }.accessibilityIdentifier("bookmarks-export-text")
                Button("CSV …") { export(.csv) }.accessibilityIdentifier("bookmarks-export-csv")
            }
            .font(theme.font(.label, size: 11 * scale))
            .disabled(visible.isEmpty)
            .help("Sichtbare Merkliste exportieren")
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { bookmark in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Button { selection = bookmark.id } label: {
                                    SongRow(entry: bookmark.song, showsInterval: false)
                                        .padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection == bookmark.id ? [.isSelected] : [])
                                .accessibilityIdentifier("bookmark-song-\(bookmark.id)")
                                BookmarkButton(song: bookmark.song, identifier: "bookmark-remove-\(bookmark.id)",
                                               tint: theme.id == .retro ? secondaryInk : nil)
                            }
                            if let recognition = bookmark.recognition {
                                HStack(spacing: 8) {
                                    Text("Quelle: Shazam").accessibilityIdentifier("bookmark-source-\(bookmark.id)")
                                    Text(recognition.recognizedAt, format: .dateTime.year().month().day().hour().minute())
                                }
                                Text("Sendertext: \(recognition.originalICY.isEmpty ? String(localized: "Kein Sendertext") : recognition.originalICY)")
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("bookmark-original-\(bookmark.id)")
                            }
                        }
                        .font(theme.font(.label, size: 11 * scale)).foregroundStyle(secondaryInk)
                        .padding(.bottom, bookmark.recognition == nil ? 0 : 8)
                        .background(selection == bookmark.id ? theme.palette.selection : .clear)
                        Rectangle().fill(theme.palette.divider.opacity(0.5)).frame(height: 1)
                    }
                }
            }
            .overlay {
                if visible.isEmpty {
                    Text(bookmarks.isReadOnly ? String(localized: "Merkliste derzeit nicht verfügbar.")
                         : (bookmarks.entries.isEmpty ? String(localized: "Noch keine Titel gemerkt.")
                            : String(localized: "Keine Titel für diese Suche.")))
                        .foregroundStyle(secondaryInk)
                }
            }
            Divider()
            HStack {
                Button("\u{F8FF} Music") { if let selectedSong { SongActions.openInMusic(selectedSong) } }
                    .help("In Apple Music suchen")
                Button("Spotify") { if let selectedSong { SongActions.openInSpotify(selectedSong) } }
                    .help("In Spotify / im Web suchen")
                Button("Lyrics") { lyricsFor = selectedSong }.help("Songtext anzeigen")
                Spacer()
                Text(exportMessage).foregroundStyle(secondaryInk)
            }
            .font(theme.font(.label, size: 11 * scale))
            .disabled(selectedSong == nil)
        }
        .font(theme.font(.body, size: 13 * scale))
        .foregroundStyle(ink)
        .padding(18)
        .frame(width: 560, height: 560)
        .background { SongListSurface() }
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
        .sheet(item: $lyricsFor) { song in LyricsView(artist: song.artist ?? "", title: song.title ?? song.raw) }
        .alert("Merkliste", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func export(_ format: BookmarkStore.ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.plainText]
        panel.nameFieldStringValue = format == .csv ? "Mucke-Bookmarks.csv" : "Mucke-Bookmarks.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try bookmarks.export(visible, format: format, to: destination)
            exportMessage = String(localized: "Exportiert.")
        } catch { errorMessage = error.localizedDescription }
    }
}

// Gemeinsame Metadatenquelle für die Herz-Aktion des aktuellen Titels.
extension RadioPlayer {
    var currentSong: SongEntry? {
        guard let station = currentStation, !nowPlayingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let receivedAt = timeshiftTransport.timeline.anchor(at: timeshiftTransport.position)?.receivedAt
        let buffered = timeshiftRequested && (timeshiftTransport.timeline.canStart || timeshiftTransport.holdsPlayback)
        if buffered, let date = listeningReceivedAt {
            // Aufnahme an/aus kann denselben Titel in mehrere Dateien teilen.
            // Maßgeblich ist der Empfang des gehörten Frames, nicht nur der Titelanfang.
            if let entry = history.entries.last(where: {
                $0.station == station.name && $0.raw == nowPlayingTitle && $0.start <= date && ($0.end == nil || date <= $0.end!)
            }) { return entry }
        }
        if !buffered, let entry = history.entries.last, !entry.isPlaceholder,
           entry.station == station.name, entry.raw == nowPlayingTitle { return entry }
        let (artist, title) = SongEntry.split(nowPlayingTitle)
        return SongEntry(station: station.name, raw: nowPlayingTitle, artist: artist, title: title,
                         start: receivedAt ?? Date())
    }
}

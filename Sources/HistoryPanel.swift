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

    // Theme liefert Farben/Fonts/Texturen. `schlicht` (classic) loest exakt auf das
    // bisherige native Aussehen auf — alle Tokens sind dort semantisch
    // (textPrimary = .primary, panelBackground = windowBackgroundColor usw.).
    @Environment(\.theme) private var theme
    // UI-Schriftfaktor (1.0 = normal). Wird hier durchgereicht, damit die
    // Theme-Fonts genauso mitzoomen wie das frueher per `scaledFont` der Fall war.
    @Environment(\.uiFontScale) private var uiFontScale

    @State private var selection: SongEntry.ID?
    @State private var lyricsFor: SongEntry?
    @State private var exportMsg = ""
    @State private var showExportChoice = false

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

    private var selectedEntry: SongEntry? {
        history.entries.first { $0.id == selection }
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
        VStack(spacing: 0) {
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
                Menu {
                    Button("Älter als 1 Tag löschen") { clean(.day, 1) }
                    Button("Älter als 1 Woche löschen") { clean(.day, 7) }
                    Button("Älter als 1 Monat löschen") { clean(.month, 1) }
                    Divider()
                    Button("Gesamten Verlauf löschen", role: .destructive) { history.clear() }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(historyActionInk) }
                    .menuStyle(.borderlessButton).fixedSize().help("Verlauf-Optionen")
                Button { onClose() } label: { Image(systemName: "sidebar.trailing").foregroundStyle(historyActionInk) }
                    .buttonStyle(.plain).help("Verlauf ausblenden")
            }
            .padding(10)
            Divider()

            if history.entries.isEmpty {
                Spacer()
                Text("Noch nichts gehört.")
                    .themedFont(theme, .body, size: 13 * uiFontScale)
                    .foregroundColor(historyInkDim).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(history.entries) { entry in
                            SongRow(entry: entry).id(entry.id)
                                // Selektion manuell (kein `List(selection:)`): macOS faerbt das
                                // eingebaute Inset-Highlight mit der SYSTEM-Highlight-Farbe, die
                                // `.tint` nicht zuverlaessig ueberschreibt und oft nicht zum Theme
                                // passt. Stattdessen eigener, theme-getoenter Zeilenhintergrund.
                                .listRowBackground(
                                    selection == entry.id ? theme.palette.selection : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selection = entry.id }
                                // `.draggable` (statt `.onDrag`) vertraegt sich mit dem Tap;
                                // der Export laeuft erst beim Drop (off-main), blockiert den Klick nicht.
                                .draggable(DraggableSong(entry: entry, recorder: player.recorder))
                        }
                    }
                    .listStyle(.inset)
                    // List-Eigenhintergrund ausblenden → der Theme-Panel/das Pergament
                    // (ThemedSurface/ParchmentBackground) scheint durch. Behebt bei retro die
                    // unlesbare Tinte (dunkle Schrift lag auf dem dunklen List-Default-Material,
                    // Creme nur als „Rahmen") und macht alle Themes konsistent.
                    .scrollContentBackground(.hidden)
                    .onChange(of: history.entries) { _, _ in
                        if let last = history.entries.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = history.entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider()
            // Aktionen fuer den ausgewaehlten Titel — Icon UND Text (Daniel-Wunsch).
            // Vertikal (Icon oben, Label unten) bleibt schmal genug fuer die enge Spalte.
            // .bottom: alle Labels liegen unten buendig (Icon-Box gleicht Glyphenhoehen aus).
            HStack(alignment: .bottom, spacing: 4) {
                // Apple Music: das Apple-Logo-Zeichen (U+F8FF) statt des Wortes „Apple".
                Button { if let e = selectedEntry { openInMusic(e) } } label: {
                    historyActionLabel("music.note", "\u{F8FF} Music")
                }.buttonStyle(.plain).help("In Apple Music suchen").disabled(!selectedIsLookup)
                Button { if let e = selectedEntry { openInSpotify(e) } } label: {
                    historyActionLabel("music.note.list", "Spotify")
                }.buttonStyle(.plain).help("In Spotify / im Web suchen").disabled(!selectedIsLookup)
                Button { lyricsFor = selectedEntry } label: {
                    historyActionLabel("text.quote", "Lyrics")
                }.buttonStyle(.plain).help("Songtext anzeigen").disabled(!selectedIsLookup)
                // Plain-Button (statt Menu) — der borderlessButton-Menustil rendert sein Label
                // groesser/horizontal und ignoriert die kleine Schrift; so saehe „Export" anders
                // aus als die anderen drei. Die zwei Export-Varianten kommen in einen Dialog.
                Button { showExportChoice = true } label: {
                    historyActionLabel("square.and.arrow.up", "Export")
                }
                .buttonStyle(.plain)
                .help("Song aus Aufnahme exportieren (oder per Drag&Drop aus der Liste ziehen)")
                .confirmationDialog("Song exportieren", isPresented: $showExportChoice, titleVisibility: .visible) {
                    Button("Als Datei (harter Schnitt) …") { exportToFile(.hardCut) }
                    Button("Als Datei (ein-/ausgefadet) …") { exportToFile(.faded) }
                    Button("Abbrechen", role: .cancel) {}
                }
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
            if theme.id == .retro {
                ParchmentBackground(texture: theme.image(theme.panelTexture))
            } else {
                ThemedSurface(.panel)
            }
        }
        .sheet(item: $lyricsFor) { e in
            LyricsView(artist: e.artist ?? "", title: e.title ?? e.raw)
        }
    }

    // MARK: - Export (Aufnahme -> Song-Datei)

    // Quelldatei + Offset/Dauer fuer einen Verlauf-Eintrag bestimmen.
    private func sourceInfo(_ e: SongEntry) -> (url: URL, offset: Double, duration: Double)? {
        guard let clip = player.recorder.clip(covering: e.start) else { return nil }
        let url = player.recorder.dir.appendingPathComponent(clip.file)
        let offset = e.start.timeIntervalSince(clip.start)
        let duration = (e.end ?? Date()).timeIntervalSince(e.start)
        return (url, offset, duration)
    }

    private func exportName(_ e: SongEntry) -> String {
        let base = (e.artist.map { "\($0) - " } ?? "") + (e.title ?? e.raw)
        return base.replacingOccurrences(of: "/", with: "_")
    }

    private func exportToFile(_ mode: SongExporter.Mode) {
        guard let e = selectedEntry, let info = sourceInfo(e) else {
            exportMsg = "Keine Aufnahme zu diesem Titel."; return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = exportName(e) + ".m4a"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        exportMsg = String(localized: "Exportiere …")
        Task {
            do {
                try await SongExporter.export(source: info.url, offset: info.offset,
                                              duration: info.duration, mode: mode, to: dest)
                exportMsg = "Exportiert."
            } catch {
                exportMsg = (error as? SongExporter.ExportError)?.errorDescription ?? "Fehler beim Export."
            }
        }
    }

    // MARK: - Song-Aktionen

    // Apple Music: exakten Track via iTunes-API finden (mit Zusatz-Stripping),
    // in der Musik-App oeffnen; ohne App im Browser.
    private func openInMusic(_ e: SongEntry) {
        Task {
            let url = await SongLink.appleMusic(artist: e.artist, title: e.title, raw: e.raw)
            await MainActor.run { openURL(url, inApp: "com.apple.Music") }
        }
    }

    // Spotify: per App-URI suchen (bereinigter Begriff); ohne Spotify-App im Web.
    private func openInSpotify(_ e: SongEntry) {
        let term = SongLink.enc(SongLink.spotifyQuery(artist: e.artist, title: e.title, raw: e.raw))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client"),
           let uri = URL(string: "spotify:search:\(term)") {
            NSWorkspace.shared.open([uri], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://open.spotify.com/search/\(term)") {
            NSWorkspace.shared.open(web)
        }
    }

    // URL bevorzugt in der angegebenen App oeffnen, sonst im Standardbrowser.
    private func openURL(_ url: URL, inApp bundleID: String) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - ParchmentBackground

/// Heller Pergament-Hintergrund für das retro-History-Panel.
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

    // Theme + Schriftfaktor wie im Panel. SongRow liest beide selbst aus dem
    // Environment (kein Durchreichen noetig).
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private var isLive: Bool { entry.end == nil }

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
        let s = Self.timeFmt.string(from: entry.start)
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
        let base = (entry.artist.map { "\($0) - " } ?? "") + (entry.title ?? entry.raw)
        return base.replacingOccurrences(of: "/", with: "_") + ".m4a"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { song in
            guard let clip = song.recorder.clip(covering: song.entry.start) else {
                throw SongExporter.ExportError.noSession
            }
            let url = song.recorder.dir.appendingPathComponent(clip.file)
            let offset = song.entry.start.timeIntervalSince(clip.start)
            let duration = (song.entry.end ?? Date()).timeIntervalSince(song.entry.start)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(song.fileName)
            try await SongExporter.export(source: url, offset: offset,
                                          duration: duration, mode: .hardCut, to: tmp)
            return SentTransferredFile(tmp)
        }
        .suggestedFileName { $0.fileName }
    }
}

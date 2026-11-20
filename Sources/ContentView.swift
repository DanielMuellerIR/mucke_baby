import SwiftUI
import AppKit
import os

struct ContentView: View {
    @EnvironmentObject var startup: StartupSettings
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer
    @EnvironmentObject var health: StationHealth

    @AppStorage("volume") private var volume: Double = 0.77
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("uiZoom") private var uiZoom = 0   // selber Key wie im App-Scope
    // Theme-Key: selber UserDefaults-Key wie im App-Struct — synchron automatisch.
    // codereview-ok: Der Theme-Button in PlayerHeader schreibt selectedThemeRaw über diese Bindung (2026-07-01)
    @AppStorage("selectedTheme") private var selectedThemeRaw = "schlicht"

    @State private var editing = false
    @State private var showingAdd = false
    @State private var showingPrefs = false
    @State private var showingGroups = false
    @State private var showingQuickSelection = false
    @State private var showingSearch = false
    @State private var browserWidth: CGFloat = 780
    @State private var showingGenres = false
    @State private var showingBookmarks = false
    @State private var showingRecordings = false
    @State private var showingRecognition = false
    @State private var sheetHeight: CGFloat = 540
    @State private var editStation: Station?
    // Einmaliger Willkommens-Hinweis beim allerersten Start (Audio-Berechtigung +
    // optionalen Mitschnitt erklären). Flag persistiert, damit er nur einmal kommt.
    @AppStorage("didShowWelcome") private var didShowWelcome = false
    @State private var showingWelcome = false
    @Environment(\.theme) private var theme
    @EnvironmentObject private var visualizerWindow: PlayerWindowState
    @StateObject private var mainWindow = PlayerWindowState()

    var body: some View {
        VStack(spacing: 0) {
            // Die gemeinsame Kopfleiste ersetzt die native Toolbar mit ihren Glas-Kapseln.
            PlayerHeader(
                editing: $editing,
                showHistory: $showHistory,
                selectedThemeRaw: $selectedThemeRaw,
                onSearch: { showingSearch = true },
                onAdd: { showingAdd = true },
                onImportGenres: { showingGenres = true },
                onPreferences: { showingPrefs = true }
            )
            Rectangle().fill(theme.palette.divider).frame(height: 1)
            consoleBody
            TimeshiftControlsView(player: player)
            // Fuß: aktueller Titel groß und kopierbar, Merkliste, Laufzeit und Lautstärke.
            Rectangle().fill(theme.palette.divider).frame(height: 1)
            NowPlayingFooter(
                volume: $volume,
                onOpenRecognition: { showingRecognition = true },
                onOpenBookmarks: { showingBookmarks = true }
            )
        }
        .background { ThemedSurface(.window) }
        // Inhalt unter den (transparenten) Titelbalken ziehen, sonst setzt SwiftUI die obere
        // Safe-Area (Titelbalken-Höhe) als Inset → die Kopfleiste rutscht NACH UNTEN und die
        // Ampel-Buttons sitzen in einem leeren Streifen darüber. Mit ignoresSafeArea(.top)
        // beginnt die Kopfleiste ganz oben; die Ampel-Buttons liegen INLINE darüber (die
        // PlayerHeader reserviert links 68 pt Platz für sie).
        .ignoresSafeArea(.container, edges: .top)
        // Kein blauer Fokus-Rahmen auf den Buttons (sieht bewusst schlicht aus, gilt für alle
        // Buttons). Gilt fürs ganze Fensterinhalt; Sheets (Eingabefelder) sind eigene
        // Präsentationen und behalten ihren Fokus-Ring.
        .focusEffectDisabled()
        // Mindestbreite: so breit, dass die Kopfleiste (Titel + Controls) nicht clippt, aber
        // klein genug, dass der Mittelbereich (Stage, Schwelle 780) beim Schmalziehen ausblendet.
        .frame(minWidth: 620, minHeight: 420)
        // Gemeinsame Modifier
        .onAppear { player.setVolume(Float(volume)) }
        .onChange(of: volume) { _, value in player.setVolume(Float(value)) }
        .task {
            // Allererster Start: erst den Willkommens-Hinweis zeigen, Autoplay erst beim
            // Schliessen (onDismiss) — sonst legt sich der macOS-Audio-Prompt ueber den Text.
            if !didShowWelcome {
                showingWelcome = true
                didShowWelcome = true
            } else {
                autoplayIfNeeded()
            }
            health.checkAll(store.stations)
        }
        // Neupruefung nicht nur bei geaenderter Anzahl, sondern auch, wenn sich der
        // Inhalt eines bestehenden Senders aendert. Reines .count uebersah eine URL-
        // Korrektur an einem Sender (id + Anzahl unveraendert), sodass der alte
        // Health-Status bis zum App-Neustart haengenblieb. Wir leiten deshalb eine
        // kompakte Signatur aus allen Sender-URLs ab und beobachten diese. Die URLs
        // werden vor dem Zusammenfuegen sortiert, damit eine reine Umsortierung der
        // Sender (Store.move) KEINEN unnoetigen Netz-Recheck aller Sender ausloest —
        // nur echtes Hinzufuegen/Entfernen/Aendern einer URL veraendert die Signatur.
        // codereview-ok: toggleEnabled-Nichtpruefen ist by design (deaktivierte Sender ignoriert); Reaktivierungs-Edge von dieser URL-Signatur-Beobachtung abgedeckt (2026-07-01)
        .onChange(of: store.stations.map(\.url).sorted().joined(separator: "\n")) { _, _ in
            health.checkAll(store.stations)
        }
        // Zuletzt gespielten Sender merken (für „beim Start fortsetzen").
        .onChange(of: player.currentStation?.id) { _, id in
            if let id { startup.rememberStation(id) }
        }
        .sheet(isPresented: $showingAdd) { StationEditView(station: nil) }
        .sheet(item: $editStation) { st in StationEditView(station: st) }
        .sheet(isPresented: $showingPrefs) { PreferencesView() }
        .sheet(isPresented: $showingGroups) { StationGroupsView() }
        .sheet(isPresented: $showingQuickSelection) { StationQuickSelectionView() }
        .focusedSceneValue(\.openStationQuickSelection, quickSelectionAction)
        .focusedSceneValue(\.openRecordingLibrary, { showingRecordings = true })
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear {
                    browserWidth = geometry.size.width - 32
                    sheetHeight = geometry.size.height - 32
                }
                    .onChange(of: geometry.size.width) { _, width in browserWidth = width - 32 }
                    .onChange(of: geometry.size.height) { _, height in sheetHeight = height - 32 }
            }
        }
        .sheet(isPresented: $showingSearch) { StationBrowserView(availableWidth: browserWidth) }
        .sheet(isPresented: $showingGenres) { GenreListsView() }
        .sheet(isPresented: $showingBookmarks) { BookmarkLibrary(onClose: { showingBookmarks = false }) }
        .sheet(isPresented: $showingRecordings) { RecordingLibraryView(availableWidth: browserWidth) }
        .sheet(isPresented: $showingRecognition) {
            MusicRecognitionView(availableWidth: browserWidth, availableHeight: sheetHeight)
        }
        .sheet(isPresented: $showingWelcome, onDismiss: { autoplayIfNeeded() }) { WelcomeView() }
        // Cmd+"=" als zweite Zoom-in-Taste (Layout-unabhaengig), unsichtbar verdrahtet.
        .background {
            Button("") {
                uiZoom = min(uiZoom + 1, 5)
                uiLog.notice("zoom= -> \(uiZoom, privacy: .public)")
            }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // Fenster so konfigurieren, dass die Kopfleiste den Titelbalken-Bereich einnimmt
        // (Ampel-Buttons inline). Unsichtbar.
        .background(WindowConfigurator().frame(width: 0, height: 0))
        .background(PlayerWindowObserver(state: mainWindow).frame(width: 0, height: 0))
        .environment(\.visualizerRenderingEnabled, mainWindow.isVisible && !visualizerWindow.isVisible)
    }

    private func autoplayIfNeeded() {
        guard startup.claimAutoplay() else { return }
        if let target = startup.configuration.target(in: store.stations) {
            player.play(target)
        }
    }

    // MARK: 3-Spalten-Layout (alle Themes: Stations | Stage+Visualizer | Verlauf)

    /// 3-Spalten-Ansicht: Stations | Stage | History
    private var consoleBody: some View {
        // Responsiv: Stations | (Stage) | (Verlauf). Die Stage (Visualizer) wird unter einer
        // Breiten-Schwelle KOMPLETT ausgeblendet — nicht nur versteckt, sondern nicht gerendert
        // → die TimelineView-Animation läuft dann gar nicht (kein Performance-Overhead).
        GeometryReader { geo in
            let width = geo.size.width
            // Schwelle: unter 780 Punkten ist zu wenig Platz für einen sinnvollen Visualizer.
            let showStage = width >= 780
            let stageWidth: CGFloat = showStage ? min(520, max(300, width * 0.30)) : 0
            let dividers = CGFloat((showStage ? 1 : 0) + (showHistory ? 1 : 0))
            let rest = width - stageWidth - dividers
            // Verbleibende Breite teilen sich Stations + (optional) Verlauf.
            let stationsWidth = showHistory ? max(220, rest * 0.5) : max(240, rest)
            let historyWidth = max(220, rest * 0.5)
            HStack(spacing: 0) {
                StationColumn(
                    width: stationsWidth,
                    editing: editing,
                    onQuickSelection: { showingQuickSelection = true },
                    onGroups: { showingGroups = true },
                    onEdit: { editStation = $0 }
                )
                if showStage {
                    Rectangle().fill(theme.palette.divider).frame(width: 1)
                    // Stage exakt auf stageWidth zwingen (direkt .frame(width:), kein Overlay).
                    StageView()
                        .frame(width: stageWidth)
                        .clipped()
                }
                if showHistory {
                    Rectangle().fill(theme.palette.divider).frame(width: 1)
                    HistoryPanel(
                        onClose: { withAnimation { showHistory = false } },
                        onOpenRecordings: { showingRecordings = true }
                    )
                    .frame(width: historyWidth)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    private var quickSelectionAction: (() -> Void)? {
        guard !showingAdd, editStation == nil, !showingPrefs, !showingGroups,
              !showingQuickSelection, !showingSearch, !showingGenres, !showingBookmarks, !showingWelcome else { return nil }
        return { showingQuickSelection = true }
    }
}

/// Zieht den Inhalt unter den Titelbalken (fullSizeContentView), macht ihn transparent und
/// blendet den Titel aus. Dadurch sitzt unsere eigene Kopfleiste ganz oben und die Ampel-
/// Buttons (rot/gelb/grün) liegen INLINE links in der Kopfleiste — kein separater, leerer
/// Titelbalken mehr. Ergänzt `.windowStyle(.hiddenTitleBar)` (erzwingt es zuverlässig).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.identifier = NSUserInterfaceItemIdentifier("MuckeBabyMain")
            // Ein Hintergrund-Kurzbefehl darf kein beim letzten Quit gesichertes
            // Hauptfenster wiederherstellen. Der normale Appstart öffnet es selbst.
            w.isRestorable = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

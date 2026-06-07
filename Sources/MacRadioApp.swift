import SwiftUI
import AppKit
import os

private let uiLog = Logger(subsystem: "de.danielmuller.macradio", category: "ui")

@main
struct MacRadioApp: App {
    @StateObject private var store = Store()
    @StateObject private var player = RadioPlayer()
    @StateObject private var health = StationHealth()
    // Audio-Reaktivität der Visualizer (CoreAudio Process-Tap auf die eigene Ausgabe).
    @StateObject private var audioTap = AudioTap()
    // Nur fuer headless Theme-Screenshots aktiv (Env MUCKE_SHOTS); sonst No-Op.
    @NSApplicationDelegateAdaptor(MuckeAppDelegate.self) private var appDelegate
    // Menueleisten-Icon: per Schalter zu/abschaltbar. Default aus.
    @AppStorage("menuBarMode") private var menuBarMode = false
    // Globale Schriftskalierung (CMD +/-/0). macOS-SwiftUI ignoriert dynamicTypeSize,
    // daher eigener Skalierungsfaktor (uiFontScale-Environment) + explizite Fontgroessen.
    @AppStorage("uiZoom") private var uiZoom = 0
    // Aktives Theme (persistiert als ThemeID.rawValue).
    @AppStorage("selectedTheme") private var selectedThemeRaw = "schlicht"
    // Beobachtet die System-Hell/Dunkel-Einstellung. Nötig, weil `schlicht` dem System
    // folgen soll: `preferredColorScheme(nil)` revertet nach einem erzwungenen .dark/.light
    // NICHT zuverlaessig (SwiftUI laesst das Fenster im alten Scheme haengen — Bug 6a:
    // „Standard dark-Inhalt + helle Toolbar" nach Wechsel von Black MIDI). Loesung: IMMER
    // einen expliziten Scheme uebergeben (nie nil), fuer `schlicht` den echten System-Scheme.
    @StateObject private var sysAppearance = SystemAppearance()

    /// Aktuelles Theme-Objekt aus dem gespeicherten Rohwert.
    private var theme: Theme { Theme.theme(raw: selectedThemeRaw) }

    /// Effektiver Scheme: Theme erzwingt einen → den nehmen; `schlicht` (nil) → System-Scheme.
    /// Niemals nil, damit der Wechsel sauber durchschlaegt.
    private var effectiveScheme: ColorScheme { theme.colorScheme ?? sysAppearance.scheme }

    var body: some Scene {
        // Normales App-Fenster (Standardmodus).
        WindowGroup("Mucke, Baby!") {
            ContentView()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(player.history)   // Wiedergabeverlauf
                .environmentObject(health)           // Sender-Healthcheck
                .environmentObject(audioTap)         // Audio-Reaktivität
                .environment(\.uiFontScale, Self.scale(uiZoom))
                // Theme und ColorScheme ins Environment injizieren
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        }
        // Eigener Kopfbereich statt nativer Toolbar/Titel: hiddenTitleBar entfernt die
        // macOS-Titelleiste (und damit die erzwungenen Glas-Kapseln um Toolbar-Inhalte,
        // U1). Die Ampel-Buttons schweben weiter oben links; unsere Kopfleiste laesst
        // links Platz fuer sie. Titel + Transport + Lautstaerke + Aktionen zeichnen wir
        // selbst (themed, identische Region in ALLEN Themes).
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)         // frei groesser ziehbar
        .defaultSize(width: 940, height: 620)        // Startgroesse: Platz fuer 3-Spalten-Themes
        .commands {
            // Eigenes, sichtbares "Darstellung"-Menue (anklickbar). CMD +/-/0 skaliert
            // die UI ueber dynamicTypeSize. Cmd+"=" zusaetzlich als Zoom-in (auf manchen
            // Tastaturlayouts liefert ⌘+ erst mit Shift) — verdrahtet in ContentView.
            CommandMenu("Darstellung") {
                Button("Schrift größer") { uiZoom = min(uiZoom + 1, 5); uiLog.notice("zoom+ -> \(uiZoom, privacy: .public)") }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Schrift kleiner") { uiZoom = max(uiZoom - 1, -3); uiLog.notice("zoom- -> \(uiZoom, privacy: .public)") }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Originalgröße") { uiZoom = 0; uiLog.notice("zoom0") }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // Thema-Menue: IMMER erreichbar (unabhaengig vom Layout). Haken beim aktiven
            // Theme; ⌘⇧T schaltet zum naechsten. Zusaetzlich zum Pill/Toolbar-Button.
            CommandMenu("Thema") {
                ForEach(ThemeID.allCases) { tid in
                    Button {
                        selectedThemeRaw = tid.rawValue
                    } label: {
                        if selectedThemeRaw == tid.rawValue {
                            Label(Theme.theme(tid).name, systemImage: "checkmark")
                        } else {
                            Text(Theme.theme(tid).name)
                        }
                    }
                }
                Divider()
                Button("Nächstes Thema") { selectedThemeRaw = theme.nextID.rawValue }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        // Optionaler Menueleisten-Modus. `isInserted` blendet das Icon
        // zur Laufzeit ein/aus, ohne die Szene neu aufzubauen.
        MenuBarExtra("Mucke, Baby!", systemImage: "dot.radiowaves.left.and.right",
                     isInserted: $menuBarMode) {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(player)
                .environment(\.uiFontScale, Self.scale(uiZoom))
                // Auch im Menueleisten-Popup Theme + ColorScheme setzen
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        }
        .menuBarExtraStyle(.window)
    }

    // Zoom-Stufe (-3 … +5) auf einen Skalierungsfaktor abbilden (~13 % je Stufe).
    static func scale(_ zoom: Int) -> CGFloat {
        max(0.7, min(1.8, 1 + CGFloat(zoom) * 0.13))
    }
}

// MARK: - System-Hell/Dunkel beobachten

/// Liefert den aktuellen System-ColorScheme (Hell/Dunkel) und aktualisiert sich live,
/// wenn der Nutzer die Systemeinstellung umstellt. Wird gebraucht, damit das `schlicht`-
/// Theme dem System folgen kann, OHNE `preferredColorScheme(nil)` zu verwenden — denn nil
/// revertet nach einem zuvor erzwungenen .dark/.light nicht zuverlaessig (Bug 6a).
final class SystemAppearance: ObservableObject {
    @Published var scheme: ColorScheme = SystemAppearance.current()
    private var observer: NSObjectProtocol?

    init() {
        // macOS feuert diese (undokumentierte, aber stabile) Distributed-Notification beim
        // Hell/Dunkel-Wechsel. Danach den Default neu lesen.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheme = SystemAppearance.current()
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Aktueller System-Scheme: `AppleInterfaceStyle == "Dark"` → dunkel, sonst hell.
    static func current() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}

// MARK: - Schriftskalierung (macOS-tauglich)

// Globaler UI-Schriftfaktor im Environment (1.0 = normal). Wird in ContentView /
// MenuBarView gesetzt; alle skalierten Texte multiplizieren ihre Basisgroesse damit.
private struct UIFontScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var uiFontScale: CGFloat {
        get { self[UIFontScaleKey.self] }
        set { self[UIFontScaleKey.self] = newValue }
    }
}

extension View {
    // Ersatz fuer `.font(.<style>)`, der den uiFontScale beruecksichtigt. macOS
    // ignoriert dynamicTypeSize -> wir setzen explizite `.system(size:)`-Groessen.
    func scaledFont(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFontModifier(style: style, weight: weight))
    }
}

struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiFontScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: UIFont.baseSize(style) * scale,
                             weight: weight ?? UIFont.defaultWeight(style)))
    }
}

// Basis-Punktgroessen der macOS-Textstile (Naeherung), Single Source.
enum UIFont {
    static func baseSize(_ s: Font.TextStyle) -> CGFloat {
        switch s {
        case .largeTitle: return 26
        case .title:      return 22
        case .title2:     return 17
        case .title3:     return 15
        case .headline:   return 13
        case .body:       return 13
        case .callout:    return 12
        case .subheadline:return 11
        case .footnote:   return 10
        case .caption:    return 11
        case .caption2:   return 10
        @unknown default: return 13
        }
    }
    static func defaultWeight(_ s: Font.TextStyle) -> Font.Weight {
        s == .headline ? .semibold : .regular
    }
}

// MARK: - Fenster-Konfiguration

/// Zieht den Inhalt unter den Titelbalken (fullSizeContentView), macht ihn transparent und
/// blendet den Titel aus. Dadurch sitzt unsere eigene Kopfleiste ganz oben und die Ampel-
/// Buttons (rot/gelb/grün) liegen INLINE links in der Kopfleiste — kein separater, leerer
/// Titelbalken mehr. Ergänzt `.windowStyle(.hiddenTitleBar)` (erzwingt es zuverlässig).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Macht einen Bereich NICHT fenster-verschiebbar. Da unsere Kopfleiste über der (transparenten,
/// fullSizeContentView-)Titelregion liegt, würde ein Mausklick dort sonst das Fenster ziehen statt
/// das Steuerelement zu bedienen — genau das passierte beim Lautstärkeknopf. Eine NSView mit
/// `mouseDownCanMoveWindow=false` unter dem Knopf unterbindet den Fenster-Drag, der Klick landet
/// auf der Geste.
private struct NonDraggableArea: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Feine waagrechte Bürstlinien für die gebürstete Goldplatte (GuitarAmp-Kopf).
/// Deterministisch (LCG-Hash, kein random) und CPU-schonend.
private struct BrushedGoldSheen: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt32 = 0xC0FF_EE11
            func next() -> Double {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Double(seed) / Double(UInt32.max)
            }
            var y = 0.0
            while y < size.height {
                let a = 0.03 + next() * 0.05
                // Abwechselnd helle (Sheen) und dunkle (Riefe) Linien → Brushed-Optik.
                let col: Color = next() > 0.5 ? .white.opacity(a) : .black.opacity(a * 0.7)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(col), lineWidth: 0.6)
                y += 1.5
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Hauptansicht

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: RadioPlayer
    @EnvironmentObject var health: StationHealth

    @AppStorage("volume") private var volume: Double = 0.77
    @AppStorage("autoplayOnLaunch") private var autoplay = true
    // Zuletzt gespielter Sender (UUID-String) — beim Start wird DIESER wieder gestartet,
    // nicht mehr blind der oberste/Favorit. Wird bei jedem Senderwechsel aktualisiert.
    @AppStorage("lastStationID") private var lastStationID = ""
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("uiZoom") private var uiZoom = 0   // selber Key wie im App-Scope
    // Theme-Key: selber UserDefaults-Key wie im App-Struct — synchron automatisch.
    @AppStorage("selectedTheme") private var selectedThemeRaw = "schlicht"

    @State private var editing = false
    @State private var showingAdd = false
    @State private var showingPrefs = false
    @State private var showingSearch = false
    @State private var showingGenres = false
    @State private var editStation: Station?
    @State private var didAutoplay = false
    // Lautstärke bei Beginn einer Knopf-Drehung (knob-Themes) — für relatives Ziehen.
    @State private var knobDragStart: Double? = nil

    // Aktives Theme aus dem Environment (von MacRadioApp injiziert).
    @Environment(\.theme) private var theme
    // Schriftfaktor (CMD +/−/0) — die Kopfleiste skaliert mit.
    @Environment(\.uiFontScale) private var uiFontScale
    // Audio-Reaktivität (Process-Tap) — wird beim Start angeworfen, von den Visualizern gelesen.
    @EnvironmentObject private var audioTap: AudioTap

    // Kopf-Vordergrund: Bei GuitarAmp liegt die Kopfleiste auf einer HELLEN Goldplatte → die
    // normalen Theme-Töne (cremefarbener Titel, goldene Icons) verschwinden darauf. Deshalb
    // dort dunkle „Tinte" für Kontrast; in allen anderen Themes die Palette-Töne.
    private var onGoldHeader: Bool { theme.id == .stack }
    private var headerInk: Color { onGoldHeader ? Color(hex: "#2A1E05") : theme.palette.textSecondary }
    private var headerInkStrong: Color { onGoldHeader ? Color(hex: "#1A1203") : theme.palette.textPrimary }

    var body: some View {
        VStack(spacing: 0) {
            // Einheitliche Kopfleiste (ALLE Themes, gleiche Fenster-Region): App-Titel groß,
            // Transport (Play/Stop), Lautstaerke, Aktions-Icons. Ersetzt die native Toolbar
            // → keine erzwungenen macOS-Glas-Kapseln (U1). Layout darunter pro Theme.
            headerBar
            Rectangle().fill(theme.palette.divider).frame(height: 1)
            // 3-Spalten-Layout (Stations | Stage+Visualizer | Verlauf). Standard = minimalste
            // Skin. Spalten werden responsiv ein-/ausgeblendet (s. consoleBody).
            consoleBody
            // Fuß: aktueller Titel groß + kopierbar (Daniel-Wunsch). Transport/Lautstärke
            // sitzen oben in der Kopfleiste — hier NUR die Now-Playing-Anzeige.
            Rectangle().fill(theme.palette.divider).frame(height: 1)
            nowPlayingFooter
        }
        .background { ThemedSurface(.window) }
        // Inhalt unter den (transparenten) Titelbalken ziehen, sonst setzt SwiftUI die obere
        // Safe-Area (Titelbalken-Höhe) als Inset → die Kopfleiste rutscht NACH UNTEN und die
        // Ampel-Buttons sitzen in einem leeren Streifen darüber. Mit ignoresSafeArea(.top)
        // beginnt die Kopfleiste ganz oben; die Ampel-Buttons liegen INLINE darüber (die
        // headerBar reserviert links 68 pt Platz für sie). (TODO #2)
        .ignoresSafeArea(.container, edges: .top)
        // Kein blauer Fokus-Rahmen auf den Buttons (Daniel: „sieht doof aus, gilt für alle
        // Buttons"). Gilt fürs ganze Fensterinhalt; Sheets (Eingabefelder) sind eigene
        // Präsentationen und behalten ihren Fokus-Ring.
        .focusEffectDisabled()
        // Mindestbreite: so breit, dass die Kopfleiste (Titel + Controls) nicht clippt, aber
        // klein genug, dass der Mittelbereich (Stage, Schwelle 780) beim Schmalziehen ausblendet.
        .frame(minWidth: 620, minHeight: 420)
        // Gemeinsame Modifier
        .onAppear { player.setVolume(Float(volume)) }
        .onChange(of: volume) { _, v in player.setVolume(Float(v)) }
        .task { autoplayIfNeeded(); health.checkAll(store.stations) }
        .onChange(of: store.stations.count) { _, _ in health.checkAll(store.stations) }
        // Zuletzt gespielten Sender merken (für „beim Start fortsetzen").
        .onChange(of: player.currentStation?.id) { _, id in
            if let id { lastStationID = id.uuidString }
        }
        // Audio-Analyse-Player (Visualizer-Reaktivität) an die laufende Stream-URL koppeln.
        .onChange(of: player.currentStreamURL) { _, url in audioTap.setStream(url) }
        .sheet(isPresented: $showingAdd) { StationEditView(station: nil) }
        .sheet(item: $editStation) { st in StationEditView(station: st) }
        .sheet(isPresented: $showingPrefs) { PreferencesView() }
        .sheet(isPresented: $showingSearch) { SearchView() }
        .sheet(isPresented: $showingGenres) { GenreListsView() }
        // Cmd+"=" als zweite Zoom-in-Taste (Layout-unabhaengig), unsichtbar verdrahtet.
        .background {
            Button("") { uiZoom = min(uiZoom + 1, 5); uiLog.notice("zoom= -> \(uiZoom, privacy: .public)") }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // Fenster so konfigurieren, dass die Kopfleiste den Titelbalken-Bereich einnimmt
        // (Ampel-Buttons inline). Unsichtbar.
        .background(WindowConfigurator().frame(width: 0, height: 0))
        // Beim Beenden kurze Verlauf-Fragmente (< 20 s) wegputzen.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            player.history.pruneOnLaunchOrQuit()
        }
    }

    // Beim ersten Erscheinen: Favorit (sonst ersten sichtbaren Sender) starten.
    private func autoplayIfNeeded() {
        guard autoplay, !didAutoplay else { return }
        didAutoplay = true
        // Zuletzt gespielten Sender bevorzugen (Daniel-Wunsch); sonst Favorit, sonst erster.
        let last = store.enabledStations.first { $0.id.uuidString == lastStationID }
        if let target = last ?? store.favorite ?? store.enabledStations.first {
            player.play(target)
        }
    }

    // MARK: Gemeinsame Kopfleiste (alle Themes)

    /// Kopfleiste: links Platz fuer die Ampel-Buttons + großer App-Titel, rechts Transport,
    /// Laufzeit, Lautstaerke und Aktions-Icons. Theme-getoent, ohne native Glas-Kapsel.
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Platz fuer die schwebenden Ampel-Buttons (hiddenTitleBar laesst sie oben links)
            Color.clear.frame(width: 68, height: 1)

            // App-Titel groß + Version (Titel darf NICHT klein sein — Daniel-Wunsch)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Mucke, Baby!")
                    .font(theme.font(.title, size: 18 * uiFontScale, weight: .bold))
                    .tracking(theme.fonts.tracking)
                    .foregroundStyle(headerInkStrong)
                    .fixedSize()
                // Version: lesbar, aber dezent — textSecondary statt textDim (war kaum lesbar).
                Text("v\(AppInfo.version)")
                    .font(theme.font(.label, size: 11 * uiFontScale, weight: .medium))
                    .foregroundStyle(headerInk)
                    .fixedSize()
            }

            Spacer(minLength: 12)

            // Transport: Play/Stop (Daniel-Wunsch: Stopp oben). MIT Text-Label — ein nacktes
            // Quadrat ist ohne Kontext nicht eindeutig.
            Button { if let s = player.currentStation { player.toggle(s) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(player.isPlaying ? "Stopp" : "Wiedergabe")
                        .font(theme.font(.label, size: 11 * uiFontScale, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(onGoldHeader ? headerInkStrong : theme.palette.playActive)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentStation == nil)
            .help(player.isPlaying ? "Stopp" : "Wiedergabe")

            // Laufzeit sitzt jetzt im Fuß (war hier doppelt) → spart Platz in der Kopfleiste.

            // Lautstaerke (Daniel-Wunsch: oben)
            headerVolume

            Rectangle().fill(theme.palette.divider).frame(width: 1, height: 20)
            headerActions
        }
        .padding(.horizontal, 14)
        // Schlanke Kopfleiste (Ampel-Buttons liegen oben links inline). knob-Themes brauchen
        // mehr Höhe für den 3D-Drehknopf samt Label (Amp-Bedienpanel-Optik).
        .frame(height: theme.control == .knob ? 52 : 38)
        .background { headerBackground }
    }

    /// Kopfleisten-Hintergrund. Stack: gebürstete Goldplatte über dunklem Grund (Daniel-Wunsch
    /// „echte Leiste aus gebürstetem Gold" = die obere Bedienleiste). Sonst Theme-Panel.
    @ViewBuilder
    private var headerBackground: some View {
        if theme.id == .stack {
            // Helle, gebürstete Messingplatte (Amp-Bedienpanel, Vorbild marshall_amp_design).
            // Warmer Gold-Verlauf als Basis (hell oben → dunkler unten = leichte Wölbung),
            // optionale Goldtextur als Korn (blendMode .overlay), feine waagrechte Bürstlinien,
            // oben Glanzkante / unten Schattenkante (3D-Bevel der Platte).
            LinearGradient(
                colors: [Color(hex: "#E6C86C"), Color(hex: "#C8A246"), Color(hex: "#9C7A2E")],
                startPoint: .top, endPoint: .bottom
            )
            .overlay {
                if let gold = theme.image(theme.accentTexture) {
                    gold.resizable().scaledToFill().opacity(0.28).blendMode(.overlay)
                }
            }
            .overlay { BrushedGoldSheen() }
            .overlay(alignment: .top) {       // Glanzkante oben
                LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 3)
            }
            .overlay(alignment: .bottom) {     // Schattenkante unten (Bevel-Abschluss)
                LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 4)
            }
            .clipped()
        } else {
            ThemedSurface(.panel)
        }
    }

    /// Lautstaerke in der Kopfleiste. knob-Themes (retro/stack): drehbarer Goldknopf
    /// (ziehen = drehen, fotorealistische Textur). Sonst Slider mit Speaker-Icons.
    @ViewBuilder
    private var headerVolume: some View {
        if theme.control == .knob {
            // Der sichtbare Knopf ist klein (38 pt). Damit er bedienbar ist, wird das KLICK-/
            // ZIEH-Target per Padding deutlich vergrößert (horizontal viel Platz, vertikal durch
            // die Kopfhöhe begrenzt) — contentShape macht das gesamte gepolsterte Rechteck
            // greifbar. (Daniel: Target war fast unbedienbar.)
            // Sichtbarer Knopf klein (38pt), aber GROSSES Klick-/Ziehtarget: füllt die ganze
            // Kopfhöhe und viel Breite. `NonDraggableArea` im Hintergrund verhindert, dass der
            // Klick stattdessen das Fenster verschiebt (Knopf liegt in der Titelregion).
            KnobView(value: volume, label: "VOL", tint: theme.palette.accent, diameter: 38)
                .frame(maxHeight: .infinity)          // volle Kopfhöhe greifbar
                .padding(.horizontal, 30)
                .contentShape(Rectangle())
                .background(NonDraggableArea())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let start = knobDragStart ?? volume
                            if knobDragStart == nil { knobDragStart = volume }
                            // hoch ODER rechts ziehen = lauter (Drehgefühl)
                            let delta = Double((-g.translation.height + g.translation.width) / 120)
                            volume = min(1, max(0, start + delta))
                        }
                        .onEnded { _ in knobDragStart = nil }
                )
                .help("Lautstärke: \(Int(volume * 100)) % — ziehen zum Drehen")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10)).foregroundStyle(theme.palette.textDim)
                Slider(value: $volume, in: 0...1)
                    .frame(width: 96)
                    .tint(theme.palette.accent)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10)).foregroundStyle(theme.palette.textDim)
            }
            .help("Lautstärke: \(Int(volume * 100)) %")
        }
    }

    /// Aktions-Icons rechts: Suche, Hinzufuegen, Bearbeiten, Einstellungen, Verlauf, Theme.
    private var headerActions: some View {
        HStack(spacing: 14) {
            headerIcon("magnifyingglass", "Sender suchen (radio-browser)") { showingSearch = true }
            Menu {
                Button("Sender hinzufügen …") { showingAdd = true }
                Button("Genre-Liste importieren …") { showingGenres = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 13))
                    .foregroundStyle(headerInk)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Hinzufügen")
            headerIcon(editing ? "checkmark" : "pencil", editing ? "Fertig" : "Bearbeiten") { editing.toggle() }
            headerIcon("gearshape", "Einstellungen") { showingPrefs = true }
            headerIcon(showHistory ? "sidebar.trailing" : "clock.arrow.circlepath",
                       "Verlauf ein-/ausblenden") { withAnimation { showHistory.toggle() } }
            headerIcon("paintpalette", "Theme: \(theme.name) → \(Theme.theme(theme.nextID).name)") {
                selectedThemeRaw = theme.nextID.rawValue
            }
        }
    }

    /// Einheitlicher Kopf-Icon-Button (theme-getoent, plain — keine Glas-Kapsel).
    private func headerIcon(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(headerInk)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Now-Playing-Fuß

    /// Fuß: laufender Sender + Titel — groß und **markierbar/kopierbar** (textSelection),
    /// bei Überlänge horizontal scrollbar — plus Laufzeit. Bedienelemente sitzen oben in der
    /// Kopfleiste; hier ausschließlich die Now-Playing-Anzeige.
    private var nowPlayingFooter: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentStation?.name ?? "Kein Sender")
                        .font(theme.font(.label, size: 11 * uiFontScale))
                        .foregroundStyle(theme.palette.textSecondary)
                    nowPlayingFooterTitle
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let started = player.playStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(PlaybackClock.runtime(since: started, now: ctx.date))
                        .font(theme.font(.label, size: 12 * uiFontScale))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.textDim)
                }
                .fixedSize()
                .help("Laufzeit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background { ThemedSurface(.panel) }
    }

    /// Großer Now-Playing-Titel im Fuß (Interpret fett + Titel), als EIN Text → kopierbar.
    @ViewBuilder
    private var nowPlayingFooterTitle: some View {
        if !player.nowPlayingTitle.isEmpty {
            let (artist, title) = SongEntry.split(player.nowPlayingTitle)
            if let a = artist, let t = title {
                (Text(a).font(theme.font(.body, size: 16 * uiFontScale, weight: .bold))
                 + Text("   ").font(theme.font(.body, size: 15 * uiFontScale))
                 + Text(t).font(theme.font(.body, size: 15 * uiFontScale)))
                    .foregroundStyle(theme.palette.textPrimary)
            } else {
                Text(title ?? player.nowPlayingTitle)
                    .font(theme.font(.body, size: 16 * uiFontScale, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        } else {
            Text(player.isLoading ? player.statusText
                 : (player.isPlaying ? "♪" : player.statusText))
                .font(theme.font(.body, size: 15 * uiFontScale))
                .foregroundStyle(theme.palette.textPrimary)
        }
    }

    // MARK: 3-Spalten-Layout (alle Themes: Stations | Stage+Visualizer | Verlauf)

    /// 3-Spalten-Ansicht: Stations | Stage | History
    private var consoleBody: some View {
        // Responsiv: Stations | (Stage) | (Verlauf). Die Stage (Visualizer) wird unter einer
        // Breiten-Schwelle KOMPLETT ausgeblendet — nicht nur versteckt, sondern nicht gerendert
        // → die TimelineView-Animation läuft dann gar nicht (keine Performance, Daniel-Wunsch).
        GeometryReader { geo in
            let W = geo.size.width
            // Schwelle: unter STAGE_MIN ist zu wenig Platz für einen sinnvollen Visualizer.
            let STAGE_MIN: CGFloat = 780
            let showStage = W >= STAGE_MIN
            let showHist = showHistory
            let stageW: CGFloat = showStage ? min(520, max(300, W * 0.30)) : 0
            let dividers = CGFloat((showStage ? 1 : 0) + (showHist ? 1 : 0))
            let rest = W - stageW - dividers
            // Verbleibende Breite teilen sich Stations + (optional) Verlauf.
            let stationsW = showHist ? max(220, rest * 0.5) : max(240, rest)
            let histW = max(220, rest * 0.5)
            HStack(spacing: 0) {
                consoleStationsColumn(width: stationsW)
                if showStage {
                    Rectangle().fill(theme.palette.divider).frame(width: 1)
                    // Stage exakt auf stageW zwingen (direkt .frame(width:), kein Overlay).
                    StageView()
                        .frame(width: stageW)
                        .clipped()
                }
                if showHist {
                    Rectangle().fill(theme.palette.divider).frame(width: 1)
                    HistoryPanel(onClose: { withAnimation { showHistory = false } })
                        .frame(width: histW)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    /// Linke Spalte im console-Layout: Stations-Header + scrollbare Senderliste.
    /// GeometryReader-Wrapper zwingt den Inhalt auf die KONKRETE Spaltenbreite — sonst
    /// schrumpft der VStack/die List auf ihre Inhaltsbreite (Sender-Sliver), obwohl der
    /// aeussere Frame breit ist.
    private func consoleStationsColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Spalten-Kopf: nur Titel (Suche/Hinzufügen/Bearbeiten sitzen in der Kopfleiste).
            HStack(spacing: 8) {
                // Im midi-Theme heißt der Header "STATIONS.EXE" (Terminal-Stil)
                SectionHeader(theme.id == .midi ? "STATIONS.EXE" : "STATIONS")
                Spacer()
                if editing {
                    Text(theme.fonts.uppercaseHeaders ? "BEARBEITEN" : "Bearbeiten")
                        .font(theme.font(.label, size: 9 * uiFontScale, weight: .semibold))
                        .foregroundStyle(theme.palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle()
                .fill(theme.palette.divider)
                .frame(height: 1)

            if editing {
                // Bearbeiten-Modus: native List (Reihenfolge/Löschen/An-Aus/Favorit/Edit).
                // Bewusst nativ — Funktion vor Theming; der Theme-Hintergrund scheint durch.
                List {
                    ForEach(store.stations) { st in
                        EditRow(station: st) { editStation = st }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    .onDelete { store.delete(at: $0, in: store.stations) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                // Wiedergabe-Modus: themed Senderzeilen. ScrollView+VStack (nicht List),
                // damit die Theme-Optik exakt steuerbar ist; Breite kommt vom GeometryReader.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.enabledStations) { st in
                            ConsoleStationRow(station: st)
                            Rectangle()
                                .fill(theme.palette.divider)
                                .frame(height: 1)
                                .opacity(0.5)
                        }
                    }
                }
            }
        }
        .frame(width: width)
        .background { ThemedSurface(.panel) }
    }
}

// MARK: - Themed Stations-Zeile (console-Layout)

/// Sender-Zeile fuer das console-Layout. Passt Marker und Stil dem Theme an.
/// Klick-Aktion: dieselbe wie in PlayRow (player.toggle).
private struct ConsoleStationRow: View {
    @EnvironmentObject var player: RadioPlayer
    @EnvironmentObject var health: StationHealth
    @Environment(\.theme) private var theme
    // UI-Schriftfaktor (CMD +/−/0) — muss auch im console-Layout wirken (Bug 1b:
    // console-Zeilen nutzten feste Groessen und wuchsen nicht mit).
    @Environment(\.uiFontScale) private var uiFontScale
    let station: Station

    @State private var showError = false

    private var isCurrent: Bool { player.currentStation?.id == station.id }
    private var isActive: Bool { isCurrent && player.isPlaying }

    private var badReason: String? {
        if case .bad(let r) = health.states[station.id] ?? .unknown { return r }
        return nil
    }

    /// Index des Senders in der sichtbaren Liste (fuer retro-Nummerierung).
    @EnvironmentObject var store: Store
    private var stationIndex: Int? {
        store.enabledStations.firstIndex(where: { $0.id == station.id })
    }

    var body: some View {
        Button {
            player.toggle(station)
        } label: {
            HStack(spacing: 8) {
                // Fuehrender Marker je nach Theme-Stil
                leadingMarker

                VStack(alignment: .leading, spacing: 2) {
                    // Stations-Name (im midi-Theme mit ">>> "-Prefix)
                    let nameText = (theme.control == .terminal) ? ">>> \(station.name)" : station.name
                    Text(nameText)
                        .font(theme.font(.body, size: 12 * uiFontScale, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isActive ? theme.palette.selectionText : theme.palette.textPrimary)
                        .lineLimit(1)
                    // Aktueller Titel wenn dieser Sender spielt
                    if isCurrent && !player.nowPlayingTitle.isEmpty {
                        Text(player.nowPlayingTitle)
                            .font(theme.font(.label, size: 10 * uiFontScale))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Rechte Seite: Favorit, Ladesymbol, Warnung
                if station.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.palette.favorite)
                }
                if isCurrent && player.isLoading {
                    ProgressView().controlSize(.mini)
                }
                if let reason = badReason {
                    Button { showError.toggle() } label: { Text("⚠️").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Sender nicht erreichbar")
                        .popover(isPresented: $showError) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sender nicht erreichbar").font(.headline)
                                Text(reason).font(.callout)
                                Text(station.url).font(.caption)
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .padding(12).frame(width: 300)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Bug 1 (Senderliste in Design-Themes nicht klickbar): macOS-SwiftUI-Eigenheit —
        // ein Plain-Button in der themed Stations-ScrollView bekam KEINE Klicks, solange kein
        // eigener Gesture-Recognizer an der Zeile hing (nur im schlicht-Theme klappte es).
        // Dieser leere simultaneousGesture „primt" das Hit-Testing der Zeile; die eigentliche
        // Aktion macht weiterhin allein die Button-Aktion oben (kein Doppel-Toggle).
        .simultaneousGesture(TapGesture().onEnded { })
        // Selektierter/spielender Sender: Auswahl-Hintergrund
        .background(
            isActive
                ? theme.palette.selection.opacity(0.25)
                : Color.clear
        )
        .foregroundStyle(theme.palette.textPrimary)
    }

    /// Fuehrender Marker (LED, Nummer, Bullet) je nach Theme-Kontrollstil.
    @ViewBuilder
    private var leadingMarker: some View {
        switch theme.control {
        case .neon, .terminal:
            // Leuchtender LED-Punkt
            LEDDot(on: isActive, color: theme.palette.playActive, size: 8)
                .frame(width: 14)

        case .knob:
            // Kleine Nummer (retro/stack) oder Radio-Symbol
            if let idx = stationIndex {
                Text("\(idx + 1).")
                    .font(theme.font(.label, size: 10 * uiFontScale, weight: .medium))
                    .foregroundStyle(isActive ? theme.palette.accent : theme.palette.textDim)
                    .frame(width: 20, alignment: .trailing)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.palette.textDim)
                    .frame(width: 20)
            }

        case .stamp, .hairline, .plain:
            // Einfacher Bullet
            Circle()
                .fill(isActive ? theme.palette.playActive : theme.palette.divider)
                .frame(width: 5, height: 5)
                .frame(width: 14)
        }
    }
}

// MARK: - StageView (center column)

/// Mittlere Spalte: der Visualizer (Now-Playing-Anzeige sitzt jetzt im Fuß — groß+kopierbar).
/// Wird responsiv ganz ausgeblendet, wenn das Fenster zu schmal ist (consoleBody) → dann
/// rendert hier nichts mehr und die TimelineView-Animation frisst keine Performance.
struct StageView: View {
    @EnvironmentObject var player: RadioPlayer
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Buehnen-Hintergrundflaeche
            ThemedSurface(.stage)

            if theme.id == .retro {
                // Retro: VU-Meter in ein eingelassenes Mess-Panel mit gebürstetem Metall-
                // Bezel fassen, dahinter warmes Bernstein-Röhrenglühen (Vintage-Amp-Wärme).
                retroMeterStage
            } else {
                // Visualizer füllt die Stage
                VisualizerView(isPlaying: player.isPlaying)
                    .padding(20)
            }
        }
    }

    /// Retro-Bühne: Amber-Glow + eingefasstes VU-Mess-Panel.
    private var retroMeterStage: some View {
        let amber = theme.palette.accent
        let playing = player.isPlaying
        return ZStack {
            // 1) Weiter, warmer Halo über der ganzen Bühne (sichtbar im Rand um das Panel).
            RadialGradient(
                gradient: Gradient(colors: [Color(hex: "#E08A2E").opacity(playing ? 0.22 : 0.10), .clear]),
                center: .center, startRadius: 30, endRadius: 380
            )
            .blendMode(.screen)

            // 2) VU-Meter im eingelassenen, von innen warm beleuchteten Mess-Panel.
            VisualizerView(isPlaying: playing)
                .padding(16)
                // Panel-Fläche: dunkle Glasscheibe mit Amber-Backlight (Röhren-Hinterleuchtung)
                // hinter den cremefarbenen Skalen + innerem Schatten oben (Tiefe).
                .background(
                    ZStack {
                        Color(hex: "#17120B")
                        RadialGradient(
                            gradient: Gradient(colors: [amber.opacity(playing ? 0.32 : 0.15),
                                                        amber.opacity(playing ? 0.10 : 0.05), .clear]),
                            center: .center, startRadius: 0, endRadius: 240
                        )
                        .blendMode(.screen)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(LinearGradient(colors: [.black.opacity(0.65), .clear],
                                                   startPoint: .top, endPoint: .center),
                                    lineWidth: 3)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Gebürsteter Metall-Bezel (warmer Stahl/Bronze-Verlauf).
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            LinearGradient(colors: [Color(hex: "#7A6A4E"), Color(hex: "#2C2418"),
                                                    Color(hex: "#6A5A40")],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 6)
                )
                // Schlagschatten → Panel liegt auf der Bühne auf.
                .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
                .padding(.horizontal, 26)
                .padding(.vertical, 30)
        }
    }
}

// Zeile im Bearbeiten-Modus: an/aus, Favorit, Bearbeiten.
struct EditRow: View {
    @EnvironmentObject var store: Store
    let station: Station
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { station.enabled },
                set: { _ in store.toggleEnabled(station) }
            ))
            .labelsHidden()
            .help("In Liste anzeigen")

            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).scaledFont(.body).foregroundStyle(station.enabled ? .primary : .secondary)
                Text(station.url).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            Button {
                store.setFavorite(station)
            } label: {
                Image(systemName: station.favorite ? "star.fill" : "star")
                    .foregroundStyle(station.favorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help("Als Favorit/Autostart setzen")

            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Bearbeiten")
        }
    }
}

// Laufzeit-Formatierung (mm:ss / h:mm:ss). Frueher in NowPlayingBar; die Leiste ist mit
// dem einheitlichen Kopf-Layout entfallen, die Formatierung wird in der Kopfleiste genutzt.
enum PlaybackClock {
    // B2: Laufzeit als mm:ss, ab 1 h als h:mm:ss.
    static func runtime(since start: Date, now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

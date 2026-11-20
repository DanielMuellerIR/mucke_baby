import SwiftUI
import AppKit
import os

let uiLog = Logger(subsystem: "de.danielmuller.macradio", category: "ui")

private struct AppNotices: ViewModifier {
    @ObservedObject var startup: StartupSettings
    @ObservedObject var store: Store

    func body(content: Content) -> some View {
        content
            .alert("Startauswahl", isPresented: $startup.showNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(startup.notice ?? "")
            }
            .alert(store.persistenceMessage, isPresented: $store.persistenceFailed) {
                Button("OK", role: .cancel) {}
            }
    }
}

#if !MUCKE_TRANSPORT_PROBE
@main
#endif
struct MacRadioApp: App {
    private let services = RadioServices.shared
    private var store: Store { services.store }
    private var startup: StartupSettings { services.startup }
    private var player: RadioPlayer { services.player }
    @StateObject private var health = StationHealth()
    private var bookmarks: BookmarkStore { services.bookmarks }
    // Audio-Reaktivität der Visualizer (CoreAudio Process-Tap auf die eigene Ausgabe,
    // vor der Analyse gegen die App-Lautstaerke normalisiert).
    private var audioTap: AudioTap { services.audioTap }
    @NSApplicationDelegateAdaptor(MuckeAppDelegate.self) private var appDelegate
    // Menueleisten-Icon: per Schalter zu/abschaltbar. Default aus.
    @AppStorage("menuBarMode") private var menuBarMode = false
    // Globale Schriftskalierung (CMD +/-/0). macOS-SwiftUI ignoriert dynamicTypeSize,
    // daher eigener Skalierungsfaktor (uiFontScale-Environment) + explizite Fontgroessen.
    @AppStorage("uiZoom") private var uiZoom = 0
    // Aktives Theme (persistiert als ThemeID.rawValue).
    @AppStorage("selectedTheme") private var selectedThemeRaw = "schlicht"
    // Sparkle-Selbst-Update: genau EIN langlebiger Updater (siehe UpdaterController.swift).
    @StateObject private var updater = UpdaterViewModel()
    // SwiftUI kann nach einem Theme-Wechsel im zuvor erzwungenen Farbschema
    // bleiben. Für `schlicht` setzen wir deshalb explizit das Systemfarbschema.
    @StateObject private var sysAppearance = SystemAppearance()
    @StateObject private var visualizerWindow = PlayerWindowState()

    /// Aktuelles Theme-Objekt aus dem gespeicherten Rohwert.
    private var theme: Theme { Theme.theme(raw: selectedThemeRaw) }

    /// Effektiver Scheme: Theme erzwingt einen → den nehmen; `schlicht` (nil) → System-Scheme.
    /// Niemals nil, damit der Wechsel sauber durchschlaegt.
    private var effectiveScheme: ColorScheme { theme.colorScheme ?? sysAppearance.scheme }

    var body: some Scene {
        // Normales App-Fenster (Standardmodus).
        WindowGroup("Mucke, Baby!", id: "main-player") {
            ContentView()
                .environmentObject(store)
                .environmentObject(startup)
                .environmentObject(player)
                .environmentObject(bookmarks)
                .environmentObject(player.history)   // Wiedergabeverlauf
                .environmentObject(health)           // Sender-Healthcheck
                .environmentObject(audioTap)         // Audio-Reaktivität
                .environmentObject(services.recognition)
                .environmentObject(visualizerWindow)
                .modifier(VisualizerMotionFixture())
                .environment(\.uiFontScale, TypographyMetrics.scale(uiZoom))
                // Theme und ColorScheme ins Environment injizieren
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
                .modifier(AppNotices(startup: startup, store: store))
        }
        // Die versteckte native Titelleiste lässt Platz für die gemeinsame Kopfleiste
        // ohne Glas-Kapseln. Sie reserviert links Platz für die Ampel-Buttons.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)         // frei groesser ziehbar
        .defaultSize(width: 940, height: 620)        // Startgroesse: Platz fuer 3-Spalten-Themes
        .commands {
            StationCommands(store: store, player: player)
            RecordingLibraryCommands()
            // „Nach Updates suchen …" im App-Menue (direkt unter „Über …").
            // Deaktiviert, solange Sparkle nicht suchen kann (laufende Suche/Installation).
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // Cmd+"=" ist in ContentView zusätzlich belegt, weil "+" auf manchen
            // Tastaturlayouts nur mit der Umschalttaste erreichbar ist.
            CommandMenu("Darstellung") {
                Button("Schrift größer") {
                    uiZoom = min(uiZoom + 1, 5)
                    uiLog.notice("zoom+ -> \(uiZoom, privacy: .public)")
                }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Schrift kleiner") {
                    uiZoom = max(uiZoom - 1, -3)
                    uiLog.notice("zoom- -> \(uiZoom, privacy: .public)")
                }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Originalgröße") {
                    uiZoom = 0
                    uiLog.notice("zoom0")
                }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                VisualizerOpenButton(presentation: visualizerWindow)
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

        Window("Miniplayer", id: "mini-player") {
            MiniPlayerView()
                .environmentObject(store)
                .environmentObject(startup)
                .environmentObject(player)
                .environmentObject(bookmarks)
                .environmentObject(audioTap)
                .environmentObject(services.recognition)
                .environment(\.uiFontScale, TypographyMetrics.scale(uiZoom))
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        }
        .defaultSize(width: 420, height: 240)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("m", modifiers: [.command, .shift])

        // Eine feste Präsentationsidentität erhält genau eine große Ansicht.
        WindowGroup("Visualizer", id: "visualizer", for: VisualizerWindowIdentity.self) { _ in
            VisualizerWindowView()
                .modifier(VisualizerMotionFixture())
                .environmentObject(store)
                .environmentObject(startup)
                .environmentObject(player)
                .environmentObject(audioTap)
                .environmentObject(services.recognition)
                .environmentObject(visualizerWindow)
                .environment(\.uiFontScale, TypographyMetrics.scale(uiZoom))
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        } defaultValue: { .shared }
        .defaultSize(width: 940, height: 620)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        Window("Audioeinstellungen", id: "audio-settings") {
            AudioSettingsView()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(services.audioSettings)
                .environment(\.uiFontScale, TypographyMetrics.scale(uiZoom))
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        }
        .defaultSize(width: 620, height: 650)
        .windowResizability(.contentMinSize)

        // Optionaler Menueleisten-Modus. `isInserted` blendet das Icon
        // zur Laufzeit ein/aus, ohne die Szene neu aufzubauen.
        MenuBarExtra("Mucke, Baby!", systemImage: "dot.radiowaves.left.and.right",
                     isInserted: $menuBarMode) {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(startup)
                .environmentObject(player)
                .environmentObject(bookmarks)
                .environment(\.uiFontScale, TypographyMetrics.scale(uiZoom))
                // Auch im Menueleisten-Popup Theme + ColorScheme setzen
                .environment(\.theme, theme)
                .preferredColorScheme(effectiveScheme)
        }
        .menuBarExtraStyle(.window)
    }
}

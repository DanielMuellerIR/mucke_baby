// Theme.swift — Theme-System für „Mucke, Baby!".
//
// EINE theme-parametrisierte Codebasis: jedes Aussehen ist eine `Theme`-Instanz.
// `schlicht` reproduziert exakt das bisherige native Look-and-feel (dark/light
// folgt dem System). Die 6 Design-Themes setzen die Entwürfe aus
// `design-proposal/` um. Views lesen Farben/Fonts/Texturen aus `@Environment(\.theme)`
// statt sie hart zu codieren. Fehlt eine Textur-PNG, liefert der Loader `nil`
// und die View fällt auf die Palette-Farbe zurück — alles bleibt lauffähig.
//
// Spec: design-proposal/THEME-PLAN.md

import SwiftUI
import AppKit

// MARK: - Hex-Farbhelfer

extension Color {
    /// Erzeugt eine Farbe aus einem Hex-String wie "#1A1B1E" oder "RRGGBBAA".
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8) / 255
            a = Double(v & 0x000000FF) / 255
        default: // RRGGBB (und Fallback)
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Aufzählungen

/// Alle wählbaren Themes. `rawValue` wird in `@AppStorage("selectedTheme")` persistiert.
/// Reihenfolge = Durchschalt-Reihenfolge des Kopf-Buttons.
enum ThemeID: String, CaseIterable, Identifiable {
    // `stack` war frueher `marshall` — umbenannt (Markenrisiko: „Marshall" ist eine
    // eingetragene Marke fuer Verstaerker/Audio). Migration alter Werte: siehe theme(raw:).
    case schlicht, acid, retro, fanzine, stack, danish, midi
    var id: String { rawValue }
}

/// Grob-Layout. `.classic` = heutiger Aufbau (Senderliste + Verlauf-Toggle + Footer).
/// `.console` = 3-Spalten-Skelett aller Mockups (Stations | Stage | History) + Footer.
enum ThemeLayout { case classic, console }

/// Visualizer-Spielart in der Stage-Mitte (TimelineView-animiert, gated auf isPlaying).
enum VisualizerStyle { case none, waveform, vu, fabric, midiNotes, bars }

/// Bedien-Optik (Buttons, Slider, Sender-Marker).
enum ControlStyle { case plain, neon, knob, stamp, hairline, terminal }

/// Schrift-Familien — ausschließlich macOS-Bordmittel (kein Font-Bundling nötig).
enum ThemeFontFamily { case system, monospaced, serif, typewriter, cursive, thin, handwritten }

/// Schrift-Rolle, die eine View anfragt.
enum FontSlot { case title, body, label }

// MARK: - Palette & Fonts

/// Alle Farb-Token eines Themes. Views greifen ausschließlich hierauf zu.
struct ThemePalette {
    var windowBackground: Color   // Fenster-Grundfläche / Window-Bg
    var panelBackground: Color    // Seitenspalten (Stations/History)
    var stageBackground: Color    // Mittel-Bühne (NowPlaying/Visualizer)
    var textPrimary: Color        // Haupttext
    var textSecondary: Color      // Nebentext/Labels
    var textDim: Color            // sehr leise (Zeiten, Hints)
    var accent: Color             // Leitfarbe
    var accent2: Color            // Zweitfarbe
    var playActive: Color         // aktives Play-Icon / laufender Sender
    var liveBadge: Color          // Live-/Aufnahme-Indikator
    var favorite: Color           // Stern/Favorit
    var alert: Color              // Fehler/rote Hinweise
    var divider: Color            // Trennlinien
    var selection: Color          // Auswahl-Hintergrund (Sender-Zeile)
    var selectionText: Color      // Text auf Auswahl
    var visualizer1: Color        // Visualizer-Verlauf Start
    var visualizer2: Color        // Visualizer-Verlauf Ende
}

/// Schrift-Konfiguration eines Themes.
struct ThemeFonts {
    var title: ThemeFontFamily
    var body: ThemeFontFamily
    var label: ThemeFontFamily
    var tracking: CGFloat = 0       // Buchstabenabstand (Header/Spaltentitel)
    var uppercaseHeaders: Bool = false
}

// MARK: - Theme

struct Theme: Identifiable {
    let id: ThemeID
    var name: String
    /// nil = dem System folgen (schlicht). Sonst Dark/Light erzwingen.
    var colorScheme: ColorScheme?
    var layout: ThemeLayout
    var palette: ThemePalette
    var fonts: ThemeFonts
    var control: ControlStyle
    var visualizer: VisualizerStyle
    // Textur-Dateinamen (in Resources/themes/<id>/). nil = keine Textur.
    var backgroundTexture: String? = nil
    var panelTexture: String? = nil
    var stageTexture: String? = nil
    var accentTexture: String? = nil   // z.B. Goldplatte (marshall), Stoffscheibe (danish)

    var isConsole: Bool { layout == .console }

    // MARK: Font-Resolver

    /// Liefert die Font für eine Rolle in der gewünschten Größe/Stärke.
    func font(_ slot: FontSlot, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fam: ThemeFontFamily
        switch slot {
        case .title: fam = fonts.title
        case .body:  fam = fonts.body
        case .label: fam = fonts.label
        }
        return Theme.resolve(fam, size: size, weight: weight)
    }

    static func resolve(_ fam: ThemeFontFamily, size: CGFloat, weight: Font.Weight) -> Font {
        switch fam {
        case .system:     return .system(size: size, weight: weight)
        case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
        case .serif:      return .system(size: size, weight: weight, design: .serif)
        case .typewriter: return .custom("American Typewriter", fixedSize: size).weight(weight)
        case .cursive:    return .custom("Snell Roundhand", fixedSize: size).weight(weight)
        case .thin:       return .system(size: size, weight: weight == .regular ? .ultraLight : weight)
        case .handwritten:return .custom("Noteworthy", fixedSize: size).weight(weight)
        }
    }

    // MARK: Textur-Loader

    /// Lädt eine Theme-Textur aus dem Bundle (`Contents/Resources/themes/<id>/`).
    /// Gibt `nil` zurück, wenn die Datei fehlt → Aufrufer nutzt Palette-Farbe.
    func image(_ file: String?) -> Image? {
        guard let file else { return nil }
        let ns = file as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "png" : ns.pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext,
                                        subdirectory: "themes/\(id.rawValue)"),
              let img = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: img)
    }

    // MARK: Lookup & Zyklus

    static func theme(_ id: ThemeID) -> Theme { all.first { $0.id == id } ?? all[0] }
    static func theme(raw: String) -> Theme {
        // Migration: alter persistierter Wert „marshall" → „stack" (Theme umbenannt).
        let migrated = (raw == "marshall") ? "stack" : raw
        return theme(ThemeID(rawValue: migrated) ?? .schlicht)
    }

    /// Nächstes Theme im Zyklus (für den Kopf-Button).
    var nextID: ThemeID {
        let cases = ThemeID.allCases
        let i = cases.firstIndex(of: id) ?? 0
        return cases[(i + 1) % cases.count]
    }

    // MARK: Definitionen aller Themes

    static let all: [Theme] = [schlicht, acid, retro, fanzine, stack, danish, midi]

    // 0 — schlicht (Anzeigename „Standard"): heutiges natives Aussehen, dark/light folgt System.
    // Interner rawValue/case bleibt `schlicht` (Persistenz in @AppStorage darf nicht brechen).
    static let schlicht = Theme(
        id: .schlicht, name: "Standard", colorScheme: nil, layout: .classic,
        palette: ThemePalette(
            windowBackground: Color(nsColor: .windowBackgroundColor),
            panelBackground:  Color(nsColor: .windowBackgroundColor),
            stageBackground:  Color(nsColor: .windowBackgroundColor),
            textPrimary: .primary, textSecondary: .secondary, textDim: .secondary,
            accent: .accentColor, accent2: .accentColor,
            playActive: .accentColor, liveBadge: .accentColor,
            favorite: .yellow, alert: .red,
            divider: Color(nsColor: .separatorColor),
            selection: Color.accentColor.opacity(0.15), selectionText: .primary,
            visualizer1: .accentColor, visualizer2: .accentColor),
        fonts: ThemeFonts(title: .system, body: .system, label: .system),
        // Standard nutzt jetzt auch das 3-Spalten-Layout (minimalste Skin) und bekommt
        // einen schlichten Waveform-Visualizer in der Akzentfarbe.
        control: .plain, visualizer: .waveform)

    // 1 — acid: Beton, Neon-Grün/Cyan, Monospace, Waveform.
    static let acid = Theme(
        id: .acid, name: "Acid Rave", colorScheme: .dark, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#1A1B1E"),
            panelBackground:  Color(hex: "#121315"),
            stageBackground:  Color(hex: "#0E0F11"),
            textPrimary: Color(hex: "#E8EBE9"), textSecondary: Color(hex: "#8A8F94"),
            textDim: Color(hex: "#5A5F64"),
            accent: Color(hex: "#39FF14"), accent2: Color(hex: "#00E5FF"),
            playActive: Color(hex: "#39FF14"), liveBadge: Color(hex: "#00E5FF"),
            favorite: Color(hex: "#39FF14"), alert: Color(hex: "#FF3B3B"),
            divider: Color(hex: "#2A2C2F"),
            selection: Color(hex: "#39FF14").opacity(0.16), selectionText: Color(hex: "#E8EBE9"),
            visualizer1: Color(hex: "#00E5FF"), visualizer2: Color(hex: "#39FF14")),
        fonts: ThemeFonts(title: .monospaced, body: .monospaced, label: .monospaced,
                          tracking: 1.5, uppercaseHeaders: true),
        control: .neon, visualizer: .waveform,
        backgroundTexture: "bg-concrete.png")

    // 2 — retro: gebürstetes Metall + Pergament, Amber/Gold, Serif, VU-Meter.
    static let retro = Theme(
        id: .retro, name: "Retro", colorScheme: .dark, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#1C1A17"),
            panelBackground:  Color(hex: "#23201B"),
            stageBackground:  Color(hex: "#1A1714"),
            textPrimary: Color(hex: "#F5F0E1"), textSecondary: Color(hex: "#C9A227"),
            textDim: Color(hex: "#8A7B52"),
            accent: Color(hex: "#FF9F0A"), accent2: Color(hex: "#C9A227"),
            playActive: Color(hex: "#FF9F0A"), liveBadge: Color(hex: "#FF9F0A"),
            favorite: Color(hex: "#C9A227"), alert: Color(hex: "#C0392B"),
            divider: Color(hex: "#3A352C"),
            selection: Color(hex: "#FF9F0A").opacity(0.18), selectionText: Color(hex: "#F5F0E1"),
            visualizer1: Color(hex: "#FF9F0A"), visualizer2: Color(hex: "#C9A227")),
        fonts: ThemeFonts(title: .serif, body: .serif, label: .serif,
                          tracking: 0.5, uppercaseHeaders: true),
        control: .knob, visualizer: .vu,
        backgroundTexture: "bg-brushed.png", panelTexture: "paper.png")

    // 3 — fanzine: Zeitungspapier (LIGHT), Tinte-Schwarz, Typewriter, gezackte Waveform.
    static let fanzine = Theme(
        id: .fanzine, name: "Fanzine", colorScheme: .light, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#ECEAE3"),
            panelBackground:  Color(hex: "#F4F2EC"),
            stageBackground:  Color(hex: "#F0EEE6"),
            textPrimary: Color(hex: "#0D0D0D"), textSecondary: Color(hex: "#3A3A3A"),
            textDim: Color(hex: "#6A6A6A"),
            accent: Color(hex: "#0D0D0D"), accent2: Color(hex: "#B5231F"),
            playActive: Color(hex: "#0D0D0D"), liveBadge: Color(hex: "#B5231F"),
            favorite: Color(hex: "#0D0D0D"), alert: Color(hex: "#B5231F"),
            divider: Color(hex: "#0D0D0D"),
            selection: Color(hex: "#0D0D0D").opacity(0.10), selectionText: Color(hex: "#0D0D0D"),
            visualizer1: Color(hex: "#0D0D0D"), visualizer2: Color(hex: "#0D0D0D")),
        fonts: ThemeFonts(title: .typewriter, body: .typewriter, label: .typewriter,
                          tracking: 0.5, uppercaseHeaders: true),
        control: .stamp, visualizer: .waveform,
        backgroundTexture: "bg-newsprint.png")

    // 4 — stack (früher „marshall", umbenannt wg. Markenrecht): schwarzes Tolex +
    // Goldplatte, Serif-Titel (KEINE Marshall-Schreibschrift mehr), Knöpfe, rotes Jewel.
    static let stack = Theme(
        id: .stack, name: "GuitarAmp", colorScheme: .dark, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#0A0A0A"),
            panelBackground:  Color(hex: "#141414"),
            stageBackground:  Color(hex: "#0D0D0D"),
            textPrimary: Color(hex: "#F7F4EC"), textSecondary: Color(hex: "#C8A03C"),
            textDim: Color(hex: "#8A7430"),
            accent: Color(hex: "#C8A03C"), accent2: Color(hex: "#E8C766"),
            playActive: Color(hex: "#E8C766"), liveBadge: Color(hex: "#E0241B"),
            favorite: Color(hex: "#C8A03C"), alert: Color(hex: "#E0241B"),
            divider: Color(hex: "#2A2419"),
            selection: Color(hex: "#C8A03C").opacity(0.18), selectionText: Color(hex: "#F7F4EC"),
            visualizer1: Color(hex: "#E8C766"), visualizer2: Color(hex: "#C8A03C")),
        fonts: ThemeFonts(title: .serif, body: .system, label: .system,
                          tracking: 0.5, uppercaseHeaders: true),
        control: .knob, visualizer: .vu,
        backgroundTexture: "bg-tolex.png", accentTexture: "plate-gold.png")

    // 5 — danish: seidenmattes Alu (LIGHT), Eiche/Wolle, ultra-thin Sans, minimal-Equalizer.
    // (Stoff-Scheibe entfernt — Kreis bewusst weggelassen; Kontrast angehoben.)
    static let danish = Theme(
        id: .danish, name: "Danish", colorScheme: .light, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#ECEAE6"),
            panelBackground:  Color(hex: "#F3F1EE"),
            stageBackground:  Color(hex: "#EFEDE9"),
            // Kontrast nochmals angehoben (nicht-fette Schrift zu blass): Sekundär-/Dim-
            // Texte deutlich dunkler — die dünne Schriftstärke braucht kräftigere Farbe.
            textPrimary: Color(hex: "#1A1A1A"), textSecondary: Color(hex: "#332F2A"),
            textDim: Color(hex: "#514C44"),
            accent: Color(hex: "#4C4842"), accent2: Color(hex: "#B5894F"),
            playActive: Color(hex: "#1C1C1C"), liveBadge: Color(hex: "#B5894F"),
            favorite: Color(hex: "#B5894F"), alert: Color(hex: "#B5231F"),
            divider: Color(hex: "#CFCBC3"),
            selection: Color(hex: "#1C1C1C").opacity(0.08), selectionText: Color(hex: "#1C1C1C"),
            // Equalizer-Balken: warmes Eiche-Oben → Anthrazit-Unten (klar sichtbar).
            visualizer1: Color(hex: "#B5894F"), visualizer2: Color(hex: "#57534B")),
        fonts: ThemeFonts(title: .thin, body: .thin, label: .thin,
                          tracking: 1.0, uppercaseHeaders: true),
        control: .hairline, visualizer: .bars,
        backgroundTexture: "bg-aluminum.png", panelTexture: "oak.png",
        accentTexture: "fabric-wool.png")

    // 6 — midi: pechschwarz + Cyber-Grid, Neon Magenta/Cyan/Violett, Terminal, fallende Noten.
    static let midi = Theme(
        id: .midi, name: "Black MIDI", colorScheme: .dark, layout: .console,
        palette: ThemePalette(
            windowBackground: Color(hex: "#050507"),
            panelBackground:  Color(hex: "#0A0A12"),
            stageBackground:  Color(hex: "#060608"),
            textPrimary: Color(hex: "#E8E8FF"), textSecondary: Color(hex: "#7A7AA0"),
            textDim: Color(hex: "#4A4A66"),
            accent: Color(hex: "#FF2EC4"), accent2: Color(hex: "#1EE6FF"),
            playActive: Color(hex: "#1EE6FF"), liveBadge: Color(hex: "#1EE6FF"),
            favorite: Color(hex: "#FF2EC4"), alert: Color(hex: "#FF2EC4"),
            divider: Color(hex: "#1A1A2E"),
            selection: Color(hex: "#FF2EC4").opacity(0.16), selectionText: Color(hex: "#E8E8FF"),
            visualizer1: Color(hex: "#FF2EC4"), visualizer2: Color(hex: "#1EE6FF")),
        fonts: ThemeFonts(title: .monospaced, body: .monospaced, label: .monospaced,
                          tracking: 1.0, uppercaseHeaders: true),
        control: .terminal, visualizer: .midiNotes,
        backgroundTexture: "bg-cyber.png")
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = Theme.theme(.schlicht)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

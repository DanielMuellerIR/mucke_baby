// ThemedComponents.swift — Wiederverwendbare UI-Primitive für das Theme-System.
//
// Alle Komponenten lesen ihr Aussehen aus `@Environment(\.theme)`.
// Keine App-Typen (Station, RadioPlayer, ContentView …) hier — diese Datei
// ist self-contained: nur SwiftUI, AppKit und Typen aus Theme.swift.
//
// Öffentliche API (exakte Namen/Signaturen — andere Dateien hängen davon ab):
//   ThemedSurface    — Hintergrundfläche (Fenster / Panel / Stage)
//   SectionHeader    — Spalten-/Abschnittstitel ("STATIONS", "HISTORY" …)
//   LEDDot           — Leuchtpunkt für Sender-Zeilen
//   KnobView         — Dekorativer Drehknopf (retro/stack)
//   VisualizerView   — Bühnen-Visualizer, alle VisualizerStyle-Varianten
//   View.neonGlow    — Neon-Glow-Helper (Shadow-basiert)

import SwiftUI
import AppKit

// MARK: - ThemedSurface

/// Hintergrundfläche, die je nach `Kind` die passende Palette-Farbe oder Textur zeigt.
/// Verwendung: `.background { ThemedSurface(.panel) }`
///
/// Scrim-Alphas (leicht zu tunen):
///   WINDOW_SCRIM  — Textur-Transparenz fürs Fenster (höher = matter, niedriger = Textur sichtbarer)
///   STAGE_SCRIM   — Stärker abgedämpft, da Stage-Text Priorität hat
///   PANEL_OPACITY — Panel bleibt fast undurchsichtig (Lesbarkeit der Listentexte)
private let WINDOW_SCRIM:  Double = 0.32   // Grundfenster: Textur gut sichtbar, Farbe dominiert
private let STAGE_SCRIM:   Double = 0.50   // Stage: gedämpft für Titeltext-Lesbarkeit
private let PANEL_OPACITY: Double = 0.88   // Panel: fast deckend, nur leichtes Durchscheinen

public struct ThemedSurface: View {

    /// Welche Fläche soll gezeichnet werden.
    public enum Kind { case window, panel, stage }

    private let kind: Kind
    @Environment(\.theme) private var theme

    public init(_ kind: Kind = .window) {
        self.kind = kind
    }

    public var body: some View {
        // Rein dekorativ (Hintergrund/Textur) → soll NIE Klicks abfangen. Defensive Härtung:
        // anders als die schlichte `Color` im schlicht-Theme sind die Textur-`Image`/
        // `ProceduralMaterial`-`Canvas`-Layer hit-testbar. (Hinweis: das alleinige Abschalten
        // hier hat Bug 1 — Senderliste in Design-Themes nicht klickbar — NICHT behoben; der
        // eigentliche Fix ist der Gesture-Primer in `ConsoleStationRow`. Trotzdem korrekt, dass
        // eine reine Deko-Fläche kein Hit-Testing beansprucht.)
        surface.allowsHitTesting(false)
    }

    /// Die eigentliche Hintergrund-Zeichnung (ohne Hit-Testing-Logik — die sitzt in `body`).
    @ViewBuilder
    private var surface: some View {
        // Palette-Grundfarbe je nach Fläche
        let baseColor: Color = {
            switch kind {
            case .window: return theme.palette.windowBackground
            case .panel:  return theme.palette.panelBackground
            case .stage:  return theme.palette.stageBackground
            }
        }()

        // schlicht: kein Overlay — pixel-identisch zum bisherigen Verhalten.
        if theme.id == .schlicht {
            baseColor
        } else {
            switch kind {

            // Fenster-Hintergrund: Textur mit Scrim, sonst prozedurales Overlay.
            case .window:
                if let img = theme.image(theme.backgroundTexture) {
                    // WICHTIG: `baseColor` ist der Größen-Geber (füllt exakt das Angebot). Die
                    // Textur kommt als OVERLAY drauf — Overlays vergrößern den Eltern-Frame NICHT.
                    // Früher saß das scaledToFill-Image als ZStack-Geschwister → der ZStack wuchs
                    // auf die Bildgröße (überlief das `.frame(width:)`) und Geschwister-Views
                    // (z.B. der Stage-Visualizer) erbten die falsche, viel zu große Breite.
                    baseColor
                        .overlay { img.resizable().scaledToFill() }
                        .overlay { baseColor.opacity(WINDOW_SCRIM) }
                        .clipped()
                } else {
                    baseColor.overlay {
                        ProceduralMaterial(themeID: theme.id, kind: kind,
                                           accent: theme.palette.accent,
                                           accent2: theme.palette.accent2)
                    }
                }

            // Stage: eigene Textur wenn vorhanden, sonst Fallback auf window-Textur —
            // stärkerer Scrim damit der Bühnen-Titeltext klar lesbar bleibt.
            case .stage:
                let stageTex = theme.stageTexture ?? theme.backgroundTexture
                if let img = theme.image(stageTex) {
                    // Größen-Geber = baseColor; Textur als Overlay (siehe .window oben). Sonst
                    // bläht das scaledToFill-Image den Stage-Frame auf und die VU-Meter rechnen
                    // mit einer viel zu großen Breite → Nadeln ragen über den Stage-Rand.
                    baseColor
                        .overlay { img.resizable().scaledToFill() }
                        .overlay { baseColor.opacity(STAGE_SCRIM) }
                        .clipped()
                } else {
                    baseColor.overlay {
                        ProceduralMaterial(themeID: theme.id, kind: kind,
                                           accent: theme.palette.accent,
                                           accent2: theme.palette.accent2)
                    }
                }

            // Panel: kein schweres Textur-Overlay — Listentexte müssen lesbar bleiben.
            // Fast-deckende Palette-Farbe + optionales prozedurales Overlay erzeugt
            // einen dezenten Kabinett-Einbau-Look (Fenster-Textur scheint leicht durch).
            case .panel:
                if theme.id == .danish {
                    // Danish: Senderliste + Historie sollen KEINE gebürstete Aluminium-Textur
                    // tragen (Daniel: Textur nur in Kopf/Fuß, dort über die .window-Fläche).
                    // Darum deckende Panel-Farbe, kein Fenster-Durchschein, kein Alu-Overlay
                    // → ruhige, edle Flächen mit klarem Textkontrast.
                    baseColor
                } else {
                    baseColor.opacity(PANEL_OPACITY)
                        .overlay {
                            ProceduralMaterial(themeID: theme.id, kind: kind,
                                               accent: theme.palette.accent,
                                               accent2: theme.palette.accent2)
                        }
                }
            }
        }
    }
}

// MARK: - ProceduralMaterial

/// Prozeduraler Materialeindruck als leichtes Canvas-Overlay über der Palette-Grundfarbe.
/// Alle Muster sind deterministisch (kein `Date`/`random`) und CPU-schonend (< 300 Primitive).
/// Alpha-Zielwert: 0.04–0.12 — Palette-Farbe dominiert immer.
private struct ProceduralMaterial: View {

    let themeID: ThemeID
    let kind: ThemedSurface.Kind
    let accent: Color
    let accent2: Color

    var body: some View {
        // Overlay-Stärke minimal anpassen je Fläche:
        // stage etwas dezenter als window/panel, da dort Text-Dichte hoch ist.
        let scale: Double = kind == .stage ? 0.75 : 1.0

        Canvas { context, size in
            switch themeID {
            case .schlicht:
                break   // Kein Overlay — niemals hier, guard oben greift schon

            case .acid:
                // Beton: gemottelte hellere/dunklere Flecken + leichte Vignette.
                // Kleiner LCG-Hash → deterministisch, kein random().
                drawConcreteTexture(context: context, size: size, scale: scale)

            case .retro:
                // Gebürstetes Metall: feine waagrechte 1-pt-Linien + Sheen-Verlauf.
                drawBrushedMetalTexture(context: context, size: size, scale: scale)

            case .fanzine:
                // Newsprint: feines Halbton-Punktraster + wenige Tinte-Sprenkel.
                drawNewsprintTexture(context: context, size: size, scale: scale)

            case .stack:
                // Tolex-Leder: gejittertes Kleinpunkt-Raster (Kreuzschraffur-Optik) + Vignette.
                drawTolexTexture(context: context, size: size, scale: scale)

            case .danish:
                // Gebürstetes Aluminium: sehr feine senkrechte Linien + horizontaler Sheen.
                drawAluminiumTexture(context: context, size: size, scale: scale)

            case .midi:
                // Cyber-Grid: Neon-Gitterlinien (Magenta/Cyan) + weiche Bokeh-Dots in Ecken.
                drawCyberGridTexture(context: context, size: size, scale: scale,
                                     accent: accent, accent2: accent2)
            }
        }
    }

    // MARK: Beton (acid) — gemottelte Flecken + Vignette

    private func drawConcreteTexture(context: GraphicsContext, size: CGSize, scale: Double) {
        // ~120 kleine ovale Flecken in leicht versetzten Positionen.
        // LCG-Parameter (klassisch): a=1664525, c=1013904223, m=2^32
        var seed: UInt32 = 0xA1C2_D3E4
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }

        let spotCount = 110
        for _ in 0..<spotCount {
            let x = next() * Double(size.width)
            let y = next() * Double(size.height)
            let rx = 6 + next() * 18   // Breite 6…24 pt
            let ry = 4 + next() * 12   // Höhe 4…16 pt
            // Abwechselnd heller / dunkler
            let bright = next() > 0.5
            let alpha = (0.03 + next() * 0.05) * scale
            let col: Color = bright ? Color.white.opacity(alpha) : Color.black.opacity(alpha)
            let rect = CGRect(x: x - rx / 2, y: y - ry / 2, width: rx, height: ry)
            context.fill(Path(ellipseIn: rect), with: .color(col))
        }

        // Sanfte Vignette (rand dunkler)
        let vigAlpha = 0.12 * scale
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: Color.black.opacity(vigAlpha), location: 1.0)
                ]),
                center: .init(x: 0.5, y: 0.5),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.65
            )
        )
    }

    // MARK: Gebürstetes Metall (retro) — waagrechte Linien + Sheen

    private func drawBrushedMetalTexture(context: GraphicsContext, size: CGSize, scale: Double) {
        // Feine waagrechte Linien: Abstand 2 pt, warmes Dunkelbraun, sehr niedrige Alpha.
        let lineSpacing: Double = 2.0
        let lineAlpha = 0.07 * scale
        var y: Double = 0
        // LCG für minimale Positions-Jitter je Linie (macht es organischer)
        var seed: UInt32 = 0xB2C3_D4E5
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }
        while y < Double(size.height) {
            // Leichte Alpha-Variation pro Linie
            let a = lineAlpha * (0.6 + next() * 0.8)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Color.white.opacity(a)), lineWidth: 1)
            y += lineSpacing
        }

        // Sanfter Sheen: helles Band von oben nach unten (simuliert Lichteinfall von oben).
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.06 * scale), location: 0.0),
                    .init(color: Color.white.opacity(0.00), location: 0.45),
                    .init(color: Color.black.opacity(0.05 * scale), location: 1.0)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    // MARK: Newsprint (fanzine) — Halbton-Punktraster + Tinte-Sprenkel

    private func drawNewsprintTexture(context: GraphicsContext, size: CGSize, scale: Double) {
        // Halbton-Raster: reguläres Gitter mit kleinen dunklen Kreisen.
        let gridSize: Double = 8.0   // Rasterweite in pt
        let dotRadius: Double = 0.9  // Punkt-Radius (< gridSize/2 = feine Punkte)
        let dotAlpha = 0.07 * scale

        var gx: Double = gridSize / 2
        while gx < Double(size.width) {
            var gy: Double = gridSize / 2
            while gy < Double(size.height) {
                let rect = CGRect(x: gx - dotRadius, y: gy - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(dotAlpha)))
                gy += gridSize
            }
            gx += gridSize
        }

        // Wenige Tinte-Sprenkel (unregelmäßige kleine Flecken, sehr dezent)
        var seed: UInt32 = 0xC3D4_E5F6
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }
        let speckCount = 35
        for _ in 0..<speckCount {
            let x = next() * Double(size.width)
            let y = next() * Double(size.height)
            let r = 0.5 + next() * 1.5
            let a = (0.04 + next() * 0.07) * scale
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(a)))
        }
    }

    // MARK: Tolex-Leder (stack) — gejittertes Kleinpunkt-Kreuzraster + Vignette

    private func drawTolexTexture(context: GraphicsContext, size: CGSize, scale: Double) {
        // Gejittertes Raster kleiner dunkler Punkte → ergibt Pebble-Textur.
        let gridSize: Double = 7.0
        let dotRadius: Double = 0.8
        let dotAlpha = 0.10 * scale

        var seed: UInt32 = 0xD4E5_F6A7
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }

        var gx: Double = gridSize / 2
        while gx < Double(size.width) {
            var gy: Double = gridSize / 2
            while gy < Double(size.height) {
                // Leichter Jitter: ±1.5 pt in beide Richtungen
                let jx = (next() - 0.5) * 3.0
                let jy = (next() - 0.5) * 3.0
                let x = gx + jx
                let y = gy + jy
                let r = dotRadius * (0.7 + next() * 0.6)
                let a = dotAlpha * (0.6 + next() * 0.8)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(a)))
                gy += gridSize
            }
            gx += gridSize
        }

        // Vignette: ränder dunkler (Tolex-Gewölbeoptik)
        let vigAlpha = 0.18 * scale
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.40),
                    .init(color: Color.black.opacity(vigAlpha), location: 1.0)
                ]),
                center: .init(x: 0.5, y: 0.5),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.65
            )
        )
    }

    // MARK: Gebürstetes Aluminium (danish) — senkrechte Linien + horizontaler Sheen

    private func drawAluminiumTexture(context: GraphicsContext, size: CGSize, scale: Double) {
        // Sehr feine senkrechte Linien (gebürsterter Metall-Look).
        let lineSpacing: Double = 1.5
        let baseAlpha = 0.05 * scale

        var seed: UInt32 = 0xE5F6_A7B8
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }

        var x: Double = 0
        while x < Double(size.width) {
            let a = baseAlpha * (0.5 + next() * 1.0)  // leichte Variation
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Color.black.opacity(a)), lineWidth: 1)
            x += lineSpacing
        }

        // Horizontaler Sheen: helles Band in der Mitte (Lichtreflektion auf Metall).
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.00), location: 0.0),
                    .init(color: Color.white.opacity(0.07 * scale), location: 0.35),
                    .init(color: Color.white.opacity(0.04 * scale), location: 0.50),
                    .init(color: Color.white.opacity(0.00), location: 1.0)
                ]),
                startPoint: CGPoint(x: 0, y: size.height / 2),
                endPoint: CGPoint(x: size.width, y: size.height / 2)
            )
        )
    }

    // MARK: Cyber-Grid (midi) — Neon-Gitterlinien + Bokeh-Dots

    private func drawCyberGridTexture(context: GraphicsContext, size: CGSize, scale: Double,
                                       accent: Color, accent2: Color) {
        // Feines Neon-Gitter: waagrecht Magenta, senkrecht Cyan, sehr niedrige Alpha.
        let vSpacing: Double = 24.0
        let hSpacing: Double = Double(size.width) / 12.0
        let gridAlpha = 0.08 * scale

        // Waagrechte Gitterlinien (Magenta/accent)
        var y: Double = 0
        while y < Double(size.height) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(accent.opacity(gridAlpha)), lineWidth: 0.5)
            y += vSpacing
        }

        // Senkrechte Gitterlinien (Cyan/accent2)
        var x: Double = 0
        while x <= Double(size.width) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(accent2.opacity(gridAlpha)), lineWidth: 0.5)
            x += hSpacing
        }

        // 8 weiche Bokeh-Dots in den Ecken und Kantenmittel (deterministisch platziert).
        // Positionen als Bruchteil der Größe: (relX, relY, radius, farbe 0=accent/1=accent2)
        let bokehDefs: [(Double, Double, Double, Int)] = [
            (0.0, 0.0, 55, 0), (1.0, 0.0, 45, 1),
            (0.0, 1.0, 50, 1), (1.0, 1.0, 55, 0),
            (0.5, 0.0, 35, 0), (0.5, 1.0, 40, 1),
            (0.0, 0.5, 30, 1), (1.0, 0.5, 35, 0)
        ]
        let bokehAlpha = 0.07 * scale
        for (rx, ry, rad, which) in bokehDefs {
            let cx = rx * Double(size.width)
            let cy = ry * Double(size.height)
            let col = which == 0 ? accent : accent2
            context.fill(
                Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad,
                                       width: rad * 2, height: rad * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: col.opacity(bokehAlpha), location: 0.0),
                        .init(color: col.opacity(0.0), location: 1.0)
                    ]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: rad
                )
            )
        }
    }
}

// MARK: - SectionHeader

/// Stilisierter Spalten-/Abschnittstitel ("STATIONS", "HISTORY" …).
/// Respektiert theme.fonts.uppercaseHeaders und theme.fonts.tracking.
public struct SectionHeader: View {

    private let text: String
    @Environment(\.theme) private var theme

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let label = theme.fonts.uppercaseHeaders ? text.uppercased() : text
        // Spaltentitel nutzen den gut lesbaren label-Slot, NICHT den title-Slot:
        // sonst kaeme z.B. bei Marshall die Schreibschrift (cursive) — unleserlich.
        Text(label)
            .font(theme.font(.label, size: 11, weight: .semibold))
            .tracking(theme.fonts.tracking)
            .foregroundColor(theme.palette.textSecondary)
    }
}

// MARK: - LEDDot

/// Leuchtpunkt für Sender-Zeilen (neon-Themes leuchten, andere Themes zeigen nur die Farbe).
public struct LEDDot: View {

    private let on: Bool
    private let color: Color
    private let size: CGFloat
    @Environment(\.theme) private var theme

    public init(on: Bool, color: Color, size: CGFloat = 8) {
        self.on = on
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(on ? color : color.opacity(0.25))
            .frame(width: size, height: size)
            // Neon-Glow nur bei Themes mit entsprechendem Stil
            .neonGlow(color, radius: size * 0.8,
                      active: on && (theme.control == .neon || theme.control == .terminal))
    }
}

// MARK: - KnobView

/// Dekorativer Drehknopf (retro/stack). Zeigt `value` (0…1) als Zeigerposition.
/// Nicht interaktiv — rein dekorativ.
public struct KnobView: View {

    private let value: Double      // 0…1
    private let label: String
    private let tint: Color?
    private let diameter: CGFloat
    @Environment(\.theme) private var theme

    public init(value: Double, label: String, tint: Color? = nil, diameter: CGFloat = 44) {
        self.value = value
        self.label = label
        self.tint = tint
        self.diameter = diameter
    }

    public var body: some View {
        // Akzent-/Messington aus dem Theme (Gold bei stack/retro).
        let gold = tint ?? theme.palette.accent
        VStack(spacing: 2) {
            ZStack {
                // 1) Schlagschatten — hebt den Knopf von der Platte ab (3D-Auflage).
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: diameter, height: diameter)
                    .blur(radius: diameter * 0.07)
                    .offset(y: diameter * 0.07)

                // 2) Gold-Bezel: Conic-(Angular-)Gradient simuliert die umlaufenden Licht-
                //    kanten eines gedrehten Messingrings (Vorbild: Verstärker-Potiknopf).
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                gold.opacity(0.45), gold, .white.opacity(0.85),
                                gold, gold.opacity(0.4), gold, gold.opacity(0.45)
                            ]),
                            center: .center, angle: .degrees(-90)
                        )
                    )
                    .frame(width: diameter, height: diameter)

                // 3) Dunkler, gewölbter Knopfkörper — Radial-Gradient mit Lichtquelle oben-
                //    links erzeugt den Dome-Eindruck; oben ein feiner Glanzrand.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#3C3A37"), Color(hex: "#1A1814"), Color(hex: "#050505")],
                            center: UnitPoint(x: 0.38, y: 0.30),
                            startRadius: 0, endRadius: diameter * 0.5
                        )
                    )
                    .frame(width: diameter * 0.76, height: diameter * 0.76)
                    .overlay(
                        Circle().stroke(
                            LinearGradient(colors: [.white.opacity(0.30), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: max(0.6, diameter * 0.025))
                            .frame(width: diameter * 0.76, height: diameter * 0.76)
                    )

                // 4) Glanzlicht oben-links auf der Wölbung.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.35), .clear],
                                         center: .center, startRadius: 0, endRadius: diameter * 0.17))
                    .frame(width: diameter * 0.32, height: diameter * 0.32)
                    .offset(x: -diameter * 0.13, y: -diameter * 0.15)

                // 5) Gold-Skalenstriche am Rand (wie die 0…10-Skala am Amp-Poti).
                KnobTicks(count: 11, diameter: diameter)
                    .stroke(gold.opacity(0.85), lineWidth: max(0.7, diameter * 0.022))

                // 6) Zeiger-Kerbe: heller Gold-Strich von innen zum Rand zeigt den Wert.
                KnobPointer(value: value, diameter: diameter)
                    .stroke(
                        LinearGradient(colors: [gold, .white], startPoint: .center, endPoint: .top),
                        style: StrokeStyle(lineWidth: max(1.5, diameter * 0.07), lineCap: .round)
                    )
            }
            .frame(width: diameter, height: diameter)

            // Label unter dem Knopf
            Text(label.uppercased())
                .font(theme.font(.label, size: 8, weight: .semibold))
                .tracking(theme.fonts.tracking)
                .foregroundColor(theme.palette.textSecondary)
        }
    }
}

/// Skalenstriche rund um den Knopf (gleicher Winkelbereich wie der Zeiger: 135°…405°).
private struct KnobTicks: Shape {
    let count: Int
    let diameter: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rOut = (diameter / 2) * 0.98
        let rIn  = (diameter / 2) * 0.84
        let startAngle = 135.0, range = 270.0
        var path = Path()
        for i in 0..<count {
            let frac = count > 1 ? Double(i) / Double(count - 1) : 0
            let a = Angle(degrees: startAngle + frac * range).radians
            path.move(to: CGPoint(x: cx + cos(a) * rIn,  y: cy + sin(a) * rIn))
            path.addLine(to: CGPoint(x: cx + cos(a) * rOut, y: cy + sin(a) * rOut))
        }
        return path
    }
}

/// Zeiger-Form für den Knopf. Zeichnet eine Linie vom Mittelpunkt zum Rand.
private struct KnobPointer: Shape {
    let value: Double     // 0…1
    let diameter: CGFloat

    func path(in rect: CGRect) -> Path {
        // Bereich: von 7-Uhr-Position bis 5-Uhr-Position (270° Gesamtbereich)
        let startAngle = 135.0  // Grad, im Uhrzeigersinn von rechts
        let range = 270.0
        let angle = Angle(degrees: startAngle + value * range)

        let cx = rect.midX
        let cy = rect.midY
        // Kerbe NICHT durch die Mitte, sondern als Strich auf der Wölbung (innen→Rand).
        let rIn  = (diameter / 2) * 0.30
        let rOut = (diameter / 2) * 0.80
        let ca = cos(angle.radians), sa = sin(angle.radians)

        var path = Path()
        path.move(to: CGPoint(x: cx + ca * rIn,  y: cy + sa * rIn))
        path.addLine(to: CGPoint(x: cx + ca * rOut, y: cy + sa * rOut))
        return path
    }
}

// MARK: - VisualizerView

/// Bühnen-Visualizer. Wählt je nach `theme.visualizer` den passenden Stil.
/// Animiert via TimelineView(.animation). Wenn `!isPlaying` → ruhig/flach/gedimmt.
public struct VisualizerView: View {

    private let isPlaying: Bool
    @Environment(\.theme) private var theme
    // Audio-Reaktivität: Pegel/Bänder der eigenen Ausgabe. Die Sub-Visualizer lesen sie pro
    // Frame in ihrer TimelineView (deshalb wird der Tap selbst durchgereicht, kein Snapshot).
    @EnvironmentObject private var audioTap: AudioTap

    public init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    public var body: some View {
        // Entsprechenden Visualizer je nach Theme-Konfiguration rendern
        switch theme.visualizer {
        case .none:
            Color.clear

        case .waveform:
            WaveformVisualizer(
                isPlaying: isPlaying,
                color1: theme.palette.visualizer1,
                color2: theme.palette.visualizer2,
                isFanzine: theme.control == .stamp,  // Fanzine: gezackte Tinte, kein Glow
                audioTap: audioTap
            )

        case .vu:
            // retro und stack teilen die VU-Mechanik, sehen aber unterschiedlich aus:
            // retro = cremefarbenes Vintage-Zifferblatt mit dunkler Nadel; stack = dunkles
            // Zifferblatt mit Goldnadel (Daniel: „nicht bei beiden gleich aussehen").
            let isRetro = theme.id == .retro
            VUMeterVisualizer(
                isPlaying: isPlaying,
                needleColor: isRetro ? Color(hex: "#7A2E12") : theme.palette.accent,
                faceColor: isRetro ? Color(hex: "#F2E8CE") : theme.palette.stageBackground,
                textColor: isRetro ? Color(hex: "#5C4A2E") : theme.palette.textSecondary,
                bezelStyle: isRetro ? .brushedSteel : .polishedGold,
                audioTap: audioTap
            )

        case .fabric:
            FabricVisualizer(
                isPlaying: isPlaying,
                accentTexture: theme.accentTexture,
                fallbackColor: theme.palette.accent.opacity(0.6)
            )

        case .midiNotes:
            MidiNotesVisualizer(
                isPlaying: isPlaying,
                color1: theme.palette.visualizer1,
                color2: theme.palette.visualizer2,
                gridColor: theme.palette.textDim.opacity(0.3),
                audioTap: audioTap
            )

        case .bars:
            BarsVisualizer(
                isPlaying: isPlaying,
                color1: theme.palette.visualizer1,
                color2: theme.palette.visualizer2,
                audioTap: audioTap
            )
        }
    }
}

// MARK: - WaveformVisualizer

/// Echtes Oszilloskop: zeichnet die gemessene Mono-Wellenform (`audioTap.waveform`,
/// −1…1) zentriert als Kurve — wie ein Winamp-Scope / Hi-Fi-Sichtgerät.
/// Acid-Modus: Neon-Glow (Gradient visualizer1→visualizer2).
/// Fanzine-Modus (.stamp): gezackte schwarze Tinte, quantisiert, kein Glow.
/// Kein echtes Signal (`!reactive`): ruhige Idle-Linie statt totem Strich.
private struct WaveformVisualizer: View {

    let isPlaying: Bool
    let color1: Color
    let color2: Color
    let isFanzine: Bool
    let audioTap: AudioTap

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Echtes Audio anliegen → gemessene Kurve; sonst sanfte Idle-Welle.
            let reactive = audioTap.reactive && isPlaying
            let samples = reactive ? audioTap.waveform : idleWave(t: t)
            GeometryReader { geo in
                ZStack {
                    // Null-Achse (Mittellinie) des Oszilloskops
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(color1.opacity(0.12), lineWidth: 1)

                    scopeTrace(samples: samples, size: geo.size)

                    // dezentes Label (links unten)
                    VStack {
                        Spacer()
                        HStack {
                            Text(isFanzine ? "OSC" : "SCOPE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(color1.opacity(0.45))
                            Spacer()
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    /// Die Scope-Kurve — weich+Glow (Acid) oder gezackte Tinte (Fanzine).
    @ViewBuilder
    private func scopeTrace(samples: [Float], size: CGSize) -> some View {
        let amp = size.height * 0.42
        if isFanzine {
            ScopeShape(samples: samples, amplitude: amp, jagged: true)
                .stroke(color1, style: StrokeStyle(lineWidth: 2, lineJoin: .miter))
        } else {
            let grad = LinearGradient(colors: [color1, color2],
                                      startPoint: .leading, endPoint: .trailing)
            ScopeShape(samples: samples, amplitude: amp, jagged: false)
                .stroke(grad, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .overlay(
                    ScopeShape(samples: samples, amplitude: amp, jagged: false)
                        .stroke(color1.opacity(0.25), lineWidth: 7)
                        .blur(radius: 5)
                )
        }
    }

    /// Ruhige, leicht atmende Linie, wenn kein echtes Signal anliegt.
    private func idleWave(t: Double) -> [Float] {
        let n = 120
        return (0..<n).map { i in
            let phase = Double(i) / Double(n) * .pi * 2
            return Float(sin(phase * 2 + t * 1.2) * 0.05)
        }
    }
}

/// Oszilloskop-Kurve aus rohen Wellenform-Samples (−1…1). Zeichnet sie zentriert
/// über die Breite. `jagged` = Fanzine: weniger Stützpunkte + quantisiert → eckige Tinte.
private struct ScopeShape: Shape {

    var samples: [Float]
    var amplitude: CGFloat
    var jagged: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = samples.count
        guard n > 1 else { return path }
        let midY = rect.midY
        // Rohe PCM-Samples sind meist leiser als ±1 → moderater Boost, dann clampen,
        // damit das Scope sichtbar ausschlägt, ohne über den Rahmen zu schießen.
        let boost: CGFloat = 2.4
        // Fanzine zeichnet gröber (eckiger); Acid nimmt jeden Punkt (glatte Kurve).
        let step = jagged ? max(1, n / 90) : 1
        var i = 0
        var first = true
        while i < n {
            let x = CGFloat(i) / CGFloat(n - 1) * rect.width
            var v = CGFloat(samples[i]) * boost
            v = max(-1, min(1, v))
            if jagged { v = (v * 4).rounded() / 4 }   // quantisieren → Tinte-Sprünge
            let pt = CGPoint(x: x, y: midY - v * amplitude)
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            i += step
        }
        return path
    }
}

// MARK: - VUMeterVisualizer

/// Material der einzelnen VU-Meter-Einfassung.
private enum VUMeterBezelStyle {
    case brushedSteel
    case polishedGold
}

/// Analoges VU-Nadel-Meter (ein oder zwei Gauge-Halbkreise mit Skala und Nadel).
/// Wenn isPlaying: Nadel schlägt aus. Wenn pausiert: Nadel ruht links.
private struct VUMeterVisualizer: View {

    let isPlaying: Bool
    let needleColor: Color
    let faceColor: Color
    let textColor: Color
    let bezelStyle: VUMeterBezelStyle
    let audioTap: AudioTap

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                // L/R-Orientierung nach Zellen-Aspekt: Ein VU-Bogen ist LANDSCAPE (breiter als
                // hoch). Nebeneinander halbiert die Breite → schmale Hochkant-Zellen → Bogen
                // überdimensioniert + am Stage-Rand abgeschnitten (Retro-Bug). Darum stapeln,
                // solange der Stage nicht deutlich breiter als hoch ist; nur bei sehr breitem
                // Stage nebeneinander.
                let stacked = geo.size.width < geo.size.height * 1.8
                let lr = [0, 1]
                let pad = min(geo.size.width, geo.size.height) * 0.04
                Group {
                    if stacked {
                        VStack(spacing: 8) {
                            ForEach(lr, id: \.self) { ch in meter(ch, t: t) }
                        }
                    } else {
                        HStack(spacing: 14) {
                            ForEach(lr, id: \.self) { ch in meter(ch, t: t) }
                        }
                    }
                }
                .padding(pad)
            }
        }
    }

    private func meter(_ channel: Int, t: Double) -> some View {
        SingleVUMeter(
            t: t, channel: channel, isPlaying: isPlaying,
            needleColor: needleColor, faceColor: faceColor, textColor: textColor,
            bezelStyle: bezelStyle,
            audioTap: audioTap
        )
    }
}

/// Hält den geglätteten Nadel-Stand zwischen den Frames (Referenztyp, via `@State` persistiert).
/// Wird im `body` fortgeschrieben — das invalidiert die View NICHT (Klassen-Mutation), die
/// laufende `TimelineView(.animation)` zeichnet ohnehin jeden Frame neu.
private final class NeedleBallistics {
    var value: Double = 0.0     // aktueller Nadelausschlag 0…1
    var lastT: Double = 0       // Zeitstempel des letzten Frames (für dt)
}

/// Glättet ein ganzes Werte-Array (z.B. Spektrum-Bänder) frame-raten-unabhängig pro Frame.
/// Grund: Der Audio-Callback liefert neue Bänder schubweise (nicht 60×/s) — ohne Interpolation
/// „springen" Balken/Visualizer und wirken laggy. Attack schnell (geringer Lag), Release langsamer.
private final class ArraySmoother {
    var values: [CGFloat] = []
    var lastT: Double = 0
    func step(toward target: [Float], t: Double, attack: Double, release: Double) -> [CGFloat] {
        if values.count != target.count {           // erste Runde / Größenwechsel → direkt setzen
            values = target.map { CGFloat($0) }; lastT = t; return values
        }
        // dt auf [0, 0.1] clampen: springt `t` zurück (Pause→Play, Theme-Wechsel, TimelineView-
        // Reset), wäre t−lastT negativ → die exp-Glättung liefe RÜCKWÄRTS und der Visualizer
        // bliebe am Anschlag hängen ("Vollausschlag, kein Ton"). max(0,…) verhindert das.
        let dt = lastT == 0 ? (1.0 / 60.0) : max(0, min(0.1, t - lastT))
        lastT = t
        for i in values.indices {
            let tgt = CGFloat(target[i])
            let rate = tgt > values[i] ? attack : release
            values[i] += (tgt - values[i]) * CGFloat(1 - exp(-rate * dt))
        }
        return values
    }
}

/// Ein einzelnes VU-Meter: Halbkreis-Skala + Nadel.
private struct SingleVUMeter: View {

    let t: Double
    let channel: Int    // 0=L, 1=R
    let isPlaying: Bool
    let needleColor: Color
    let faceColor: Color
    let textColor: Color
    let bezelStyle: VUMeterBezelStyle
    let audioTap: AudioTap

    @State private var ball = NeedleBallistics()

    /// Ziel-Pegel der Nadel (0…1). NUR bei echtem Signal der gemessene Pegel; sonst Ruhe (0) —
    /// kein künstliches Zeitprogramm mehr (Daniel: lieber warten bis echte Pegel da sind, als
    /// Fake-Bewegung zeigen, etwa während der Analyse-Player nach Senderwechsel erst anläuft).
    private var targetLevel: Double {
        guard isPlaying, audioTap.reactive else { return 0.0 }
        let chBias = channel == 0 ? 0.0 : -0.03    // R minimal niedriger fürs analoge Gefühl
        return min(1, max(0, Double(audioTap.level) + chBias))
    }

    /// Schreibt die Ballistik frame-raten-unabhängig fort und gibt den anzuzeigenden Wert zurück.
    /// Attack (hoch) schnell, Release (runter) langsamer — aber IMMER sofort sinkend (kein Halten),
    /// nur die Sink-GESCHWINDIGKEIT ist geringer als die maximale Steig-Geschwindigkeit.
    private func advanceNeedle() -> Double {
        let dt = ball.lastT == 0 ? (1.0 / 60.0) : max(0, min(0.1, t - ball.lastT))   // ≥0: kein Rückwärts-Hängen
        ball.lastT = t
        let target = targetLevel
        // Raten pro Sekunde; exponentielle Annäherung → butterweich bei 60 fps. Attack schnell
        // (geringer Relativ-Lag zum Ton), Release deutlich langsamer (analoges VU-Nachschwingen).
        let rate = target > ball.value ? 38.0 : 8.0
        ball.value += (target - ball.value) * (1 - exp(-rate * dt))
        return ball.value
    }

    var body: some View {
        let level = advanceNeedle()
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Der 120°-Bogen (210°→330°) öffnet nach oben. Seine Bounding-Box ist ca.
            // 1.732·r breit und r hoch. Radius so wählen, dass die Box mit etwas Rand IN die
            // Zelle passt — in Breite UND Höhe. Vorher war der Radius nur breitenbezogen und
            // der Mittelpunkt fix bei 0.92·h → in schmalen/hohen Zellen ragte der Zeiger über
            // den Stage-Rand (Retro-Bug „Nadeln links raus").
            let m = min(w, h) * 0.06                              // kleiner Innenrand
            let radius = max(8, min((w - 2 * m) / 1.732, h - 2 * m))
            let cx = w / 2
            // Bogen-Band [cy−r, cy] vertikal in der Zelle zentrieren → cy = h/2 + r/2.
            let cy = h / 2 + radius / 2
            let bezelRadius = radius * 1.10
            let bezelGradient = LinearGradient(
                colors: bezelStyle == .brushedSteel
                    ? [Color(hex: "#E1D6BE"), Color(hex: "#8B7B5D"), Color(hex: "#30281B")]
                    : [Color(hex: "#F6D878"), Color(hex: "#C79B38"), Color(hex: "#6F4D12")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            let innerShadow = bezelStyle == .brushedSteel
                ? Color(hex: "#241B12").opacity(0.35)
                : Color.black.opacity(0.46)

            ZStack {
                // 1) Eigenes Gehaeuse pro Meter: kein grosser gemeinsamer Kasten mehr.
                GaugeArc(cx: cx, cy: cy, radius: bezelRadius)
                    .fill(bezelGradient)
                    .shadow(color: .black.opacity(0.50), radius: 7, y: 3)

                // 2) Dunkle Einlass-Fase zwischen Metall und Skalenblatt.
                GaugeArc(cx: cx, cy: cy, radius: radius * 1.04)
                    .fill(innerShadow)

                // 3) Skalenblatt.
                GaugeArc(cx: cx, cy: cy, radius: radius)
                    .fill(faceColor.opacity(0.85))
                    .shadow(color: .white.opacity(bezelStyle == .brushedSteel ? 0.18 : 0.05),
                            radius: 2, x: -1, y: -1)
                    .shadow(color: .black.opacity(0.22), radius: 2, x: 1, y: 1)

                // Skalierungs-Striche
                GaugeTicks(cx: cx, cy: cy, radius: radius, count: 11)
                    .stroke(textColor.opacity(0.6), lineWidth: 1)

                // Farbiger Bereich rechts (hohe Pegel = rot-orange)
                GaugeArcSegment(cx: cx, cy: cy, radius: radius,
                                fromFraction: 0.8, toFraction: 1.0)
                    .fill(Color.red.opacity(0.35))

                // Nadel — Bewegung kommt aus der frame-weisen Ballistik (advanceNeedle),
                // daher KEIN SwiftUI-`.animation` (das fing sich mit dem 60-fps-Redraw der
                // TimelineView und wirkte gummiartig/ruckelig).
                NeedleShape(cx: cx, cy: cy, radius: radius * 0.85, fraction: level)
                    .stroke(needleColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, x: 1, y: 1)

                // Kleine Achskappe macht den Zeiger analoger und verdeckt den Ursprung.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [needleColor.opacity(0.95), Color.black.opacity(0.55)],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: max(4, radius * 0.055)
                        )
                    )
                    .frame(width: max(7, radius * 0.075), height: max(7, radius * 0.075))
                    .position(x: cx, y: cy)

                // Kanal-Label
                Text(channel == 0 ? "L" : "R")
                    .font(.system(size: radius * 0.22, weight: .bold, design: .serif))
                    .foregroundColor(textColor.opacity(0.7))
                    .position(x: cx, y: cy - radius * 0.38)
            }
            .clipped()   // Sicherheitsnetz: nie über die Zellgrenze hinaus zeichnen
        }
    }
}

/// Halbkreisbogen für den Gauge-Hintergrund.
private struct GaugeArc: Shape {
    let cx, cy, radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Linker Anschlag bei 210°, rechter bei 330° (Uhrzeiger-Koordinaten)
        var path = Path()
        path.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                    startAngle: .degrees(210), endAngle: .degrees(330),
                    clockwise: false)
        path.addLine(to: CGPoint(x: cx, y: cy))
        path.closeSubpath()
        return path
    }
}

/// Hervorgehobenes Bogensegment (für den roten VU-Überlastbereich).
private struct GaugeArcSegment: Shape {
    let cx, cy, radius: CGFloat
    let fromFraction: Double  // 0…1 auf der Gauge-Skala
    let toFraction: Double

    func path(in rect: CGRect) -> Path {
        // Gauge-Bereich: 210° → 330° = 120° gesamt
        let startDeg = 210.0 + fromFraction * 120.0
        let endDeg = 210.0 + toFraction * 120.0
        var path = Path()
        path.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                    startAngle: .degrees(startDeg), endAngle: .degrees(endDeg),
                    clockwise: false)
        path.addArc(center: CGPoint(x: cx, y: cy), radius: radius * 0.7,
                    startAngle: .degrees(endDeg), endAngle: .degrees(startDeg),
                    clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Skalen-Striche am Gauge-Bogen.
private struct GaugeTicks: Shape {
    let cx, cy, radius: CGFloat
    let count: Int  // Anzahl der Striche

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...count {
            let fraction = Double(i) / Double(count)
            let angle = Angle(degrees: 210.0 + fraction * 120.0)
            let inner = radius * 0.82
            let outer = radius * (i == 0 || i == count || i == count * 8 / 10 ? 1.0 : 0.92)
            let cos_ = CGFloat(cos(angle.radians))
            let sin_ = CGFloat(sin(angle.radians))
            path.move(to: CGPoint(x: cx + cos_ * inner, y: cy + sin_ * inner))
            path.addLine(to: CGPoint(x: cx + cos_ * outer, y: cy + sin_ * outer))
        }
        return path
    }
}

/// Zeiger-Linie der VU-Nadel.
private struct NeedleShape: Shape {
    let cx, cy, radius: CGFloat
    let fraction: Double  // 0…1 auf der Skala

    func path(in rect: CGRect) -> Path {
        let angle = Angle(degrees: 210.0 + fraction * 120.0)
        let dx = CGFloat(cos(angle.radians)) * radius
        let dy = CGFloat(sin(angle.radians)) * radius
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
        return path
    }
}

// MARK: - FabricVisualizer

/// Runde, stoffbespannte Lautsprecherscheibe mit dezenter Atem-Animation.
private struct FabricVisualizer: View {

    let isPlaying: Bool
    let accentTexture: String?
    let fallbackColor: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            // Pulsieren: sehr langsam, subtil
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = isPlaying
                ? 1.0 + CGFloat(sin(t * 1.2)) * 0.025
                : 1.0

            GeometryReader { geo in
                let diameter = min(geo.size.width, geo.size.height) * 0.85
                ZStack {
                    // Äußerer Rahmen (Lautsprecherrahmen)
                    Circle()
                        .strokeBorder(fallbackColor.opacity(0.4), lineWidth: 3)
                        .frame(width: diameter, height: diameter)

                    // Stoff-Füllung: Textur oder generiertes Webmuster
                    FabricDiscContent(
                        accentTexture: accentTexture,
                        fallbackColor: fallbackColor,
                        diameter: diameter * 0.92
                    )
                    .scaleEffect(pulse)
                    .animation(.easeInOut(duration: 0.8), value: pulse)

                    // Zentrale Staubkappe (kleiner Kreis in der Mitte)
                    Circle()
                        .fill(fallbackColor.opacity(0.5))
                        .frame(width: diameter * 0.14, height: diameter * 0.14)
                    Circle()
                        .strokeBorder(fallbackColor.opacity(0.3), lineWidth: 1)
                        .frame(width: diameter * 0.14, height: diameter * 0.14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Innere Stoff-Füllung der Lautsprecherscheibe.
private struct FabricDiscContent: View {
    let accentTexture: String?
    let fallbackColor: Color
    let diameter: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        if let img = theme.image(accentTexture) {
            // Echte Stoff-Textur wenn vorhanden
            img.resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            // Generiertes Webmuster als Fallback
            WovenPattern(color: fallbackColor)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        }
    }
}

/// Einfaches radialen Webmuster für den Stoff-Fallback.
private struct WovenPattern: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 6
            let lineW: CGFloat = 1.5

            // Waagrechte Fäden
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color.opacity(0.35)), lineWidth: lineW)
                y += spacing
            }

            // Senkrechte Fäden
            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: lineW)
                x += spacing
            }

            // Radialer Verlauf darüber (Tiefenwirkung)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.0), color.opacity(0.3)]),
                    center: .init(x: 0.5, y: 0.5),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }
}

// MARK: - MidiNotesVisualizer

/// RGB-Komponenten 0…1 (für Farb-Interpolation im Spektrogramm).
private typealias RGB = (r: Double, g: Double, b: Double)

/// Scrollende Energie-Historie für das Black-MIDI-Spektrogramm. Referenztyp (via `@State`
/// persistiert), wird im `body` fortgeschrieben — invalidiert die View NICHT.
private final class SpectrogramBuffer {
    var rows: [[CGFloat]] = []      // [0] = neueste Zeile (oben)
    var lastT: Double = 0
    func push(_ vals: [CGFloat], t: Double, maxRows: Int, interval: Double) {
        if lastT != 0, t < lastT { lastT = t; return }        // Zeit-Reset → nur Marke nachziehen
        if lastT == 0 || t - lastT >= interval {
            rows.insert(vals, at: 0)
            if rows.count > maxRows { rows.removeLast(rows.count - maxRows) }
            lastT = t
        }
    }
}

/// Fallende Neon-Noten: kleine gerundete Rechtecke regnen in Palette-Farben
/// über einem feinen Raster herunter. Deterministische Pseudo-Zufallspositionen.
/// „Black MIDI"-Piano-Roll: dichte, neonfarbene Notensäulen fallen über ein Raster nach unten
/// auf eine leuchtende Trefferlinie zu (Anlehnung an Black-MIDI-Videos = Noten-Wände).
/// Alles in EINEM Canvas gezeichnet (deterministisch, kein random) — deutlich dichter UND
/// günstiger als die frühere Version mit 64 einzelnen geblurrten SwiftUI-Views.
private struct MidiNotesVisualizer: View {

    let isPlaying: Bool
    let color1: Color
    let color2: Color
    let gridColor: Color
    let audioTap: AudioTap

    private let barLanes = 24       // Frequenz-Bänder: oben Spektrogramm-Spuren UND unten Balken
    private let spectroRows = 140   // Höhe der scrollenden Spektrogramm-Historie (Zeilen)

    @State private var barSmoother = ArraySmoother()    // geglättete Band-Höhen (oben+unten)
    @State private var spectro = SpectrogramBuffer()    // scrollende Energie-Historie je Band

    var body: some View {
        TimelineView(.animation) { context in
            let t = isPlaying ? context.date.timeIntervalSinceReferenceDate : 0
            let active = audioTap.reactive
            let bands = audioTap.bands

            // Eine Energie pro Frequenz-Band (echtes Spektrum, sonst 0), geglättet. Dieselben
            // Werte speisen OBEN das Spektrogramm UND UNTEN die Balken → wo unten Ausschlag ist,
            // entsteht oben eine Linie; wo 0 ist, bleibt es leer.
            let barTargets: [Float] = (active && !bands.isEmpty)
                ? (0..<barLanes).map { min(1, max(0, bands[min(bands.count - 1, $0 * bands.count / barLanes)])) }
                : [Float](repeating: 0, count: barLanes)
            let barVals = barSmoother.step(toward: barTargets, t: t, attack: 38, release: 12)

            VStack(spacing: 0) {
                Canvas { ctx, size in
                    // Scrollende Historie hier fortschreiben (Canvas-Closure ist kein ViewBuilder):
                    // neue Zeile oben, ältere wandern nach unten weg.
                    if isPlaying { spectro.push(barVals, t: t, maxRows: spectroRows, interval: 0.05) }
                    drawSpectro(ctx, size, rows: spectro.rows)
                }
                    .frame(maxHeight: .infinity)        // großes scrollendes Spektrogramm
                Spacer(minLength: 6)
                Canvas { ctx, size in drawBars(ctx, size, vals: barVals) }
                    .frame(height: 34)                  // schmaler Spektrum-Streifen unten
            }
        }
    }

    /// Scrollendes Spektrogramm: je Band (Spalte) eine Historie farbiger Zellen. Energie 0 →
    /// LÜCKE (keine Linie); sonst Farbe nach Energie-HÖHE (niedrig=color2 → mittel=color1 → hoch=weiß).
    /// Ändert sich die Energie, ändert sich die Zellenfarbe → die „Linie" wirkt segmentiert/dynamisch.
    /// Keine horizontale Trefferlinie (auf Wunsch entfernt).
    private func drawSpectro(_ ctx: GraphicsContext, _ size: CGSize, rows: [[CGFloat]]) {
        drawGrid(ctx, size)
        guard !rows.isEmpty else { return }
        let laneW = size.width / CGFloat(barLanes)
        let rowH = size.height / CGFloat(spectroRows)
        let c2 = rgb(color2), c1 = rgb(color1)          // Endpunkte einmal in RGB (teuer pro Zelle)
        let shown = min(rows.count, spectroRows)
        for r in 0..<shown {
            let row = rows[r]
            let y = CGFloat(r) * rowH                    // r=0 oben (neueste), scrollt nach unten
            for l in 0..<min(barLanes, row.count) {
                let e = Double(row[l])
                if e < 0.05 { continue }                 // 0-Ausschlag → keine Linie (Lücke)
                let col = energyColor(e, low: c2, mid: c1)
                let x = CGFloat(l) * laneW + laneW * 0.18
                let rect = CGRect(x: x, y: y, width: laneW * 0.64, height: max(1, rowH - 0.5))
                ctx.fill(Path(rect), with: .color(col.opacity(0.92)))
            }
        }
    }

    /// Energie-Höhe → Farbe: 0…0.5 von `low` (cyan) nach `mid` (magenta), 0.5…1 von `mid` nach weiß.
    private func energyColor(_ e: Double, low: RGB, mid: RGB) -> Color {
        if e < 0.5 {
            let f = e / 0.5
            return Color(red: low.r + (mid.r - low.r) * f,
                         green: low.g + (mid.g - low.g) * f,
                         blue: low.b + (mid.b - low.b) * f)
        } else {
            let f = (e - 0.5) / 0.5
            return Color(red: mid.r + (1 - mid.r) * f,
                         green: mid.g + (1 - mid.g) * f,
                         blue: mid.b + (1 - mid.b) * f)
        }
    }

    /// SwiftUI-Color → sRGB-Komponenten (für die Farb-Interpolation).
    private func rgb(_ c: Color) -> RGB {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return RGB(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
    }

    /// Unterer Balken-Streifen — echtes Spektrum (FFT-Bänder), bereits frame-weise geglättet
    /// (`vals`), wächst von unten nach oben. Kein Signal → flache Sockel (kein Fake-Programm).
    private func drawBars(_ ctx: GraphicsContext, _ size: CGSize, vals: [CGFloat]) {
        let n = barLanes
        let slot = size.width / CGFloat(n)
        let bw = slot * 0.6
        for i in 0..<n {
            let frac = i < vals.count ? max(0.04, min(1, vals[i])) : 0.04
            let h = size.height * frac
            let x = CGFloat(i) * slot + (slot - bw) / 2
            let rect = CGRect(x: x, y: size.height - h, width: bw, height: h)
            let grad = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [color2, color1]),
                startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                endPoint: CGPoint(x: rect.midX, y: rect.minY))
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: grad)
        }
    }

    /// Feines Cyber-Raster (Spurlinien senkrecht + Takte waagrecht) direkt im Canvas.
    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let hSpacing = size.width / CGFloat(barLanes)
        var x: CGFloat = 0
        while x <= size.width {
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            x += hSpacing
        }
        var y: CGFloat = 0
        while y < size.height {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            y += 28
        }
    }
}

// MARK: - BarsVisualizer

/// Equalizer-Balken aus dem ECHTEN Spektrum (FFT-Bänder), pro Frame geglättet → butterweich.
/// Kein Signal → Ruhe (flache Sockel), kein Fake-Zeitprogramm (Daniel: lieber warten).
private struct BarsVisualizer: View {

    let isPlaying: Bool
    let color1: Color
    let color2: Color
    let audioTap: AudioTap

    private let barCount = 18
    @State private var smoother = ArraySmoother()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Echte Bänder als Ziel; ArraySmoother interpoliert frame-weise (gegen Ruckeln).
            let eased = smoother.step(toward: targetBars(), t: t, attack: 38, release: 12)
            GeometryReader { geo in
                let barSpacing = geo.size.width / CGFloat(barCount)
                let barWidth = barSpacing * 0.65
                // Symmetrischer Equalizer: Balken wachsen von der Mitte nach oben UND unten.
                let maxH = geo.size.height * 0.92

                HStack(alignment: .center, spacing: barSpacing * 0.35) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let frac = i < eased.count ? eased[i] : 0.03
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [color2, color1, color2],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: barWidth, height: max(2, frac * maxH))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// Ziel-Höhe (0…1) je Balken: echtes Spektrum bei Signal, sonst Ruhe.
    private func targetBars() -> [Float] {
        guard isPlaying, audioTap.reactive else { return [Float](repeating: 0.03, count: barCount) }
        let bands = audioTap.bands
        guard !bands.isEmpty else { return [Float](repeating: 0.03, count: barCount) }
        return (0..<barCount).map { i in
            min(1, max(0.03, bands[min(bands.count - 1, i * bands.count / barCount)]))
        }
    }
}

// MARK: - neonGlow (View Extension)

extension View {
    /// Fügt einen Neon-Glow-Effekt via mehrfachen farbigen Schatten hinzu.
    /// `active: false` → keine Wirkung (z.B. für nicht-Neon-Themes).
    public func neonGlow(_ color: Color, radius: CGFloat = 6, active: Bool = true) -> some View {
        self.modifier(NeonGlowModifier(color: color, radius: radius, active: active))
    }
}

/// ViewModifier für den Neon-Glow-Effekt.
private struct NeonGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                // Mehrere überlagerte Schatten erzeugen den weichen Glow
                .shadow(color: color.opacity(0.9), radius: radius * 0.4)
                .shadow(color: color.opacity(0.6), radius: radius)
                .shadow(color: color.opacity(0.3), radius: radius * 2.0)
        } else {
            content
        }
    }
}

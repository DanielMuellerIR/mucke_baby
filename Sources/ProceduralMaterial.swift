import SwiftUI

/// Prozeduraler Materialeindruck als leichtes Canvas-Overlay über der Palette-Grundfarbe.
/// Alle Muster sind deterministisch (kein `Date`/`random`) und CPU-schonend (< 300 Primitive).
/// Alpha-Zielwert: 0.04–0.12 — Palette-Farbe dominiert immer.
struct ProceduralMaterial: View {

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
        // `<` statt `<=`: bei Breite 0 ist hSpacing 0 -> `<=` liefe (x += 0) endlos
        // auf dem Main-Thread (Canvas zeichnet dort). `<` ueberspringt den Fall.
        var x: Double = 0
        while x < Double(size.width) {
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

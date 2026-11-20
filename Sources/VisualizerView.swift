import SwiftUI

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
            // Zifferblatt mit Goldnadel (bewusst unterschiedliche Gestaltung).
            let isRetro = theme.id == .retro
            VUMeterVisualizer(
                isPlaying: isPlaying,
                needleColor: isRetro ? Color(hex: "#7A2E12") : theme.palette.accent,
                faceColor: isRetro ? Color(hex: "#F2E8CE") : theme.palette.stageBackground,
                textColor: isRetro ? Color(hex: "#5C4A2E") : theme.palette.textSecondary,
                bezelStyle: isRetro ? .brushedSteel : .polishedGold,
                audioTap: audioTap
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
/// Kein echtes Signal (`!reactive`): flache Mittellinie ohne erfundenen Ausschlag.
private struct WaveformVisualizer: View {

    let isPlaying: Bool
    let color1: Color
    let color2: Color
    let isFanzine: Bool
    let audioTap: AudioTap

    var body: some View {
        VisualizerTimeline(isPlaying: isPlaying) { date in
            // Ohne Signal bleibt die Kurve flach, auch bei laufender Wiedergabe.
            let reactive = audioTap.reactive && isPlaying
            let samples = reactive ? audioTap.waveform : [Float](repeating: 0, count: 120)
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
            if first {
                path.move(to: pt)
                first = false
            } else {
                path.addLine(to: pt)
            }
            i += step
        }
        return path
    }
}

/// Glättet Spektrum-Bänder unabhängig von der Bildrate.
/// Der Audio-Callback liefert neue Bänder schubweise (nicht 60×/s) — ohne Interpolation
/// „springen" Balken/Visualizer und wirken laggy. Attack schnell (geringer Lag), Release langsamer.
private final class ArraySmoother {
    var values: [CGFloat] = []
    var lastT: Double = 0
    func step(toward target: [Float], t: Double, attack: Double, release: Double) -> [CGFloat] {
        if values.count != target.count {           // erste Runde / Größenwechsel → direkt setzen
            values = target.map { CGFloat($0) }
            lastT = t
            return values
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

// MARK: - MidiNotesVisualizer

/// RGB-Komponenten 0…1 (für Farb-Interpolation im Spektrogramm).
private typealias RGB = (r: Double, g: Double, b: Double)

/// Scrollende Energie-Historie für das Black-MIDI-Spektrogramm. Referenztyp (via `@State`
/// persistiert), wird im `body` fortgeschrieben — invalidiert die View NICHT.
private final class SpectrogramBuffer {
    var rows: [[CGFloat]] = []      // [0] = neueste Zeile (oben)
    var lastT: Double = 0
    func push(_ vals: [CGFloat], t: Double, maxRows: Int, interval: Double) {
        if lastT != 0, t < lastT {
            // Beim Zeit-Reset nur die Zeitmarke anpassen.
            lastT = t
            return
        }
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
        VisualizerTimeline(isPlaying: isPlaying) { date in
            let t = isPlaying ? date.timeIntervalSinceReferenceDate : 0
            let active = audioTap.reactive
            let bands = audioTap.bands

            // Eine Energie pro Frequenz-Band (echtes Spektrum, sonst 0), geglättet. Dieselben
            // Werte speisen OBEN das Spektrogramm UND UNTEN die Balken → wo unten Ausschlag ist,
            // entsteht oben eine Linie; wo 0 ist, bleibt es leer.
            let barTargets: [Float] = (isPlaying && active && !bands.isEmpty)
                ? (0..<barLanes).map { min(1, max(0, bands[min(bands.count - 1, $0 * bands.count / barLanes)])) }
                : [Float](repeating: 0, count: barLanes)
            let barVals = isPlaying ? barSmoother.step(toward: barTargets, t: t, attack: 38, release: 12) : [CGFloat](repeating: 0, count: barLanes)

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
        // `<` statt `<=`: bei Breite 0 ist hSpacing 0 -> `<=` liefe (x += 0) endlos
        // auf dem Main-Thread. `<` ueberspringt den Fall (wie die y-Schleife unten).
        var x: CGFloat = 0
        while x < size.width {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            x += hSpacing
        }
        var y: CGFloat = 0
        while y < size.height {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            y += 28
        }
    }
}

// MARK: - BarsVisualizer

/// Equalizer-Balken aus dem ECHTEN Spektrum (FFT-Bänder), pro Frame geglättet → butterweich.
/// Kein Signal → Ruhe (flache Sockel), kein Fake-Zeitprogramm (bewusst: lieber warten).
private struct BarsVisualizer: View {

    let isPlaying: Bool
    let color1: Color
    let color2: Color
    let audioTap: AudioTap

    private let barCount = 18
    @State private var smoother = ArraySmoother()

    var body: some View {
        VisualizerTimeline(isPlaying: isPlaying) { date in
            let t = date.timeIntervalSinceReferenceDate
            // Echte Bänder als Ziel; ArraySmoother interpoliert frame-weise (gegen Ruckeln).
            let eased = isPlaying ? smoother.step(toward: targetBars(), t: t, attack: 38, release: 12) : [CGFloat](repeating: 0.03, count: barCount)
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

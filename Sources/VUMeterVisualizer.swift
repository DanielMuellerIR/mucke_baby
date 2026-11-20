import SwiftUI

/// Material der einzelnen VU-Meter-Einfassung.
enum VUMeterBezelStyle {
    case brushedSteel
    case polishedGold
}

/// Analoges VU-Nadel-Meter (ein oder zwei Gauge-Halbkreise mit Skala und Nadel).
/// Wenn isPlaying: Nadel schlägt aus. Wenn pausiert: Nadel ruht links.
struct VUMeterVisualizer: View {

    let isPlaying: Bool
    let needleColor: Color
    let faceColor: Color
    let textColor: Color
    let bezelStyle: VUMeterBezelStyle
    let audioTap: AudioTap

    var body: some View {
        VisualizerTimeline(isPlaying: isPlaying) { date in
            let t = date.timeIntervalSinceReferenceDate
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
    /// kein künstliches Zeitprogramm mehr (bewusst: lieber warten bis echte Pegel da sind, als
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
        guard isPlaying else {
            ball.value = 0
            ball.lastT = t
            return 0
        }
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

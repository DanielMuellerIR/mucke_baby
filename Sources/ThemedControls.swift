import SwiftUI

// MARK: - SectionHeader

/// Stilisierter Spalten-/Abschnittstitel ("STATIONS", "HISTORY" …).
/// Respektiert theme.fonts.uppercaseHeaders und theme.fonts.tracking.
public struct SectionHeader: View {

    private let text: String
    @Environment(\.theme) private var theme
    // Spaltentitel muessen beim CMD+/- Zoom mitwachsen wie alle anderen Texte —
    // sonst bleiben STATIONS/PLAYBACK_HISTORY klein (sichtbarer Stilbruch).
    @Environment(\.uiFontScale) private var uiFontScale

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let label = theme.fonts.uppercaseHeaders ? text.uppercased() : text
        // Spaltentitel nutzen den gut lesbaren label-Slot, NICHT den title-Slot:
        // sonst kaeme z.B. bei Marshall die Schreibschrift (cursive) — unleserlich.
        Text(label)
            .font(theme.font(.label, size: 11 * uiFontScale, weight: .semibold))
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

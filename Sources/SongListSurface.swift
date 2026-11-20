import SwiftUI

struct SongListSurface: View {
    @Environment(\.theme) private var theme
    var body: some View {
        if let parchment = theme.palette.parchment {
            ParchmentBackground(texture: theme.image(theme.panelTexture), paper: parchment.paper)
        } else {
            ThemedSurface(.panel)
        }
    }
}

// MARK: - ParchmentBackground

/// Heller Pergament-Hintergrund für die gemeinsamen Songlisten im Retro-Theme.
/// Wenn `texture` übergeben wird (paper.png), wird die echte PNG-Textur mit einem
/// leichten Creme-Scrim überlagert — das sorgt für gleichmäßige Helligkeit und
/// sichert die Lesbarkeit der dunklen Tinte.
/// Fehlt die Textur (nil), greift der prozedurale Fallback.
private struct ParchmentBackground: View {

    /// Optionale echte Papier-Textur aus dem Bundle (paper.png).
    let texture: Image?
    let paper: Color

    var body: some View {
        if let tex = texture {
            // Echte Textur + leichter Creme-Scrim für Gleichmäßigkeit.
            // WICHTIG: Creme-Farbe als Größen-Geber (füllt exakt das Angebot), Textur als
            // OVERLAY. Sonst wuchs der ZStack auf die scaledToFill-Bildgröße und das
            // History-Panel wurde breiter als sein `.frame(width:)` → drückte die Stage
            // zusammen („zu viel Rand rechts"). Gleiches Muster wie in ThemedSurface.
            paper
                .overlay { tex.resizable().scaledToFill() }
                .overlay { paper.opacity(0.25) }
                .clipped()
        } else {
            // Prozeduraler Fallback: warmes Papiergelb + Canvas-Noise
            proceduralParchment
        }
    }

    /// Prozeduraler Fallback wenn paper.png fehlt.
    @ViewBuilder private var proceduralParchment: some View {
        // Creme-Basis: warmes Papiergelb
        paper
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

import SwiftUI

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

            if theme.visualizer == .vu {
                // Retro/GuitarAmp: kein grosser Kasten mehr. Die Materialflaeche der Stage
                // bleibt sichtbar, nur die einzelnen VU-Meter bekommen eigene Einfassungen.
                vuMeterStage
            } else {
                // Visualizer füllt die Stage
                VisualizerView(isPlaying: player.isPlaying)
                    .padding(20)
            }
        }
    }

    /// VU-Bühne: Materialhintergrund der Stage behalten, VU-Meter direkt darauf platzieren.
    private var vuMeterStage: some View {
        let playing = player.isPlaying
        return ZStack {
            if let halo = theme.palette.vuStageHalo {
                // Nur Retro bekommt den warmen Roehren-Halo auf dem Holz/Metall-Hintergrund.
                RadialGradient(
                    gradient: Gradient(colors: [halo.opacity(playing ? 0.20 : 0.08), .clear]),
                    center: .center, startRadius: 30, endRadius: 420
                )
                .blendMode(.screen)
            }

            VisualizerView(isPlaying: playing)
                .padding(theme.palette.vuStageHalo == nil ? 22 : 26)
        }
    }
}

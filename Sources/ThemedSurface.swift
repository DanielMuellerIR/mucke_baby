import SwiftUI

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
        // Textur-Images und Canvas-Layer können Klicks abfangen. Als Hintergrund
        // sollen sie alle Interaktionen an die darüberliegenden Elemente lassen.
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
                    // tragen (Textur bewusst nur in Kopf/Fuß, dort über die .window-Fläche).
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

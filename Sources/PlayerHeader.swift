import SwiftUI

struct PlayerHeader: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    @Binding var editing: Bool
    @Binding var showHistory: Bool
    @Binding var selectedThemeRaw: String
    let onSearch: () -> Void
    let onAdd: () -> Void
    let onImportGenres: () -> Void
    let onPreferences: () -> Void

    // Kopf-Vordergrund: Bei GuitarAmp liegt die Kopfleiste auf einer HELLEN Goldplatte → die
    // normalen Theme-Töne (cremefarbener Titel, goldene Icons) verschwinden darauf. Deshalb
    // dort dunkle „Tinte" für Kontrast; in allen anderen Themes die Palette-Töne.
    private var headerInk: Color { theme.palette.headerPlate?.secondary ?? theme.palette.textSecondary }
    private var headerInkStrong: Color { theme.palette.headerPlate?.text ?? theme.palette.textPrimary }

    /// Kopfleiste mit Platz für die Ampel-Buttons, Titel, Transport und Aktions-Icons.
    var body: some View {
        HStack(spacing: 12) {
            // Platz fuer die schwebenden Ampel-Buttons (hiddenTitleBar laesst sie oben links)
            Color.clear.frame(width: 68, height: 1)

            // App-Titel groß + Version (Titel darf NICHT klein sein).
            // .layoutPriority(1): Titel gibt erst nach, wenn Stopp-Label + Slider schon
            // kollabiert/geschrumpft sind. .lineLimit(1) statt .fixedSize() — Titel bleibt
            // groß, kürzt im absoluten Extremfall mit „…" statt die Ampel zu überlappen.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Mucke, Baby!")
                    .font(theme.font(.title, size: 18 * uiFontScale, weight: .bold))
                    .tracking(theme.fonts.tracking)
                    .foregroundStyle(headerInkStrong)
                    .lineLimit(1)             // groß bleiben, aber im Extremfall kürzen statt überlappen
                // Version: lesbar, aber dezent — textSecondary statt textDim (war kaum lesbar).
                Text("v\(AppInfo.version)")
                    .font(theme.font(.label, size: 11 * uiFontScale, weight: .medium))
                    .foregroundStyle(headerInk)
                    .lineLimit(1)
            }
            .layoutPriority(1)            // Titel gibt erst als Letztes nach (rechtes Cluster zuerst)

            Spacer(minLength: 12)

            // Transport: Play/Stop (Stopp oben). Bei Platzmangel fällt das
            // Text-Label weg — nur das Icon bleibt. ViewThatFits nimmt die
            // erste Variante, die in die verfügbare Breite passt.
            Button {
                if let s = player.currentStation {
                    player.toggle(store.stations.first(where: { $0.id == s.id }) ?? s)
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Image(systemName: (player.hasPlaybackIntent) ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text((player.hasPlaybackIntent) ? String(localized: "Stopp") : String(localized: "Abspielen"))
                            .font(theme.font(.label, size: 11 * uiFontScale, weight: .semibold))
                            .lineLimit(1)         // kein .fixedSize() — verhindert künstliches Aufblähen
                    }
                    // Fallback: nacktes Icon (Tooltip via .help unten gibt den Kontext)
                    Image(systemName: (player.hasPlaybackIntent) ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(theme.palette.headerPlate?.text ?? theme.palette.playActive)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentStation == nil)
            .help((player.hasPlaybackIntent) ? String(localized: "Stopp") : String(localized: "Abspielen"))

            // Laufzeit + Lautstaerke sitzen jetzt im Fuß (neben der Zeit) — in der Titelregion
            // der Kopfleiste fing der native Fenster-Drag den Knopf-Mouse-Down ab.

            Rectangle().fill(theme.palette.divider).frame(width: 1, height: 20)
            headerActions
        }
        .padding(.horizontal, 14)
        // Die Ampel-Buttons liegen inline. Bei knob-Themes bleibt die Kopfleiste
        // als breitere Bedienblende sichtbar.
        .frame(height: theme.control == .knob ? 52 : 38)
        .background { headerBackground }
    }

    /// Kopfleisten-Hintergrund. Stack: gebürstete Goldplatte über dunklem Grund
    /// (echte Leiste aus gebürstetem Gold = die obere Bedienleiste). Sonst Theme-Panel.
    @ViewBuilder
    private var headerBackground: some View {
        if let plate = theme.palette.headerPlate {
            // Helle, gebürstete Messingplatte (Amp-Bedienpanel, Vorbild marshall_amp_design).
            // Warmer Gold-Verlauf als Basis (hell oben → dunkler unten = leichte Wölbung),
            // optionale Goldtextur als Korn (blendMode .overlay), feine waagrechte Bürstlinien,
            // oben Glanzkante / unten Schattenkante (3D-Bevel der Platte).
            LinearGradient(
                colors: plate.gradient,
                startPoint: .top, endPoint: .bottom
            )
            .overlay {
                if let gold = theme.image(theme.accentTexture) {
                    gold.resizable().scaledToFill().opacity(0.62).blendMode(.overlay)
                }
            }
            .overlay { BrushedGoldSheen() }
            .overlay(alignment: .top) {       // Glanzkante oben
                LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 3)
            }
            .overlay(alignment: .bottom) {     // Schattenkante unten (Bevel-Abschluss)
                LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 4)
            }
            .clipped()
        } else {
            ThemedSurface(.panel)
        }
    }

    /// Aktions-Icons rechts: Suche, Hinzufuegen, Bearbeiten, Einstellungen, Audio, Verlauf, Theme.
    private var headerActions: some View {
        HStack(spacing: 14) {
            headerIcon("magnifyingglass", "Sender-Katalog: stöbern, probehören, hinzufügen (radio-browser)") { onSearch() }
            Menu {
                Button("Sender hinzufügen …") { onAdd() }
                Button("Genre-Liste importieren …") { onImportGenres() }
            } label: {
                Image(systemName: "plus").font(.system(size: 13))
                    .foregroundStyle(headerInk)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Hinzufügen")
            headerIcon(editing ? "checkmark" : "pencil", editing ? "Fertig" : "Bearbeiten") { editing.toggle() }
            headerIcon("gearshape", "Einstellungen") { onPreferences() }
            AudioSettingsButton().foregroundStyle(headerInk)
            headerIcon(showHistory ? "sidebar.trailing" : "clock.arrow.circlepath",
                       "Verlauf ein-/ausblenden") { withAnimation { showHistory.toggle() } }
            headerIcon("paintpalette", "Theme: \(theme.name) → \(Theme.theme(theme.nextID).name)") {
                selectedThemeRaw = theme.nextID.rawValue
            }
        }
    }

    /// Einheitlicher Kopf-Icon-Button (theme-getoent, plain — keine Glas-Kapsel).
    private func headerIcon(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(headerInk)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

}

/// Feine waagrechte Bürstlinien für die gebürstete Goldplatte (GuitarAmp-Kopf).
/// Deterministisch (LCG-Hash, kein random) und CPU-schonend.
private struct BrushedGoldSheen: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt32 = 0xC0FF_EE11
            func next() -> Double {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Double(seed) / Double(UInt32.max)
            }
            var y = 0.0
            while y < size.height {
                let a = 0.03 + next() * 0.05
                // Abwechselnd helle (Sheen) und dunkle (Riefe) Linien → Brushed-Optik.
                let col: Color = next() > 0.5 ? .white.opacity(a) : .black.opacity(a * 0.7)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(col), lineWidth: 0.6)
                y += 1.5
            }
        }
        .allowsHitTesting(false)
    }
}

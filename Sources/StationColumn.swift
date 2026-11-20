import SwiftUI

/// Senderliste mit Filtern und Bearbeitungsmodus.
/// Ein fester Rahmen verhindert, dass sich die Liste auf ihre Inhaltsbreite zusammenzieht.
struct StationColumn: View {
    @EnvironmentObject private var store: Store
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    let width: CGFloat
    let editing: Bool
    let onQuickSelection: () -> Void
    let onGroups: () -> Void
    let onEdit: (Station) -> Void

    @State private var stationQuery = ""
    @State private var stationScope = StationListScope.all

    var body: some View {
        let visibleStations = StationSelection.filtered(
            store.stations, groups: store.groups, query: stationQuery, scope: stationScope
        )
        VStack(spacing: 0) {
            // Spalten-Kopf: nur Titel (Suche/Hinzufügen/Bearbeiten sitzen in der Kopfleiste).
            HStack(spacing: 8) {
                // Header der Senderliste — in allen Themes "STATIONS" (kein .EXE;
                // Windows-Endung bewusst entfernt, 2026-06-09).
                SectionHeader("STATIONS")
                Spacer()
                Button(action: onQuickSelection) {
                    Image(systemName: "list.bullet.rectangle").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Sender schnell auswählen …").accessibilityLabel("Sender schnell auswählen …")
                .accessibilityIdentifier("station-quick-open")
                Button(action: onGroups) {
                    Image(systemName: "folder").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Sendergruppen").accessibilityLabel("Sendergruppen")
                .accessibilityIdentifier("station-groups-open")
                if editing {
                    Text(theme.fonts.uppercaseHeaders ? "BEARBEITEN" : "Bearbeiten")
                        .font(theme.font(.label, size: 9 * uiFontScale, weight: .semibold))
                        .foregroundStyle(theme.palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle()
                .fill(theme.palette.divider)
                .frame(height: 1)

            if !editing {
                StationFilterControls(query: $stationQuery, scope: $stationScope, identifier: "main-stations")
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("\(visibleStations.count) von \(store.enabledStations.count) Sendern")
                    .font(theme.font(.label, size: 10 * uiFontScale))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .accessibilityIdentifier("station-result-count")
            }
            if editing {
                // Bearbeiten-Modus: native List (Reihenfolge/Löschen/An-Aus/Favorit/Edit).
                // Bewusst nativ — Funktion vor Theming; der Theme-Hintergrund scheint durch.
                List {
                    ForEach(store.stations) { st in
                        EditRow(station: st) { onEdit(st) }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    .onDelete { store.delete(at: $0, in: store.stations) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                // Wiedergabe-Modus: themed Senderzeilen. ScrollView+VStack (nicht List),
                // damit die Theme-Optik exakt steuerbar ist; Breite kommt vom GeometryReader.
                ScrollView {
                    VStack(spacing: 0) {
                        if visibleStations.isEmpty {
                            Text("Keine passenden Sender.")
                                .font(theme.font(.body, size: 12 * uiFontScale))
                                .foregroundStyle(theme.palette.textSecondary).padding(16)
                        }
                        ForEach(visibleStations) { st in
                            ConsoleStationRow(station: st)
                            Rectangle()
                                .fill(theme.palette.divider)
                                .frame(height: 1)
                                .opacity(0.5)
                        }
                    }
                }
            }
        }
        .frame(width: width)
        .background { ThemedSurface(.panel) }
    }
}

// MARK: - Themed Stations-Zeile (console-Layout)

/// Sender-Zeile fuer das console-Layout. Passt Marker und Stil dem Theme an.
/// Klick-Aktion: dieselbe wie in PlayRow (player.toggle).
private struct ConsoleStationRow: View {
    @EnvironmentObject var player: RadioPlayer
    @EnvironmentObject var health: StationHealth
    @Environment(\.theme) private var theme
    // Die Senderzeilen verwenden explizite Schriftgrößen und skalieren über diesen Faktor.
    @Environment(\.uiFontScale) private var uiFontScale
    let station: Station

    @State private var showError = false

    private var isCurrent: Bool { player.currentStation?.id == station.id }
    private var isActive: Bool { isCurrent && player.isPlaying }

    private var badReason: String? {
        if case .bad(let r) = health.states[station.id] ?? .unknown { return r }
        return nil
    }

    /// Index des Senders in der sichtbaren Liste (fuer retro-Nummerierung).
    @EnvironmentObject var store: Store
    private var stationIndex: Int? {
        store.enabledStations.firstIndex(where: { $0.id == station.id })
    }

    var body: some View {
        Button {
            player.toggle(station)
        } label: {
            HStack(spacing: 8) {
                // Fuehrender Marker je nach Theme-Stil
                leadingMarker

                VStack(alignment: .leading, spacing: 2) {
                    // Stations-Name (im midi-Theme mit ">>> "-Prefix)
                    let nameText = (theme.control == .terminal) ? ">>> \(station.name)" : station.name
                    Text(nameText)
                        .font(theme.font(.body, size: 12 * uiFontScale, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isActive ? theme.palette.selectionText : theme.palette.textPrimary)
                        .lineLimit(1)
                    // Aktueller Titel wenn dieser Sender spielt
                    if isCurrent && !player.nowPlayingTitle.isEmpty {
                        Text(player.nowPlayingTitle)
                            .font(theme.font(.label, size: 10 * uiFontScale))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Rechte Seite: Favorit, Ladesymbol, Warnung
                if station.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.palette.favorite)
                }
                if isCurrent && player.isLoading {
                    ProgressView().controlSize(.mini)
                }
                if let reason = badReason {
                    Button { showError.toggle() } label: { Text("⚠️").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Sender nicht erreichbar")
                        .popover(isPresented: $showError) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sender nicht erreichbar").font(.headline)
                                Text(reason).font(.callout)
                                Text(station.url).font(.caption)
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .padding(12).frame(width: 300)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // SwiftUI ignorierte Klicks auf Plain-Buttons dieser ScrollView in Design-Themes.
        // Die leere Geste aktiviert das Hit-Testing. Die Button-Aktion startet den Sender.
        .simultaneousGesture(TapGesture().onEnded { })
        // Selektierter/spielender Sender: Auswahl-Hintergrund
        .background(
            isActive
                ? theme.palette.selection.opacity(0.25)
                : Color.clear
        )
        .foregroundStyle(theme.palette.textPrimary)
        .accessibilityIdentifier("station-play-" + station.id.uuidString)
    }

    /// Fuehrender Marker (LED, Nummer, Bullet) je nach Theme-Kontrollstil.
    @ViewBuilder
    private var leadingMarker: some View {
        switch theme.control {
        case .neon, .terminal:
            // Leuchtender LED-Punkt
            LEDDot(on: isActive, color: theme.palette.playActive, size: 8)
                .frame(width: 14)

        case .knob:
            // Kleine Nummer (retro/stack) oder Radio-Symbol
            if let idx = stationIndex {
                Text("\(idx + 1).")
                    .font(theme.font(.label, size: 10 * uiFontScale, weight: .medium))
                    .foregroundStyle(isActive ? theme.palette.accent : theme.palette.textDim)
                    .frame(width: 20, alignment: .trailing)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.palette.textDim)
                    .frame(width: 20)
            }

        case .stamp, .hairline, .plain:
            // Einfacher Bullet
            Circle()
                .fill(isActive ? theme.palette.playActive : theme.palette.divider)
                .frame(width: 5, height: 5)
                .frame(width: 14)
        }
    }
}

// Zeile im Bearbeiten-Modus: an/aus, Favorit, Bearbeiten.
private struct EditRow: View {
    @EnvironmentObject var store: Store
    let station: Station
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { station.enabled },
                set: { _ in store.toggleEnabled(station) }
            ))
            .labelsHidden()
            .help("In Liste anzeigen")

            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).scaledFont(.body).foregroundStyle(station.enabled ? .primary : .secondary)
                Text(station.url).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            StationFavoriteButton(station: station)

            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Bearbeiten")
        }
    }
}

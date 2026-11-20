import SwiftUI

struct HistoryPanelHeader: View {
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale
    let onClose: () -> Void
    let onOpenRecordings: () -> Void
    @Binding var showDeleteAllRecordingsConfirmation: Bool
    @Binding var showClearHistoryConfirmation: Bool

    var body: some View {
        HStack {
            // classic (schlicht): wie bisher der schlichte Headline-Text.
            // console: stilisierter SectionHeader (Tracking/Uppercase je Theme).
            if theme.isConsole {
                SectionHeader(theme.historyTitle)
            } else {
                Text("Verlauf").themedFont(theme, .title, size: 13 * uiFontScale, weight: .semibold)
                    .foregroundColor(theme.palette.textPrimary)
            }
            Spacer()
            Button(action: onOpenRecordings) { Image(systemName: "waveform") }
                .buttonStyle(.plain).help("Aufnahmebibliothek")
                .accessibilityLabel("Aufnahmebibliothek")
                .accessibilityIdentifier("recordings-open")
            Menu {
                // Erster Satz: Verlauf-Eintraege UND die zugehoerigen Aufnahmen
                // bis zum Cutoff loeschen (bisheriges Verhalten, cleanupHistory).
                Section("Verlauf und Aufnahmen") {
                    Button("Älter als 1 Tag löschen") { clean(.day, 1) }
                    Button("Älter als 1 Woche löschen") { clean(.day, 7) }
                    Button("Älter als 1 Monat löschen") { clean(.month, 1) }
                }
                // Zweiter Satz: NUR die lokalen Aufnahme-Dateien loeschen,
                // der Verlauf (welche Songs liefen) bleibt komplett stehen.
                Section("Nur Aufnahmen (Verlauf bleibt)") {
                    Button("Älter als 1 Tag löschen") { cleanRecordings(.day, 1) }
                    Button("Älter als 1 Woche löschen") { cleanRecordings(.day, 7) }
                    Button("Älter als 1 Monat löschen") { cleanRecordings(.month, 1) }
                    // .distantFuture als Cutoff = jede abgeschlossene Aufnahme ist
                    // "aelter" -> alle weg. Eine gerade LAUFENDE Aufnahme (end == nil,
                    // offenes FileHandle) bleibt bewusst bestehen.
                    Button("Alle Aufnahmen löschen", role: .destructive) {
                        showDeleteAllRecordingsConfirmation = true
                    }
                }
                Divider()
                Button("Gesamten Verlauf löschen", role: .destructive) {
                    showClearHistoryConfirmation = true
                }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(theme.palette.songListActions) }
                .menuStyle(.borderlessButton).fixedSize().help("Verlauf-Optionen")
            Button { onClose() } label: { Image(systemName: "sidebar.trailing").foregroundStyle(theme.palette.songListActions) }
                .buttonStyle(.plain).help("Verlauf ausblenden")
        }
        .padding(10)
    }

    private func clean(_ comp: Calendar.Component, _ value: Int) {
        let cutoff = Calendar.current.date(byAdding: comp, value: -value, to: Date()) ?? Date()
        player.cleanupHistory(olderThan: cutoff)
    }

    // Nur die Aufnahme-Dateien (+ Index) aelter als der Cutoff loeschen — der
    // Verlauf bleibt vollstaendig erhalten. Man sieht also weiter, welche Songs
    // liefen; nur der Export ("Keine Aufnahme zu diesem Titel.") geht dann nicht mehr.
    private func cleanRecordings(_ comp: Calendar.Component, _ value: Int) {
        let cutoff = Calendar.current.date(byAdding: comp, value: -value, to: Date()) ?? Date()
        player.recorder.prune(olderThan: cutoff)
    }
}

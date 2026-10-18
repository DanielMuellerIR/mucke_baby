import SwiftUI

struct TimeshiftSettingsView: View {
    @EnvironmentObject private var player: RadioPlayer
    @State private var confirm = false

    var body: some View {
        Section("Zeitversatz-Puffer") {
            Toggle("Temporären Audiopuffer aktivieren", isOn: Binding(
                get: { player.timeshiftRequested },
                set: { if $0 { confirm = true } else { player.setTimeshiftRequested(false) } }))
                .accessibilityIdentifier("timeshift-enable")
            Text("Standardmäßig AUS. Nur MP3; höchstens 5 Minuten und 32 MiB Audio plus begrenzter Index. Alte Puffersegmente werden automatisch entfernt. Stoppt unter 10 GiB freiem Speicher. Abschalten, Senderwechsel und Beenden verwerfen den Puffer. Dauerhafte Aufnahmen und Verlauf bleiben erhalten. Die Wiedergabe wechselt nach mindestens 3 s Reserve auf den Puffer. Pause, Sprünge und Live stehen dann im Player bereit. Sprünge und Titel folgen der Hörposition.")
                .font(.caption).foregroundStyle(.secondary)
            Text(player.timeshiftStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("timeshift-status")
        }
        .alert("Zeitversatz aktivieren?", isPresented: $confirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren und alte Puffersegmente entfernen") { player.setTimeshiftRequested(true) }
        } message: {
            Text("Der temporäre MP3-Puffer entfernt seine ältesten Segmente automatisch innerhalb der angezeigten Grenzen. Beim Abschalten, Senderwechsel und Beenden wird er verworfen. Vorhandene Aufnahmen und Verlauf werden nicht gelöscht.")
        }
    }
}

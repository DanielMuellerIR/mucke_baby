import SwiftUI

struct RecordingControl: View {
    @EnvironmentObject var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var fontScale
    @State private var showingDetails = false
    var identifier = "recording"

    private var shortStatus: String {
        switch player.recordingState.phase {
        case .off: String(localized: "Aus")
        case .waiting, .needsStreamHeader: String(localized: "Wartet")
        case .recording: String(localized: "Läuft")
        case .lowDisk: String(localized: "Speicher")
        case .indexUnavailable: String(localized: "Indexfehler")
        case .streamEnded: String(localized: "Verbindung")
        case .writeFailed: String(localized: "Schreibfehler")
        }
    }
    private var status: String {
        switch player.recordingState.phase {
        case .off: String(localized: "Aufnahme ist ausgeschaltet.")
        case .waiting: String(localized: "Aufnahme ist aktiviert und wartet auf Audiobytes. Ohne laufenden Stream wird nichts gespeichert.")
        case .needsStreamHeader: String(localized: "Aufnahme wird mit vollständigen Streamheadern vorbereitet. Die Wiedergabe läuft weiter.")
        case .recording: String(localized: "Audiobytes werden im Aufnahmeordner gespeichert.")
        case .lowDisk: String(localized: "Aufnahme gestoppt: weniger als 10 GiB frei. Speicher freigeben und Aufnahme aus- und wieder einschalten.")
        case .indexUnavailable: String(localized: "Der Aufnahmeindex ist nicht verfügbar. Aufnahmeordner prüfen; bestehende Dateien bleiben erhalten.")
        case .streamEnded: String(localized: "Die Metadatenverbindung ist beendet. Für einen neuen Aufnahmeversuch den Sender erneut starten.")
        case .writeFailed: String(localized: "Die Aufnahme konnte nicht geschrieben werden. Aufnahmeordner und Speicher prüfen; danach aus- und wieder einschalten.")
        }
    }
    private var color: Color {
        switch player.recordingState.phase {
        case .recording, .lowDisk, .indexUnavailable, .streamEnded, .writeFailed: theme.palette.alert
        case .waiting, .needsStreamHeader: .orange
        case .off: theme.palette.textSecondary
        }
    }
    var body: some View {
        HStack(spacing: 2) {
            Button { player.setRecordingRequested(!player.recordingRequested) } label: {
                HStack(spacing: 4) {
                    Image(systemName: player.recordingState.phase == .recording ? "record.circle.fill" : "record.circle")
                    Text(shortStatus).lineLimit(1)
                }
                .font(theme.font(.label, size: 11 * fontScale)).frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(color)
            .help(status + " " + (player.recordingRequested ? String(localized: "Aufnahme ausschalten") : String(localized: "Aufnahme einschalten")))
            .accessibilityLabel(String(localized: "Aufnahme") + ": " + status)
            .accessibilityIdentifier(identifier + "-toggle")
            Button { showingDetails = true } label: {
                Image(systemName: "info.circle").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.palette.textSecondary)
            .help("Aufnahmestatus").accessibilityLabel("Aufnahmestatus")
            .accessibilityIdentifier(identifier + "-details")
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Aufnahmestatus").font(.headline)
                    Text(status).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recording-status-message")
                    Toggle("Laufende Streams mitschneiden", isOn: Binding(get: { player.recordingRequested }, set: player.setRecordingRequested))
                    Text("Der Schalter wirkt sofort auf den Mitschnitt. Die Wiedergabe läuft weiter. Ablage: ~/Music/MuckeBaby/Aufnahmen/. Aufnahme ist bei einer neuen Installation aus.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Fertig") { showingDetails = false }.keyboardShortcut(.cancelAction)
                }.padding(16).frame(width: 330)
            }
        }
        .fixedSize()
    }
}

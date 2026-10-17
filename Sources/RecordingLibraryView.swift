import SwiftUI
import AppKit

private struct RecordingLibraryActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openRecordingLibrary: (() -> Void)? {
        get { self[RecordingLibraryActionKey.self] }
        set { self[RecordingLibraryActionKey.self] = newValue }
    }
}

struct RecordingLibraryView: View {
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @AppStorage("volume") private var volume = 0.77
    @StateObject private var preview = RecordingPreview()
    @State private var inventory: RecordingLibrarySnapshot?
    @State private var selection: UUID?
    @State private var confirmPreview = false
    @State private var confirmRemoval = false
    @State private var pendingRemoval: RecordingLibraryItem?
    @State private var pendingPreview: UUID?
    @State private var busy = false
    @State private var message: String?
    @State private var previewTask: Task<Void, Never>?
    var availableWidth: CGFloat = 780

    private var selected: RecordingLibraryItem? { inventory?.items.first { $0.id == selection } }
    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var live: Bool { player.isPlaying || player.isLoading || player.currentStreamURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Aufnahmebibliothek", systemImage: "waveform")
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold))
                Spacer()
                Button { NSWorkspace.shared.open(player.recorder.dir) } label: { Image(systemName: "folder") }
                    .help("Aufnahmeordner öffnen").accessibilityLabel("Aufnahmeordner öffnen")
                    .accessibilityIdentifier("recordings-folder")
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("recordings-close")
            }
            Text("Aufnahmen bleiben unabhängig vom Verlauf erhalten. Vorhören beendet Live-Radio; anschließend den Sender bei Bedarf manuell starten.")
                .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
            if let inventory, !inventory.indexWritable {
                Label("Der Aufnahmeindex ist schreibgeschützt oder beschädigt. Die Dateien bleiben erhalten.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if inventory?.indexRecovered == true {
                Text("Der beschädigte Aufnahmeindex wurde gesichert. Vorhandene Dateien können im Aufnahmeordner geprüft werden.")
                    .font(.callout).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let inventory, !inventory.items.isEmpty {
                    List(selection: $selection) {
                        ForEach(inventory.items) { item in row(item).tag(item.id) }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("recordings-list")
                } else if inventory == nil {
                    ProgressView("Aufnahmen werden geladen …").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.largeTitle)
                        Text("Noch keine Aufnahmen")
                        Text("Die Aufnahme lässt sich im Hauptfenster bewusst einschalten.")
                            .font(.callout).foregroundStyle(dim)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("recordings-empty")
                }
            }
            .frame(minHeight: 180, idealHeight: 300)
            .background(ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            if let selected {
                Text(selected.clip.file).font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(dim).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let text = message ?? preview.error {
                Text(text).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recordings-error")
            }
            HStack(spacing: 10) {
                Button {
                    if preview.currentID != nil { cancelPreview() }
                    else if live { pendingPreview = selection; confirmPreview = true }
                    else { startPreview() }
                } label: {
                    Label(preview.currentID == nil ? String(localized: "Vorhören") : String(localized: "Vorhören stoppen"),
                          systemImage: preview.currentID == nil ? "play.fill" : "stop.fill")
                }
                .disabled(busy || (preview.currentID == nil && selected?.canPreview != true))
                .accessibilityIdentifier("recordings-preview")
                if preview.isLoading { ProgressView().controlSize(.small) }
                Button("Im Finder zeigen") { reveal() }
                    .disabled(selected == nil || selected?.status == .missing || selected?.status == .unreadable)
                    .accessibilityIdentifier("recordings-reveal")
                Spacer(minLength: 0)
                Button("Löschen …", role: .destructive) { pendingRemoval = selected; confirmRemoval = true }
                    .disabled(busy || selected == nil || selected?.isActive == true || selected?.status == .unreadable || inventory?.indexWritable != true)
                    .accessibilityIdentifier("recordings-delete")
            }
            Text("Laufende Aufnahmen sind geschützt. Löschen entfernt nur die ausgewählte Aufnahme-Datei und ihren Indexeintrag; der Verlauf bleibt erhalten.")
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .foregroundStyle(ink)
        .frame(width: min(820, max(580, availableWidth)), height: 570 + 180 * max(0, scale - 1))
        .background { SongListSurface() }
        .confirmationDialog("Live-Radio zum Vorhören beenden?", isPresented: $confirmPreview, titleVisibility: .visible) {
            Button("Radio beenden und vorhören") { startPreview(id: pendingPreview, stopLive: true) }
                .accessibilityIdentifier("recordings-confirm-preview")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Live-Radio und eine laufende Aufnahme werden beendet. Nach dem Vorhören startet das Radio nicht automatisch erneut.")
        }
        .confirmationDialog("Ausgewählte Aufnahme endgültig löschen?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Aufnahme endgültig löschen", role: .destructive) { removeSelected() }
                .accessibilityIdentifier("recordings-confirm-delete")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text((pendingRemoval?.clip.file ?? "") + "\n\n" + String(localized: "Nur diese abgeschlossene Aufnahme-Datei wird entfernt. Der Verlauf und alle anderen Aufnahmen bleiben erhalten."))
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onChange(of: player.isLoading) { _, value in if value { cancelPreview() } }
        .onChange(of: player.isPlaying) { _, value in if value { cancelPreview() } }
        .onDisappear { cancelPreview() }
    }

    private func row(_ item: RecordingLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.clip.station).font(theme.font(.body, size: 13 * scale, weight: .semibold)).lineLimit(1)
                Spacer()
                Label(status(item), systemImage: item.isActive ? "record.circle" : item.canPreview ? "waveform" : "exclamationmark.triangle")
                    .font(theme.font(.label, size: 11 * scale))
            }
            HStack(spacing: 12) {
                Text(item.clip.start, format: .dateTime.year().month().day().hour().minute())
                Spacer(minLength: 0)
                Text(duration(item))
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    .frame(minWidth: 65, alignment: .trailing)
            }.font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
        }
        .foregroundStyle(ink).padding(.vertical, 6)
        .accessibilityIdentifier("recording-row-" + item.id.uuidString)
    }

    private func status(_ item: RecordingLibraryItem) -> String {
        if item.isActive { return String(localized: "Aufnahme läuft") }
        switch item.status {
        case .available: return String(localized: "Abgeschlossen")
        case .missing: return String(localized: "Datei fehlt")
        case .unreadable: return String(localized: "Nicht lesbar")
        case .empty: return String(localized: "Datei ist leer")
        }
    }

    private func duration(_ item: RecordingLibraryItem) -> String {
        let seconds = Int(max(0, (item.clip.end ?? Date()).timeIntervalSince(item.clip.start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func refresh() async {
        let next = await player.recorder.librarySnapshot()
        guard !Task.isCancelled else { return }
        inventory = next
        if let selection, !next.items.contains(where: { $0.id == selection }) { self.selection = nil }
        if let id = preview.currentID, !next.items.contains(where: { $0.id == id && $0.canPreview }) { cancelPreview() }
    }

    private func startPreview(id requestedID: UUID? = nil, stopLive: Bool = false) {
        guard let id = requestedID ?? selection else { return }
        cancelPreview(); message = nil
        previewTask = Task {
            do {
                let url = try await player.recorder.previewURL(id: id)
                try Task.checkCancellation()
                if stopLive { player.stop() }
                preview.play(id: id, url: url, volume: Float(volume))
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }

    private func cancelPreview() { previewTask?.cancel(); previewTask = nil; preview.stop() }

    private func reveal() {
        guard let item = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([player.recorder.dir.appendingPathComponent(item.clip.file)])
    }

    private func removeSelected() {
        guard let id = pendingRemoval?.id else { return }
        if preview.currentID == id { cancelPreview() }
        busy = true; message = nil
        Task {
            do { try await player.recorder.removeCompleted(id: id) }
            catch { message = error.localizedDescription }
            await refresh(); busy = false
        }
    }
}

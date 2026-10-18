import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportEditorRequest: Identifiable {
    let id = UUID()
    let entry: SongEntry
    let source: URL
    let offset: Double
    let duration: Double
    let availableWidth: CGFloat
    let availableHeight: CGFloat
}

struct ExportEditorView: View {
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.dismiss) private var dismiss
    @AppStorage("volume") private var volume = 0.77
    @StateObject private var model: ExportEditorModel
    @StateObject private var preview = RecordingPreview()
    @State private var previewTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var exporting = false
    @State private var confirmPreview = false
    @State private var pendingPreview: URL?
    @State private var message: String?
    @State private var saved = false
    @FocusState private var field: Field?
    private enum Field { case start, end }
    let request: ExportEditorRequest

    init(request: ExportEditorRequest) {
        self.request = request
        _model = StateObject(wrappedValue: ExportEditorModel(source: request.source,
                                                            offset: request.offset, duration: request.duration))
    }

    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var live: Bool { player.isPlaying || player.isLoading || player.currentStreamURL != nil }
    private var previewVolume: Float { Float(volume.isFinite ? min(1, max(0, volume)) : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Song exportieren", systemImage: "scissors")
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold))
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export-close")
            }
            ScrollView(.vertical) {
                editorContent.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 2)
            }
            if model.isPreparing || exporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(exporting ? String(localized: "Exportiere …") : String(localized: "Ausschnitt wird vorbereitet …"))
                }.font(theme.font(.body, size: 12 * scale))
            }
            HStack {
                Button {
                    if model.isPreparing { cancelPreview(); model.cancelPreparation() }
                    else if preview.currentID != nil { cancelPreview() }
                    else { preparePreview() }
                } label: {
                    Label(model.isPreparing ? String(localized: "Abbrechen") : preview.currentID == nil
                          ? String(localized: "Vorhören") : String(localized: "Vorhören stoppen"),
                          systemImage: preview.currentID == nil ? "play.fill" : "stop.fill")
                }
                .disabled(!model.canPrepare || exporting).keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Vorhören oder stoppen (⌘⇧P)")
                .accessibilityIdentifier("export-preview")
                if preview.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Als Datei speichern …") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!model.canPrepare || model.isPreparing || exporting)
                    .accessibilityIdentifier("export-save")
            }
            Text("Vorhören und Speichern verwenden denselben Ausschnitt. Vorhören beendet Live-Radio; danach den Sender bei Bedarf manuell starten.")
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).foregroundStyle(ink)
        .frame(width: min(760, max(580, request.availableWidth)),
               height: min(max(480, request.availableHeight), 560 + 180 * max(0, scale - 1)))
        .background { SongListSurface() }
        .confirmationDialog("Live-Radio zum Vorhören beenden?", isPresented: $confirmPreview, titleVisibility: .visible) {
            Button("Radio beenden und vorhören") { if let pendingPreview { startPreview(pendingPreview, stopLive: true) } }
                .accessibilityIdentifier("export-confirm-preview")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Live-Radio wird beendet. Falls eine Aufnahme läuft, endet sie ebenfalls. Nach dem Vorhören startet das Radio nicht automatisch erneut.")
        }
        .task { await model.load(); if model.range != nil { field = .start } }
        .onChange(of: model.revision) { _, _ in cancelPreview(); message = nil; saved = false }
        .onChange(of: player.isLoading) { _, value in if value { cancelPreview() } }
        .onChange(of: player.isPlaying) { _, value in if value { cancelPreview() } }
        .onChange(of: volume) { _, _ in preview.setVolume(previewVolume) }
        .onDisappear { cancelPreview(); exportTask?.cancel(); model.close() }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.entry.raw).font(theme.font(.body, size: 14 * scale, weight: .semibold))
                    .lineLimit(2).textSelection(.enabled).help(request.entry.raw)
                Text(request.entry.station).font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                    .lineLimit(1).help(request.entry.station)
                Text(request.source.lastPathComponent).font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(dim).lineLimit(2)
            }
            Text("Die Zeitkorrekturen gelten nur für diesen Export. Die Aufnahme bleibt unverändert.")
                .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
            if model.isLoading {
                ProgressView("Verfügbares Audio wird geprüft …").frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let range = model.range {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Verfügbares Audio")
                        Spacer()
                        Text(time(range.audio.start) + " – " + time(range.audio.end)).monospacedDigit()
                    }.font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                    if range.isPartial {
                        Text("Der Titel ist nur teilweise aufgenommen. Die Ausgangsgrenzen wurden an das verfügbare Audio angepasst.")
                            .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    adjustment("Anfangskorrektur", value: Binding(get: { model.startAdjustment }, set: { model.setStart($0) }),
                               id: "export-start", field: .start)
                    adjustment("Endkorrektur", value: Binding(get: { model.endAdjustment }, set: { model.setEnd($0) }),
                               id: "export-end", field: .end)
                    HStack {
                        Toggle("Ein- und Ausblenden", isOn: Binding(get: { model.faded }, set: { model.setFaded($0) }))
                            .accessibilityIdentifier("export-fade")
                        Spacer()
                        Button("Grenzen zurücksetzen") { model.reset() }.accessibilityIdentifier("export-reset")
                    }.font(theme.font(.label, size: 11 * scale))
                    if let cut = try? model.cut {
                        HStack {
                            Text("Ausschnitt")
                            Spacer()
                            Text(time(cut.start) + " – " + time(cut.end)).monospacedDigit()
                            Text(cut.duration.formatted(.number.precision(.fractionLength(0...2))) + " s").monospacedDigit()
                        }.font(theme.font(.label, size: 12 * scale)).accessibilityIdentifier("export-range")
                    }
                }.padding(14).background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(exporting)
            }
            if let error = model.validationMessage ?? message ?? model.message ?? preview.error {
                Text(error).font(theme.font(.body, size: 12 * scale)).foregroundStyle(saved ? dim : .red)
                    .lineLimit(3).help(error).accessibilityIdentifier("export-message")
            }
        }
    }

    private func adjustment(_ title: LocalizedStringKey, value: Binding<Double>, id: String, field focus: Field) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)).grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: 100 * scale).focused($field, equals: focus)
                .accessibilityIdentifier(id)
            Text("s").foregroundStyle(dim)
            Stepper(title, value: value, step: 0.5).labelsHidden().fixedSize()
                .accessibilityIdentifier(id + "-step")
        }.font(theme.font(.body, size: 12 * scale))
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let hours = floor(value / 3600), minutes = floor((value - hours * 3600) / 60)
        return String(format: "%.0f:%02.0f:%05.2f", locale: Locale.current,
                      hours, minutes, value - hours * 3600 - minutes * 60)
    }

    private func preparePreview() {
        cancelPreview(); message = nil; saved = false
        previewTask = Task {
            do {
                let url = try await model.prepare()
                try Task.checkCancellation()
                guard model.preparedURL == url else { return }
                if live { pendingPreview = url; confirmPreview = true }
                else { startPreview(url) }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }

    private func startPreview(_ url: URL, stopLive: Bool = false) {
        guard !model.isClosed, model.preparedURL == url, FileManager.default.isReadableFile(atPath: url.path) else { return }
        if stopLive { player.stop() }
        preview.play(id: UUID(), url: url, volume: previewVolume)
    }

    private func cancelPreview() { previewTask?.cancel(); previewTask = nil; preview.stop() }

    private func save() {
        cancelPreview(); exporting = true; message = nil; saved = false
        exportTask = Task {
            defer { exporting = false }
            do {
                let url = try await model.prepare()
                try Task.checkCancellation()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.mpeg4Audio]
                panel.nameFieldStringValue = SongExporter.safeFileBase((request.entry.artist.map { $0 + " - " } ?? "")
                                                                      + (request.entry.title ?? request.entry.raw)) + ".m4a"
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try await SongExporter.savePrepared(url, originalSource: request.source, to: destination)
                if !model.isClosed { saved = true; message = String(localized: "Exportiert.") }
            } catch is CancellationError { }
            catch { if !model.isClosed { message = error.localizedDescription } }
        }
    }
}

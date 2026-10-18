import SwiftUI
import AppKit

struct ExportBatchRequest: Identifiable {
    let id = UUID()
    let jobs: [ExportJob]
    let availableWidth: CGFloat
    let availableHeight: CGFloat
}

struct ExportBatchView: View {
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue: ExportQueue
    @State private var faded = false
    @State private var directory: URL?
    let request: ExportBatchRequest

    init(request: ExportBatchRequest) {
        self.request = request
        _queue = StateObject(wrappedValue: ExportQueue(jobs: request.jobs))
    }

    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label("Mehrere Songs exportieren", systemImage: "square.and.arrow.up.on.square")
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(queue.isRunning).accessibilityIdentifier("batch-close")
            }
            if let directory {
                Text(directory.path).font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(dim).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("batch-directory")
            }
            if queue.didStart {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(queue.finishedCount), total: Double(max(1, queue.items.count)))
                    Text("\(queue.finishedCount) von \(queue.items.count) verarbeitet")
                        .font(theme.font(.label, size: 11 * scale))
                }.accessibilityIdentifier("batch-progress")
            } else {
                Text("\(queue.items.count) Titel · höchstens 100 pro Stapel")
                    .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(queue.items) { item in row(item) }
                }.padding(4)
            }.frame(maxHeight: .infinity).accessibilityIdentifier("batch-list")
            Divider()
            if queue.didStart {
                Text("\(queue.succeededCount) fertig · \(queue.failedCount) fehlgeschlagen · \(queue.cancelledCount) abgebrochen")
                    .font(theme.font(.body, size: 12 * scale))
                    .accessibilityIdentifier("batch-summary")
            } else {
                Text("Der Sender steht im Album-Feld. Ursprünglicher Sendertext und Aufnahmezeit stehen im Kommentar. Vorhandene Dateien werden nicht ersetzt.")
                    .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
            }
            ViewThatFits(in: .horizontal) {
                HStack { fadeControl; Spacer(); queueAction }
                VStack(alignment: .leading, spacing: 8) {
                    fadeControl
                    HStack { Spacer(); queueAction }
                }
            }
        }
        .padding(14).foregroundStyle(ink)
        .frame(width: max(320, min(620, request.availableWidth)),
               height: max(320, min(560, request.availableHeight)))
        .background { SongListSurface() }
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
        .interactiveDismissDisabled(queue.isRunning)
        .onDisappear { queue.cancelAll() }
    }

    @ViewBuilder private var fadeControl: some View {
        if !queue.didStart {
            Toggle("Ein-/Ausblenden", isOn: $faded).toggleStyle(.checkbox)
                .accessibilityIdentifier("batch-fade")
        }
    }

    @ViewBuilder private var queueAction: some View {
        if queue.isRunning {
            Button("Verbleibende abbrechen") { queue.cancelAll() }
                .accessibilityIdentifier("batch-cancel-all")
        } else if !queue.didStart {
            Button("Zielordner wählen …") { chooseDirectory() }
                .disabled(queue.items.isEmpty).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("batch-start")
        }
    }

    private func row(_ item: ExportQueue.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.job.metadata.displayName).font(theme.font(.body, size: 12 * scale))
                    .lineLimit(2).help(item.job.metadata.displayName)
                Text(status(item)).font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(isFailure(item) ? .red : dim).lineLimit(3).help(status(item))
                    .textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.status == .exporting { ProgressView().controlSize(.small) }
            if !item.status.finished {
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help(queue.didStart ? String(localized: "Diesen Export abbrechen") : String(localized: "Diesen Titel überspringen"))
                    .accessibilityLabel(queue.didStart ? String(localized: "Diesen Export abbrechen") : String(localized: "Diesen Titel überspringen"))
                    .accessibilityIdentifier("batch-cancel-\(item.id)")
            }
        }.accessibilityIdentifier("batch-item-\(item.id)")
    }

    private func isFailure(_ item: ExportQueue.Item) -> Bool { if case .failed = item.status { return true }; return false }
    private func status(_ item: ExportQueue.Item) -> String {
        switch item.status {
        case .waiting: return item.job.source == nil ? String(localized: "Keine Aufnahme zu diesem Titel.") : String(localized: "Wartet")
        case .exporting: return String(localized: "Exportiere …")
        case .succeeded(let url): return String(localized: "Gespeichert: \(url.lastPathComponent)")
        case .failed(let error): return error
        case .cancelled: return String(localized: "Abgebrochen")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = String(localized: "Ordner wählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        queue.start(directory: url, mode: faded ? .faded : .hardCut)
    }
}

import SwiftUI
import AppKit

enum MusicRecognitionSymbol {
    // Symbolnamen werden vom Compiler nicht auf der Mindestversion geprüft.
    static let name = NSImage(systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: nil) == nil
        ? "waveform" : "waveform.badge.magnifyingglass"
}

struct MusicRecognitionButton: View {
    @Environment(\.theme) private var theme
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: MusicRecognitionSymbol.name)
                .font(.system(size: 16)).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.palette.textSecondary)
        .help("Musik erkennen").accessibilityLabel("Musik erkennen")
        .accessibilityIdentifier(identifier)
    }
}

struct MusicRecognitionView: View {
    @EnvironmentObject private var recognition: MusicRecognitionService
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    @State private var errorMessage: String?

    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var unavailable: RecognitionFailure? {
        if case .failed(let reason) = recognition.phase, reason == recognition.availability { return nil }
        return recognition.availability
    }
    private var preferredHeight: CGFloat {
        recognition.currentResult == nil ? min(460, 300 * max(1, scale)) : min(600, 460 * max(1, scale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label("Musik erkennen", systemImage: MusicRecognitionSymbol.name)
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 10)
                Button("Schließen") { recognition.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("recognition-close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    if recognition.currentAdoption != nil, recognition.currentResult == nil {
                        Button("Sendertext verwenden") { recognition.useRadioTitle() }
                            .accessibilityIdentifier("recognition-use-radio")
                    }
                    if !recognition.phase.isBusy, let reason = unavailable {
                        Text(reason.localizedDescription).font(theme.font(.body, size: 13 * scale))
                            .accessibilityIdentifier("recognition-unavailable")
                    }
                    Text("Nach „Erkennen“ wird ein Fingerabdruck von bis zu 12 Sekunden der laufenden Musik an Shazam gesendet. Die Audiodatei wird nicht übertragen.")
                        .font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                        .accessibilityIdentifier("recognition-privacy")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                if recognition.phase.isBusy {
                    Button("Abbrechen") { recognition.cancel() }
                        .accessibilityIdentifier("recognition-cancel")
                } else {
                    Button("Erkennen") { recognition.start() }
                        .disabled(recognition.availability != nil)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("recognition-start")
                }
            }
        }
        .padding(16).foregroundStyle(ink)
        .frame(width: max(320, min(560, availableWidth)),
               height: max(280, min(availableHeight, preferredHeight)))
        .background { SongListSurface() }
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
        .onAppear { recognition.refresh() }
        .onDisappear { recognition.cancel() }
        .alert("Merkliste", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private var status: some View {
        switch recognition.phase {
        case .idle:
            Text("Erkenne die Musik des laufenden Senders.")
                .font(theme.font(.body, size: 14 * scale))
                .accessibilityIdentifier("recognition-status")
        case .listening:
            progress(String(localized: "Höre den laufenden Sender …"))
        case .matching:
            progress(String(localized: "Suche bei Shazam …"))
        case .matched(let track):
            VStack(alignment: .leading, spacing: 8) {
                Text("Erkannt").font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                    .accessibilityIdentifier("recognition-status")
                Text(track.title).font(theme.font(.title, size: 20 * scale, weight: .semibold))
                    .textSelection(.enabled).accessibilityIdentifier("recognition-title")
                if !track.artist.isEmpty {
                    Text(track.artist).font(theme.font(.body, size: 15 * scale))
                        .textSelection(.enabled).accessibilityIdentifier("recognition-artist")
                }
                if let url = track.appleMusicURL {
                    Link("In Apple Music öffnen", destination: url)
                        .accessibilityIdentifier("recognition-apple-music")
                }
                if let result = recognition.currentResult {
                    resultActions(result)
                }
            }
        case .noMatch:
            Text("Kein passender Titel gefunden. Versuche einen anderen Ausschnitt.")
                .font(theme.font(.body, size: 14 * scale))
                .accessibilityIdentifier("recognition-status")
        case .cancelled:
            Text("Erkennung abgebrochen.").font(theme.font(.body, size: 14 * scale))
                .accessibilityIdentifier("recognition-status")
        case .failed(let reason):
            Text(reason.localizedDescription).font(theme.font(.body, size: 14 * scale))
                .textSelection(.enabled)
                .accessibilityIdentifier("recognition-status")
        }
    }

    private func resultActions(_ result: RecognitionResult) -> some View {
        let song = result.song(station: player.currentStation?.name ?? "")
        let marked = bookmarks.contains(song)
        let adopted = recognition.currentAdoption == result
        return VStack(alignment: .leading, spacing: 10) {
            Text("Quelle: Shazam").font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                .accessibilityIdentifier("recognition-source")
            Text("Gehört: \(result.capturedAt.formatted(date: .abbreviated, time: .standard))")
                .font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                .accessibilityIdentifier("recognition-heard-at")
            if let received = result.context.listening?.receivedAt {
                Text("Audio empfangen: \(received.formatted(date: .abbreviated, time: .standard))")
                    .font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                    .accessibilityIdentifier("recognition-received-at")
            }
            Text("Sendertext: \(result.context.title.isEmpty ? String(localized: "Kein Sendertext") : result.context.title)")
                .font(theme.font(.body, size: 12 * scale)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recognition-original")
            Text("Katalogtreffer können eine andere Version nennen. Prüfe Titel und Mix vor dem Merken.")
                .font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                recognition.adoptCurrentResult(expected: result)
            } label: {
                Text(adopted ? String(localized: "Für Anzeige übernommen") : String(localized: "Für Anzeige übernehmen"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(adopted).keyboardShortcut(.return, modifiers: .command)
            .help("Für Anzeige übernehmen: ⌘↵").accessibilityIdentifier("recognition-adopt")
            Button {
                guard let current = recognition.currentResult, let station = player.currentStation,
                      station.id == current.context.stationID, current == result else { return }
                do { try bookmarks.add(current.song(station: station.name)) }
                catch { errorMessage = error.localizedDescription }
            } label: {
                Text(marked ? String(localized: "Gemerkt") : String(localized: "Titel merken"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(marked || bookmarks.isReadOnly).keyboardShortcut("s", modifiers: .command)
            .help("Titel merken: ⌘S").accessibilityIdentifier("recognition-bookmark")
            if adopted {
                Button("Sendertext verwenden") { recognition.useRadioTitle() }
                    .accessibilityIdentifier("recognition-use-radio")
            }
            if bookmarks.isReadOnly, let notice = bookmarks.notice {
                Text(notice).font(theme.font(.label, size: 12 * scale)).foregroundStyle(dim)
            }
        }
        .font(theme.font(.body, size: 13 * scale))
    }

    private func progress(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message).font(theme.font(.body, size: 14 * scale))
                .accessibilityIdentifier("recognition-status")
        }
    }
}

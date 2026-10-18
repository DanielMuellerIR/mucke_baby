import SwiftUI
import AppKit

enum PlayerWindowRouter {
    @MainActor static func showMain(open: OpenWindowAction) {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MuckeBabyMain" && ($0.isVisible || $0.isMiniaturized) }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else { open(id: "main-player") }
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject private var player: RadioPlayer
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var startup: StartupSettings
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.openWindow) private var openWindow
    @AppStorage("volume") private var volume = 0.77
    @AppStorage("miniPlayerFloating") private var floating = false
    @State private var quickSelection = false
    private var active: Bool { player.isPlaying || player.isLoading }
    private var current: Station? { store.enabledStations.first { $0.id == player.currentStation?.id } }
    private var normalizedVolume: Double { volume.isFinite ? min(1, max(0, volume)) : 0.77 }
    private var volumeBinding: Binding<Double> {
        Binding(get: { normalizedVolume }, set: { volume = min(1, max(0, $0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 5) {
                Text(player.nowPlayingTitle.isEmpty ? String(localized: "Noch kein Titel") : player.nowPlayingTitle)
                    .font(theme.font(.title, size: 16 * scale, weight: .semibold))
                    .lineLimit(2).textSelection(.enabled).help(player.nowPlayingTitle)
                    .frame(maxWidth: .infinity, minHeight: 40 * scale, alignment: .leading)
                    .accessibilityIdentifier("mini-title")
                Text(player.statusText).font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(theme.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mini-status")
                if let metadataStatus = player.metadataStatus {
                    Text(metadataStatus).font(theme.font(.label, size: 11 * scale))
                        .foregroundStyle(theme.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button {
                    if active { player.stop() }
                    else if let current { player.play(current) }
                } label: {
                    Label(active ? String(localized: "Stopp") : String(localized: "Abspielen"), systemImage: active ? "stop.fill" : "play.fill")
                        .font(theme.font(.label, size: 12 * scale, weight: .semibold))
                        .frame(minWidth: 76, minHeight: 30)
                }
                .buttonStyle(.plain).foregroundStyle(theme.palette.playActive)
                .disabled(!active && current == nil).accessibilityIdentifier("mini-transport")
                Slider(value: volumeBinding, in: 0...1) { Text("Lautstärke") }
                    .labelsHidden().accessibilityLabel("Lautstärke")
                    .accessibilityValue("\(Int(normalizedVolume * 100)) %").accessibilityIdentifier("mini-volume")
                Text("\(Int(normalizedVolume * 100)) %").font(theme.font(.label, size: 10 * scale)).monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                if let song = player.history.entries.last, song.end == nil {
                    BookmarkButton(song: song, identifier: "mini-bookmark")
                } else {
                    Image(systemName: "heart").frame(width: 28, height: 28).foregroundStyle(theme.palette.textDim)
                        .accessibilityLabel("Titel merken").accessibilityIdentifier("mini-bookmark-unavailable")
                }
            }
            RecordingControl(identifier: "mini-recording")
        }
        .padding(16)
        .foregroundStyle(theme.palette.textPrimary)
        .background { ThemedSurface(.window) }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 195)
        .background(MiniWindowConfigurator(floating: floating).frame(width: 0, height: 0))
        .onAppear { applyVolume() }
        .onChange(of: volume) { _, _ in applyVolume() }
        .onChange(of: player.currentStation?.id) { _, id in if let id { startup.rememberStation(id) } }
        .sheet(isPresented: $quickSelection) { StationQuickSelectionView() }
        .focusedSceneValue(\.openStationQuickSelection, { quickSelection = true })
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(store.enabledStations) { station in
                    Button(station.name) { player.play(station) }
                }
                if store.enabledStations.isEmpty { Text("Keine Sender") }
                Divider()
                Button("Sender schnell auswählen …") { quickSelection = true }
            } label: {
                Text(player.currentStation?.name ?? String(localized: "Sender auswählen"))
                    .font(theme.font(.body, size: 12 * scale, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton).accessibilityLabel("Senderauswahl")
            .accessibilityIdentifier("mini-stations")
            AudioSettingsButton()
            Button { floating.toggle() } label: {
                Image(systemName: floating ? "pin.fill" : "pin").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help(floating ? String(localized: "Nicht im Vordergrund halten") : String(localized: "Im Vordergrund halten"))
            .accessibilityLabel("Im Vordergrund halten").accessibilityValue(floating ? String(localized: "Ein") : String(localized: "Aus"))
            .accessibilityIdentifier("mini-floating")
            Button { PlayerWindowRouter.showMain(open: openWindow) } label: {
                Image(systemName: "macwindow").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help("Hauptfenster anzeigen").accessibilityLabel("Hauptfenster anzeigen")
            .accessibilityIdentifier("mini-main")
        }
    }

    private func applyVolume() {
        let value = Float(normalizedVolume)
        player.setVolume(value)
    }
}

private struct MiniWindowConfigurator: NSViewRepresentable {
    var floating: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.configure(view.window, floating: floating) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var screenObserver: NSObjectProtocol?
        func configure(_ window: NSWindow?, floating: Bool) {
            guard let window else { return }
            if self.window !== window {
                stop(); self.window = window
                window.identifier = NSUserInterfaceItemIdentifier("MuckeBabyMini")
                window.setFrameAutosaveName("MuckeBabyMiniPlayer")
                _ = window.setFrameUsingName("MuckeBabyMiniPlayer")
                placeOnScreen()
                screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main) { [weak self] _ in self?.placeOnScreen() }
            }
            window.level = floating ? .floating : .normal
        }
        private func placeOnScreen() {
            guard let window, let frame = MiniWindowPlacement.visibleFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        func stop() {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil; window = nil
        }
        deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    }
}

import SwiftUI
import AppKit

enum VisualizerWindowIdentity: String, Codable, Hashable { case shared }

final class PlayerWindowState: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var isFullScreen = false
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var wantsFullScreen = false
    private var returnAction: (() -> Void)?

    func attach(_ window: NSWindow?) {
        guard let window else { return }
        trace("attach", window: window)
        guard self.window !== window else {
            refresh()
            if wantsFullScreen && window.isVisible { scheduleFullScreen() }
            return
        }
        detach(); self.window = window
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                guard let self else { return }
                self.trace(note.name.rawValue)
                if note.name == NSWindow.willCloseNotification {
                    // SwiftUI kann dasselbe NSWindow erneut öffnen; dessen Beobachter bleiben erhalten.
                    VisualizerRenderTrace.window(self.window, visible: false, fullScreen: false)
                    self.isVisible = false; self.isFullScreen = false
                    self.returnAction = nil; self.wantsFullScreen = false
                } else {
                    if note.name == NSWindow.didEnterFullScreenNotification || note.name == NSWindow.didExitFullScreenNotification,
                       let window = self.window, window.identifier?.rawValue == "MuckeBabyVisualizer" {
                        VisualizerWindowPolicy.configure(window)
                    }
                    self.refresh()
                    if note.name == NSWindow.didExitFullScreenNotification, let action = self.returnAction {
                        self.returnAction = nil; self.window?.close(); action()
                    }
                    if self.wantsFullScreen && self.window?.isVisible == true { self.scheduleFullScreen() }
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
        if wantsFullScreen { scheduleFullScreen() }
    }

    func showFullScreen(open: OpenWindowAction) {
        trace("open-before")
        open(id: "visualizer", value: VisualizerWindowIdentity.shared)
        wantsFullScreen = true
        trace("open-after")
        if let window, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        }
        scheduleFullScreen()
    }

    func toggleFullScreen() {
        guard let window else { return }
        trace("manual-toggle")
        VisualizerWindowPolicy.configure(window)
        window.toggleFullScreen(nil)
    }

    func returnToMain(_ action: @escaping () -> Void) {
        if window?.styleMask.contains(.fullScreen) == true {
            returnAction = action; toggleFullScreen()
        } else { window?.close(); action() }
    }

    func escape(_ action: @escaping () -> Void) {
        if window?.styleMask.contains(.fullScreen) == true { toggleFullScreen() }
        else { returnToMain(action) }
    }

    private func scheduleFullScreen() {
        // SwiftUI muss die Wiederöffnung abschließen, bevor AppKit den Space wechselt.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trace("scheduled-toggle")
            guard self.wantsFullScreen, let window = self.window, window.isVisible else { return }
            self.wantsFullScreen = false
            VisualizerWindowPolicy.configure(window)
            self.trace("configured-toggle")
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    private func trace(_ event: String, window: NSWindow? = nil) {
        VisualizerRenderTrace.event(event, owner: self, window: window ?? self.window, pending: wantsFullScreen)
    }

    private func refresh() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false
        if isVisible != visible { isVisible = visible }
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if isFullScreen != fullScreen { isFullScreen = fullScreen }
        VisualizerRenderTrace.window(window, visible: visible, fullScreen: fullScreen)
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll(); window = nil; isVisible = false; isFullScreen = false
        returnAction = nil
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private enum VisualizerWindowPolicy {
    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("MuckeBabyVisualizer")
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Die primäre Vollbildrolle gilt auch nach einer SwiftUI-Wiederöffnung.
        let behavior = window.collectionBehavior.subtracting([.fullScreenAuxiliary, .fullScreenNone]).union(.fullScreenPrimary)
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
    }
}

struct PlayerWindowObserver: NSViewRepresentable {
    let state: PlayerWindowState
    var visualizer = false
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if visualizer {
                VisualizerWindowPolicy.configure(window)
            }
            state.attach(window)
        }
    }
}

private struct VisualizerRenderingKey: EnvironmentKey { static let defaultValue = true }
private struct VisualizerOwnerKey: EnvironmentKey { static let defaultValue = "main" }
private struct VisualizerMotionFixtureKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var visualizerRenderingEnabled: Bool {
        get { self[VisualizerRenderingKey.self] }
        set { self[VisualizerRenderingKey.self] = newValue }
    }
    var visualizerRenderOwner: String {
        get { self[VisualizerOwnerKey.self] }
        set { self[VisualizerOwnerKey.self] = newValue }
    }
    var visualizerReduceMotionFixture: Bool {
        get { self[VisualizerMotionFixtureKey.self] }
        set { self[VisualizerMotionFixtureKey.self] = newValue }
    }
}

struct VisualizerTimeline<Content: View>: View {
    let isPlaying: Bool
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.visualizerRenderingEnabled) private var enabled
    @Environment(\.visualizerRenderOwner) private var owner
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.visualizerReduceMotionFixture) private var motionFixture
    private var reduceMotion: Bool { systemReduceMotion || motionFixture }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !enabled || !isPlaying || reduceMotion)) { context in
            let _ = VisualizerRenderTrace.frame(owner: owner)
            content(isPlaying && !reduceMotion ? context.date : Date(timeIntervalSinceReferenceDate: 0))
        }
    }
}

enum VisualizerRenderTrace {
    private static let destination = ProcessInfo.processInfo.environment["MUCKE_VISUALIZER_TRACE"].map { URL(fileURLWithPath: $0) }
    private static var frames: [String: Int] = [:]
    private static var windows: [String: [String: Bool]] = [:]
    private static var timer: Timer?
    private static var events: [[String: Any]] = []
    static func event(_ event: String, owner: AnyObject, window: NSWindow?, pending: Bool) {
        guard destination != nil else { return }
        events.append(["event": event, "owner": String(describing: ObjectIdentifier(owner)), "window": window?.windowNumber ?? -1,
                       "visible": window?.isVisible ?? false, "fullScreen": window?.styleMask.contains(.fullScreen) ?? false,
                       "pending": pending, "collectionBehavior": window?.collectionBehavior.rawValue ?? 0,
                       "styleMask": window?.styleMask.rawValue ?? 0, "at": Date().timeIntervalSince1970])
        if events.count > 128 { events.removeFirst(events.count - 128) }
    }
    static func frame(owner: String) {
        guard destination != nil else { return }
        frames[owner, default: 0] += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard let destination, let data = try? JSONSerialization.data(withJSONObject: ["frames": frames, "windows": windows, "events": events, "at": Date().timeIntervalSince1970]) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
    static func window(_ window: NSWindow?, visible: Bool, fullScreen: Bool) {
        guard destination != nil, let window else { return }
        windows[window.identifier?.rawValue ?? window.title] = ["visible": visible, "fullScreen": fullScreen]
    }
}

// Die isolierte native Prüfung kann reduzierte Bewegung ohne Änderung der Systemeinstellung injizieren.
struct VisualizerMotionFixture: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["MUCKE_TEST_OWNER"] != nil && ProcessInfo.processInfo.arguments.contains("-MuckeReduceMotionFixture") {
            content.environment(\.visualizerReduceMotionFixture, true)
        } else { content }
    }
}

struct VisualizerOpenButton: View {
    @ObservedObject var presentation: PlayerWindowState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Visualizer im Vollbild") { presentation.showFullScreen(open: openWindow) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .accessibilityIdentifier("visualizer-open")
    }
}

struct VisualizerWindowView: View {
    @EnvironmentObject private var player: RadioPlayer
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var startup: StartupSettings
    @EnvironmentObject private var recognition: MusicRecognitionService
    @EnvironmentObject private var presentation: PlayerWindowState
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.visualizerReduceMotionFixture) private var motionFixture
    private var reduceMotion: Bool { systemReduceMotion || motionFixture }
    @AppStorage("volume") private var volume = 0.77
    @State private var controlsVisible = true
    private var active: Bool { player.isPlaying || player.isLoading }
    private var current: Station? { store.enabledStations.first { $0.id == player.currentStation?.id } }
    private var title: String {
        if let result = recognition.currentAdoption {
            return [result.track.artist, result.track.title].filter { !$0.isEmpty }.joined(separator: " – ")
        }
        return player.nowPlayingTitle
    }
    private var normalizedVolume: Double { volume.isFinite ? min(1, max(0, volume)) : 0.77 }

    var body: some View {
        VStack(spacing: 0) {
            StageView()
                .environment(\.visualizerRenderingEnabled, presentation.isVisible)
                .environment(\.visualizerRenderOwner, "visualizer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    controlsToggle
                        // Im Vollbild können Menü- und Titelleiste über der Bühne einblenden.
                        .padding(.top, presentation.isFullScreen ? 64 : 12)
                        .padding(.trailing, 12)
                }
            if controlsVisible {
                Rectangle().fill(theme.palette.divider).frame(height: 1)
                controls
            }
        }
        .foregroundStyle(theme.palette.textPrimary)
        .background { ThemedSurface(.window) }
        .frame(minWidth: 440, minHeight: controlsVisible ? max(360, 300 * scale) : 240)
        .background(PlayerWindowObserver(state: presentation, visualizer: true).frame(width: 0, height: 0))
        .onChange(of: player.currentStation?.id) { _, id in if let id { startup.rememberStation(id) } }
        .background {
            Button("") { togglePlayback() }.keyboardShortcut(.space, modifiers: [])
                .opacity(0).accessibilityHidden(true)
            Button("") { presentation.toggleFullScreen() }.keyboardShortcut("f", modifiers: [.control, .command])
                .opacity(0).accessibilityHidden(true)
            Button("") { presentation.escape { PlayerWindowRouter.showMain(open: openWindow) } }
                .keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }

    private var controlsToggle: some View {
        Button { controlsVisible.toggle() } label: {
            Image(systemName: controlsVisible ? "eye.slash" : "eye").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(theme.palette.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .help(controlsVisible ? String(localized: "Bedienung ausblenden") : String(localized: "Bedienung einblenden"))
        .accessibilityLabel(controlsVisible ? String(localized: "Bedienung ausblenden") : String(localized: "Bedienung einblenden"))
        .accessibilityIdentifier("visualizer-controls-toggle")
        .keyboardShortcut("b", modifiers: .command)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.isEmpty ? String(localized: "Noch kein Titel") : title)
                .font(theme.font(.title, size: 22 * scale, weight: .semibold))
                .lineLimit(2).textSelection(.enabled).help(title)
                .accessibilityIdentifier("visualizer-title")
            Text(player.currentStation?.name ?? String(localized: "Kein Sender ausgewählt"))
                .font(theme.font(.body, size: 13 * scale)).foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2).accessibilityIdentifier("visualizer-station")
            if recognition.currentAdoption != nil {
                Text("Shazam").font(theme.font(.label, size: 11 * scale)).foregroundStyle(theme.palette.textSecondary)
                    .accessibilityIdentifier("visualizer-source")
                Text("Sendertext: \(player.nowPlayingTitle.isEmpty ? String(localized: "Kein Sendertext") : player.nowPlayingTitle)")
                    .font(theme.font(.label, size: 11 * scale)).foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2).help(player.nowPlayingTitle)
            }
            Text(player.statusText)
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(theme.palette.textSecondary)
                .accessibilityIdentifier("visualizer-status")
            if reduceMotion {
                Text("Bewegung reduziert").font(theme.font(.label, size: 11 * scale))
                    .foregroundStyle(theme.palette.textSecondary).accessibilityIdentifier("visualizer-reduce-motion")
            }
            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Label(active ? String(localized: "Stopp") : String(localized: "Abspielen"), systemImage: active ? "stop.fill" : "play.fill")
                        .font(theme.font(.label, size: 12 * scale, weight: .semibold)).frame(minWidth: 80, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(theme.palette.playActive)
                .disabled(!active && current == nil).accessibilityIdentifier("visualizer-transport")
                Slider(value: Binding(get: { normalizedVolume }, set: { volume = min(1, max(0, $0)); player.setVolume(Float(volume)) }), in: 0...1) { Text("Lautstärke") }
                    .labelsHidden().accessibilityLabel("Lautstärke").accessibilityIdentifier("visualizer-volume")
                Text("\(Int(normalizedVolume * 100)) %").font(theme.font(.label, size: 11 * scale)).monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Button { presentation.returnToMain { PlayerWindowRouter.showMain(open: openWindow) } } label: {
                    Label("Hauptfenster anzeigen", systemImage: "macwindow").font(theme.font(.label, size: 11 * scale)).frame(minHeight: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("visualizer-main")
                .keyboardShortcut(.return, modifiers: .command)
                Spacer()
                Button { presentation.toggleFullScreen() } label: {
                    Image(systemName: presentation.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(presentation.isFullScreen ? String(localized: "Vollbild beenden") : String(localized: "Vollbild"))
                .accessibilityLabel(presentation.isFullScreen ? String(localized: "Vollbild beenden") : String(localized: "Vollbild"))
                .accessibilityIdentifier("visualizer-fullscreen")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.panelBackground)
    }

    private func togglePlayback() {
        if active { player.stop() }
        else if let current { player.play(current) }
    }
}

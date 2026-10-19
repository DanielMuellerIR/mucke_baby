import AppKit
import SwiftUI
import MediaPlayer
import Combine
import VLCKit

// Isolierter LaunchServices-Prüfhost mit den unveränderten Produktansichten.
@main @MainActor final class TimeshiftTransportProbe: NSObject, NSApplicationDelegate {
    var root: URL!
    var player: RadioPlayer!
    var store: Store!
    var startup: StartupSettings!
    var bookmarks: BookmarkStore!
    var settings: AudioSettingsStore!
    var recognition: MusicRecognitionService!
    var media: SystemMediaBinding!
    let capacity = TimeshiftTestCapacity()
    let tap = AudioTap()
    let health = StationHealth(probe: { _ in .ok })
    let visualizer = PlayerWindowState()
    var mainWindow: NSWindow!
    var miniWindow: NSWindow!
    var observations: [[String: Any]] = []
    var recognitionOutput: TimeshiftRecognitionOutput?
    var recognitionMatcher: TimeshiftRecognitionMatcher?
    var recognitionSubscriptions = Set<AnyCancellable>()

    static func main() {
        let delegate = TimeshiftTransportProbe(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            root = URL(fileURLWithPath: CommandLine.arguments[1])
            let url = URL(string: CommandLine.arguments[2])!
            try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("app.pid"))
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            let captureRoot = root!
            let capacity = self.capacity
            if ProcessInfo.processInfo.environment["MUCKE_RECOGNITION_TRANSPORT"] == "1" {
                recognitionOutput = TimeshiftRecognitionOutput(root: root)
            }
            let output = recognitionOutput
            player = RadioPlayer(makePlayer: { output?.makePlayer() ?? VLCMediaPlayer() }, recorder: Recorder(directory: root.appendingPathComponent("recordings"),
                availableCapacity: { capacity.available(at: captureRoot) }, capacityCheckInterval: 0.2),
                history: SongHistory(directory: root.appendingPathComponent("history")), timeshiftRoot: root.appendingPathComponent("buffers"),
                makeTimeshiftBuffer: { try TimeshiftSegments(root: captureRoot.appendingPathComponent("buffers"),
                    limits: TimeshiftSegmentLimits(duration: output == nil ? 300 : 60),
                    freeBytes: { capacity.available(at: $0) }) })
            store = Store(directory: root.appendingPathComponent("store"), seedURL: nil)
            let station = Station(name: url.lastPathComponent == "aac" ? "Fixture • AAC" : "Fixture • MP3", url: url.absoluteString)
            let stationData = try JSONEncoder().encode([station])
            try stationData.write(to: store.stationsURL)
            store.loadStations()
            startup = StartupSettings(directory: store.dir, stations: store.stations)
            _ = startup.claimAutoplay()
            bookmarks = BookmarkStore(directory: store.dir)
            settings = AudioSettingsStore(directory: store.dir)
            if let output {
                let matcher = TimeshiftRecognitionMatcher(root: root)
                recognitionMatcher = matcher
                recognition = MusicRecognitionService(capture: output.capture, sampleRate: { 48_000 },
                    context: { [weak player] in player?.recognitionContext }, volume: { 1 }, matcher: matcher,
                    captureWait: ProcessInfo.processInfo.environment["MUCKE_RECOGNITION_DIRECT_ONLY"] == "1" ? 12 : 5, timeout: 30)
                player.objectWillChange.sink { [weak recognition] in
                    Task { @MainActor in recognition?.refresh() }
                }.store(in: &recognitionSubscriptions)
            } else {
                recognition = MusicRecognitionService(capture: tap.recognitionCapture, sampleRate: { nil },
                    context: { [weak player] in player?.recognitionContext }, volume: { 0 }, matcher: ShazamRecognitionClient())
            }
            media = SystemMediaBinding(player: player, store: store)
            mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            mainWindow.title = "Mucke, Baby! — Transport"
            miniWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            miniWindow.title = "Mucke, Baby! — Mini"
            install(theme: .schlicht, width: 940, dark: false)
            player.setVolume(output == nil ? 0 : 0.77); player.setRecordingRequested(true); player.setTimeshiftRequested(true)
            player.play(station)
            mainWindow.center(); mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            Task { do { try await run() } catch { try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("failure.txt")) }; NSApp.terminate(nil) }
        } catch { fatalError("Probe: \(error)") }
    }

    func environment<V: View>(_ view: V, theme: ThemeID, dark: Bool) -> some View {
        view.environmentObject(player).environmentObject(store).environmentObject(startup).environmentObject(bookmarks)
            .environmentObject(player.history).environmentObject(tap).environmentObject(health).environmentObject(recognition)
            .environmentObject(visualizer).environmentObject(settings)
            .environment(\.theme, Theme.theme(raw: theme.rawValue)).preferredColorScheme(Theme.theme(theme).colorScheme ?? (dark ? .dark : .light))
    }
    func install(theme: ThemeID, width: Double, dark: Bool) {
        mainWindow.contentView = NSHostingView(rootView: environment(ContentView(), theme: theme, dark: dark))
        mainWindow.setContentSize(NSSize(width: width, height: 620))
        miniWindow.contentView = NSHostingView(rootView: environment(MiniPlayerView(), theme: theme, dark: dark))
        miniWindow.setContentSize(NSSize(width: 420, height: 390))
    }
    func shot(_ name: String, mini: Bool = false) throws {
        let view = (mini ? miniWindow : mainWindow).contentView!
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    }
    func record(_ name: String) throws {
        let transport = player.timeshiftTransport
        observations.append(["stage": name, "at": Date().timeIntervalSince1970, "position": transport.position,
            "oldest": transport.timeline.oldest, "live": transport.timeline.live, "title": player.nowPlayingTitle,
            "playing": player.isPlaying, "paused": player.isPaused, "phase": String(describing: transport.phase),
            "history": player.history.entries.count, "recording": String(describing: player.recordingState.phase),
            "systemTitle": MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] ?? "",
            "systemState": MPNowPlayingInfoCenter.default().playbackState.rawValue])
        if recognitionOutput != nil {
            observations[observations.count - 1]["status"] = player.statusText
            observations[observations.count - 1]["metadata"] = player.metadataStatus ?? ""
            observations[observations.count - 1]["recognition"] = String(describing: recognition.phase)
            observations[observations.count - 1]["vlcState"] = String(describing: recognitionOutput?.latest?.state)
            observations[observations.count - 1]["vlcTime"] = recognitionOutput?.latest?.time.intValue
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("observations.json"), options: .atomic)
    }
    func mark(_ name: String) throws { try Data(name.utf8).write(to: root.appendingPathComponent(name + ".txt")) }
    func wait(seconds: Double = 40, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "TimeshiftTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zustand fehlt"])
    }
    func run() async throws {
        if recognitionOutput != nil { try await runRecognition(); return }
        if ProcessInfo.processInfo.environment["MUCKE_TRANSPORT_INTEGRATION"] == "1" {
            try await runIntegration(); return
        }
        try await wait { self.player.isPlaying && self.player.timeshiftTransport.timeline.live > 12 }
        try record("ready")
        for theme in ThemeID.allCases {
            for width in [940.0, 660.0] {
                for dark in [false, true] {
                    install(theme: theme, width: width, dark: dark)
                    try await Task.sleep(for: .milliseconds(180))
                    try shot("\(theme.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
        install(theme: .schlicht, width: 660, dark: false)
        mainWindow.orderOut(nil); miniWindow.center(); miniWindow.makeKeyAndOrderFront(nil)
        try mark("mini-ready")
        try await wait { self.player.isPaused }
        try await Task.sleep(for: .milliseconds(300))
        let position = player.timeshiftTransport.position, title = player.nowPlayingTitle
        try record("paused"); try shot("mini-paused", mini: true); try mark("paused")
        try await Task.sleep(for: .seconds(3))
        precondition(player.isPaused && player.timeshiftTransport.position == position && player.nowPlayingTitle == title)
        try mark("seek-ready")
        try await wait { self.player.timeshiftTransport.position < position - 10 }
        precondition(player.isPaused)
        try record("sought-paused"); try shot("mini-sought", mini: true); try mark("sought")
        let anchor = player.timeshiftTransport.timeline.anchor(at: player.timeshiftTransport.position)
        precondition(player.currentSong?.start == anchor?.receivedAt, "Merkliste verwendet späteren Empfangstitel")
        try await wait { self.player.isPlaying }
        try record("resumed"); try mark("resumed")
        try await wait { self.player.timeshiftTransport.phase == .live }
        try await Task.sleep(for: .seconds(3))
        try record("live"); try shot("mini-live", mini: true); try mark("live")
        if ProcessInfo.processInfo.environment["MUCKE_TRANSPORT_QUICK"] == "1" {
            let beforeSlider = player.timeshiftTransport.position
            try await wait { self.player.timeshiftTransport.position < beforeSlider - 5 && self.player.isPlaying }
            try record("slider-sought"); try mark("slider-sought")
            try await wait { self.player.isPaused }
            try await Task.sleep(for: .milliseconds(300))
            try record("media-key-paused"); try mark("media-key-paused")
            try await wait { self.player.isPlaying }
            try await Task.sleep(for: .milliseconds(300))
            try record("media-key-resumed"); try mark("media-key-resumed")
            try await wait { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("keys-done.txt").path) }
            capacity.setLow(true)
            try await wait { self.player.recordingState.phase == .lowDisk && !self.player.isPlaying }
            try await Task.sleep(for: .milliseconds(500))
            try record("quick-low-disk"); try shot("mini-low-disk", mini: true)
            player.stop(); try mark("passed"); return
        }
        // Deckt auch den normalen 30-s-Watchdog und das volle Produktionslimit ab.
        try await wait { self.player.isPaused }
        try record("long-pause"); try mark("long-pause")
        try await wait(seconds: 330) { self.player.timeshiftTransport.phase == .expired }
        precondition(!player.isPlaying && player.hasPlaybackIntent && player.recordingRequested)
        try record("expired"); try shot("mini-expired", mini: true); try mark("expired")
        try await wait { self.player.isPlaying }
        try record("live-after-expired")
        player.play(Station(name: "Fixture B", url: CommandLine.arguments[2]))
        try await wait { self.player.isPlaying && self.player.timeshiftTransport.timeline.live > 4 }
        try record("station-change")
        player.setTimeshiftRequested(false)
        try await wait { self.player.isPlaying }
        precondition(player.recordingRequested)
        try record("disabled")
        try mark("passed")
    }
    func applicationWillTerminate(_ notification: Notification) {
        media?.shutdown(); player?.stop(); player?.recorder.flush(); mainWindow?.orderOut(nil); miniWindow?.orderOut(nil)
    }
}

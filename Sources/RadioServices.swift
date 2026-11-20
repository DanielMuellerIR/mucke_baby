import AppKit
import Combine

// Eine gemeinsame, verzögert erzeugte Abhängigkeitskette für Fenster und Menüleiste.
@MainActor
final class RadioServices {
    static let shared = RadioServices()
    let store: Store
    let bookmarks: BookmarkStore
    let startup: StartupSettings
    let player: RadioPlayer
    let systemMedia: SystemMediaBinding
    let audioSettings: AudioSettingsStore
    let audioTap: AudioTap
    let recognition: MusicRecognitionService
    private var subscriptions = Set<AnyCancellable>()
    private var recognitionRefreshPending = false
    init() {
        let store = Store()
        let player = RadioPlayer()
        self.store = store
        self.player = player
        bookmarks = BookmarkStore(directory: store.dir)
        let audioSettings = AudioSettingsStore(directory: store.dir)
        let audioTap = AudioTap()
        self.audioSettings = audioSettings
        self.audioTap = audioTap
        recognition = MusicRecognitionService(capture: audioTap.recognitionCapture,
            sampleRate: { [weak audioTap] in audioTap?.captureSampleRate },
            context: { [weak player] in player?.recognitionContext },
            volume: { [weak player] in player?.effectiveOutputVolume ?? 0 },
            matcher: ShazamRecognitionClient())
        startup = StartupSettings(directory: store.dir, stations: store.stations)
        let volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.77
        player.setVolume(Float(volume))
        systemMedia = SystemMediaBinding(player: player, store: store)
        audioSettings.$configuration.sink { [weak player] in player?.configureAudio($0) }.store(in: &subscriptions)
        player.$effectiveOutputVolume.removeDuplicates()
            .sink { [weak audioTap] in audioTap?.setOutputVolume($0) }.store(in: &subscriptions)
        player.$currentStreamURL.removeDuplicates()
            .sink { [weak audioTap] in audioTap?.setStream($0) }.store(in: &subscriptions)
        let recognitionChanges: [AnyPublisher<Void, Never>] = [
            player.$outputRevision.map { _ in () }.eraseToAnyPublisher(),
            player.$currentStreamURL.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$effectiveOutputVolume.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.timeshiftPresentation.$transport
                .map { [weak player] transport in player?.hasRecognitionTimestamp(for: transport) == true }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            audioTap.objectWillChange.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(recognitionChanges)
            .sink { [weak self] in self?.scheduleRecognitionRefresh() }.store(in: &subscriptions)
        // Auch ohne offenes Hauptfenster müssen Empfang, Dateien und Verlauf vor Quit schließen.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.recognition.cancel()
                self.player.stop()
                self.audioTap.stop()
                self.player.recorder.flush()
                self.player.history.pruneOnLaunchOrQuit()
                SongExporter.cleanupTemporaryExports()
            }.store(in: &subscriptions)
    }

    private func scheduleRecognitionRefresh() {
        guard !recognitionRefreshPending else { return }
        recognitionRefreshPending = true
        // @Published meldet den neuen Wert vor der Zuweisung. Kontext danach zusammen lesen.
        Task { @MainActor [weak self] in
            guard let self else { return }
            recognitionRefreshPending = false
            recognition.refresh()
        }
    }
}

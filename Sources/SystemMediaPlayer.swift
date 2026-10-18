import AppKit
import Combine
import MediaPlayer

@MainActor
private final class MediaPlayerBackend: SystemMediaBackend {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var targets: [(MPRemoteCommand, Any)] = []
    func setHandler(_ handler: (@Sendable (SystemMediaAction) -> Bool)?) {
        for (command, target) in targets { command.removeTarget(target); command.isEnabled = false }
        targets.removeAll()
        guard let handler else { return }
        for (command, action) in [(commands.playCommand, SystemMediaAction.play),
                                  (commands.pauseCommand, .pause), (commands.stopCommand, .stop),
                                  (commands.togglePlayPauseCommand, .toggle),
                                  (commands.previousTrackCommand, .previous), (commands.nextTrackCommand, .next)] {
            command.isEnabled = true
            let target = command.addTarget { _ in handler(action) ? .success : .noSuchContent }
            targets.append((command, target))
        }
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.changePlaybackRateCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false; commands.skipBackwardCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false; commands.seekBackwardCommand.isEnabled = false
    }
    func publish(_ info: SystemMediaInfo) {
        let title = info.title == info.station ? info.title : info.station + " — " + info.title
        var values: [String: Any] = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: info.station,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0]
        if let artist = info.artist { values[MPMediaItemPropertyArtist] = artist }
        center.nowPlayingInfo = values
    }
    func setPlaybackState(_ state: SystemMediaPlaybackState) {
        center.playbackState = state == .playing ? .playing : (state == .paused ? .paused : .interrupted)
    }
    func setNavigationEnabled(_ enabled: Bool) {
        commands.previousTrackCommand.isEnabled = enabled; commands.nextTrackCommand.isEnabled = enabled
    }
    func clear() { center.nowPlayingInfo = nil; center.playbackState = .stopped }
}

@MainActor
final class SystemMediaBinding {
    private let player: RadioPlayer
    private let store: Store
    private var coordinator: SystemMediaCoordinator!
    private var subscriptions = Set<AnyCancellable>()
    private var pending = false
    private var ended = false
    init(player: RadioPlayer, store: Store) {
        self.player = player; self.store = store
        coordinator = SystemMediaCoordinator(backend: MediaPlayerBackend()) { [weak player, weak store] action, station in
            guard let player else { return }
            switch action {
            case .stop: player.stop()
            case .pause:
                if player.canPause { player.pause() } else if !player.isPaused { player.stop() }
            case .toggle:
                if player.isPaused { player.resume() }
                else if player.timeshiftTransport.phase == .expired { player.returnToLive() }
                else if player.canPause { player.pause() }
                else { player.stop() }
            case .play:
                if player.isPaused { player.resume() }
                else if player.timeshiftTransport.phase == .expired { player.returnToLive() }
                else if let station { player.play(station) }
            case .previous, .next:
                if let station { player.play(store?.stations.first(where: { $0.id == station.id }) ?? station) }
            }
        }
        let changes: [AnyPublisher<Void, Never>] = [
            player.$currentStation.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            player.$isLoading.map { _ in () }.eraseToAnyPublisher(),
            player.$nowPlayingTitle.map { _ in () }.eraseToAnyPublisher(),
            player.$statusText.map { _ in () }.eraseToAnyPublisher(),
            player.$timeshiftTransport.map(\.phase).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$stations.map { _ in () }.eraseToAnyPublisher()]
        Publishers.MergeMany(changes).sink { [weak self] in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }.store(in: &subscriptions)
    }
    private func schedule() {
        guard !ended else { return }
        // Sofort sperren, auch wenn mehrere Published-Werte erst gemeinsam übernommen werden.
        coordinator.invalidatePendingCommands()
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.ended else { return }
            self.pending = false
            self.coordinator.apply(SystemMediaSnapshot(station: self.player.currentStation,
                playing: self.player.isPlaying, loading: self.player.isLoading,
                paused: self.player.timeshiftTransport.holdsPlayback, canPause: self.player.canPause,
                title: self.player.nowPlayingTitle, status: self.player.statusText, stations: self.store.stations))
        }
    }
    func shutdown() { ended = true; coordinator.deactivate(); subscriptions.removeAll() }
}

// Eine gemeinsame, verzögert erzeugte Abhängigkeitskette für Fenster und Menüleiste.
@MainActor
final class RadioServices: @preconcurrency ObservableObject {
    static let shared = RadioServices()
    let objectWillChange = ObservableObjectPublisher()
    let store: Store
    let bookmarks: BookmarkStore
    let startup: StartupSettings
    let player: RadioPlayer
    let systemMedia: SystemMediaBinding
    let audioSettings: AudioSettingsStore
    let audioTap: AudioTap
    let recognition: MusicRecognitionService
    private var subscriptions = Set<AnyCancellable>()
    init() {
        let store = Store(), player = RadioPlayer()
        self.store = store; self.player = player; bookmarks = BookmarkStore(directory: store.dir)
        let audioSettings = AudioSettingsStore(directory: store.dir), audioTap = AudioTap()
        self.audioSettings = audioSettings; self.audioTap = audioTap
        recognition = MusicRecognitionService(capture: audioTap.recognitionCapture,
            sampleRate: { [weak audioTap] in audioTap?.captureSampleRate },
            context: { [weak player] in player?.recognitionContext },
            volume: { [weak player] in player?.effectiveOutputVolume ?? 0 },
            matcher: ShazamRecognitionClient())
        startup = StartupSettings(directory: store.dir, stations: store.stations)
        let volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.77
        player.setVolume(Float(volume))
        systemMedia = SystemMediaBinding(player: player, store: store)
        Publishers.Merge3(store.objectWillChange, startup.objectWillChange, player.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        audioSettings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        audioSettings.$configuration.sink { [weak player] in player?.configureAudio($0) }.store(in: &subscriptions)
        player.$effectiveOutputVolume.removeDuplicates()
            .sink { [weak audioTap] in audioTap?.setOutputVolume($0) }.store(in: &subscriptions)
        player.$currentStreamURL.removeDuplicates()
            .sink { [weak audioTap] in audioTap?.setStream($0) }.store(in: &subscriptions)
        Publishers.Merge(player.objectWillChange, audioTap.objectWillChange)
            .sink { [weak recognition] in
                // @Published sendet vor der Änderung; Kontext erst danach lesen.
                Task { @MainActor in recognition?.refresh() }
            }.store(in: &subscriptions)
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
}

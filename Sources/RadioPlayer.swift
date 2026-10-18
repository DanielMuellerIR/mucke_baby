import Foundation
import AppKit
import VLCKit
import Network
import os

private let log = Logger(subsystem: "de.danielmuller.macradio", category: "player")

// Delegate-Bruecke: VLCKit ruft ObjC-Delegate-Methoden auf. Diese kleine
// NSObject-Klasse faengt sie ab und leitet sie als Closures auf den Main-Thread.
final class PlayerDelegateShim: NSObject, VLCMediaPlayerDelegate {
    // Jede Bruecke gehoert genau einer VLC-Instanz und einer Wiedergabe.
    // Die Closures bleiben unveraendert, auch wenn ein Ereignis auf Main wartet.
    let onState: (VLCMediaPlayerState) -> Void
    let onTime: () -> Void

    init(onState: @escaping (VLCMediaPlayerState) -> Void, onTime: @escaping () -> Void) {
        self.onState = onState
        self.onTime = onTime
        super.init()
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // VLCKit liefert die betroffene Instanz als Notification-Objekt. Den
        // Zustand jetzt sichern: bis zur Main-Queue kann .error bereits von
        // .stopped abgeloest sein, wodurch der Fehlerhinweis verloren ginge.
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        let state = player.state
        DispatchQueue.main.async { self.onState(state) }
    }
    // Zeit laeuft -> zuverlaessiges "spielt jetzt"-Signal (state bleibt bei
    // Live-Streams oft auf .buffering haengen).
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { self.onTime() }
    }
}

// Kapselt VLCMediaPlayer (libVLC, spielt ALLE Codecs) plus einen eigenen
// ICY-Metadaten-Reader fuer den Now-Playing-Titel (VLCKit liefert den nicht).
@MainActor
final class RadioPlayer: ObservableObject {
    @Published private(set) var currentStation: Station?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = String(localized: "Bereit")
    @Published private(set) var nowPlayingTitle = ""
    // B2: Zeitpunkt, ab dem der aktuelle Sender wirklich spielt (erstes Audio).
    // Footer zeigt daraus die laufende Sender-Laufzeit. nil = spielt nicht.
    @Published private(set) var playStartedAt: Date?
    // Aufgelöste Direkt-Stream-URL des laufenden Senders. Der AudioTap dekodiert NICHT parallel;
    // er nutzt diese Published-URL nur als Start/Stop-Signal und tappt dann die Prozessausgabe.
    @Published private(set) var currentStreamURL: URL?
    @Published private(set) var effectiveOutputVolume = AudioConfiguration.outputAmplitude(forVLCVolume: 77)
    @Published private(set) var audioNotice: String?

    let sleepTimer: SleepTimerController
    let history = SongHistory()
    let recorder: Recorder
    @Published private(set) var recordingRequested: Bool
    private let preferences: UserDefaults
    @Published private(set) var recordingState = RecordingState()
    private var recordingRevision: UInt64 = 0
    private var recordingSegmentID: UUID?

    private var player: VLCMediaPlayer
    private let makePlayer: () -> VLCMediaPlayer
    private var shim: PlayerDelegateShim?
    private let icy = ICYMetadataReader()
    private var desiredVolume: Float = 0.77
    private var audioConfiguration = AudioConfiguration()
    private var installedStationID: UUID?
    private var lastState: VLCMediaPlayerState?
    private var resolveTask: Task<Void, Never>?
    private var requests = LatestRequestGeneration()
    private var installedGeneration: UInt64 = 0
    private var recordingSessionID = UUID()
    private let reconnect: PlaybackReconnect
    @Published private(set) var metadataStatus: String?
    private let metadataReconnect: PlaybackReconnect
    private var metadataGeneration: UInt64 = 0
    private var metadataActivityUptime: TimeInterval = 0
    private var sleepingStationID: UUID?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var systemObservers: [NSObjectProtocol] = []
    private var desiredStation: Station?
    private var networkMonitor: NWPathMonitor?
    private var networkToken = UUID()

    var recognitionContext: RecognitionContext? {
        guard isPlaying, let station = currentStation, currentStreamURL != nil else { return nil }
        return RecognitionContext(generation: requests.current, stationID: station.id, title: nowPlayingTitle)
    }

    init(reconnect: PlaybackReconnect? = nil, makePlayer: @escaping () -> VLCMediaPlayer = { VLCMediaPlayer() }, recorder: Recorder = Recorder(), preferences: UserDefaults = .standard, metadataReconnect: PlaybackReconnect? = nil, sleepTimer: SleepTimerController? = nil) {
        self.sleepTimer = sleepTimer ?? SleepTimerController()
        self.preferences = preferences
        self.recordingRequested = preferences.object(forKey: "recordStreams") as? Bool ?? false
        self.recorder = recorder
        self.makePlayer = makePlayer
        self.player = makePlayer()
        self.reconnect = reconnect ?? PlaybackReconnect()
        self.metadataReconnect = metadataReconnect ?? PlaybackReconnect()
        let reconnect = self.reconnect
        // codereview-ok: icy/recorder sind app-lebenslange Member mit [weak self]-Closures — kein Retain-Cycle/Leak (2026-07-01)
        icy.onTitle  = { [weak self] title, boundary in self?.setNowPlaying(title, at: boundary) }
        recorder.onCaptureState = { [weak self] state in self?.captureStateChanged(state) }
        resetCapture()
        self.sleepTimer.onFadeChange = { [weak self] _ in
            guard let self, self.desiredStation != nil else { return }
            self.applyOutputVolume()
        }
        self.sleepTimer.onExpire = { [weak self] in self?.stop() }
        reconnect.onRetry = { [weak self] id in
            guard let self, let station = self.desiredStation, station.id == id else { return }
            self.startAttempt(station)
        }
        reconnect.onTimeout = { [weak self] in self?.attemptFailed() }
        reconnect.onChange = { [weak self] phase in self?.reconnectPhaseChanged(phase) }
        self.metadataReconnect.onRetry = { [weak self] id in
            guard let self, self.desiredStation?.id == id, let url = self.currentStreamURL else { return }
            self.startMetadata(url: url, retry: true)
        }
        self.metadataReconnect.onTimeout = { [weak self] in self?.metadataEnded(at: Date()) }
        self.metadataReconnect.onChange = { [weak self] phase in self?.metadataPhaseChanged(phase) }
        systemObservers = [
            workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.prepareForSleep() }
            },
            workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeAfterWake() }
            }]
    }

    deinit { for observer in systemObservers { workspaceNotifications.removeObserver(observer) } }

    func prepareForSleep() {
        guard sleepingStationID == nil, let desiredStation else { return }
        sleepingStationID = desiredStation.id
        reconnect.cancel(); stopMonitoringNetwork(); stopAttempt()
        nowPlayingTitle = ""; statusText = String(localized: "Wiedergabe ruht bis zum Aufwachen.")
    }

    func resumeAfterWake() {
        guard let id = sleepingStationID else { return }
        sleepingStationID = nil
        sleepTimer.refresh()
        guard let station = desiredStation, station.id == id else { return }
        play(station)
    }

    func setRecordingRequested(_ enabled: Bool) {
        guard enabled != recordingRequested else { return }
        recordingRequested = enabled
        preferences.set(enabled, forKey: "recordStreams")
        recordingRevision &+= 1
        recorder.setCaptureEnabled(enabled, revision: recordingRevision)
    }

    private func resetCapture(at date: Date = Date()) {
        recordingRevision &+= 1
        recordingSegmentID = nil
        recordingState = RecordingState(phase: recordingRequested ? .waiting : .off, revision: recordingRevision)
        recorder.clearCapture(enabled: recordingRequested, revision: recordingRevision, at: date)
    }

    private func captureStateChanged(_ state: RecordingState) {
        guard state.revision == recordingRevision else { return }
        guard state.streamID == nil || state.streamID == recordingSessionID else { return }
        recordingState = state
        if let rollover = state.rollover {
            // Der Status kann den normalen Titelcallback überholen. Die erkannte
            // Grenze gehört noch zum alten Abschnitt; erst danach ICY erneuern.
            history.closeCurrent(at: rollover.receivedAt)
            recordingSegmentID = nil
            setNowPlaying(rollover.title, at: rollover.receivedAt)
        }
        if state.phase == .needsStreamHeader, recordingRequested, state.streamID == recordingSessionID,
           let url = currentStreamURL {
            startMetadata(url: url)
            return
        }
        if state.phase == .recording, let id = state.segmentID, recordingSegmentID != id,
           state.streamID == recordingSessionID, let station = currentStation, let startedAt = state.startedAt {
            recordingSegmentID = id
            let entry = history.entries.last
            let date = entry?.end == nil && entry?.station == station.name
                ? max(startedAt, entry?.start ?? startedAt) : startedAt
            if nowPlayingTitle.isEmpty { history.beginSession(station: station.name, at: date, sessionID: id) }
            else { history.note(station: station.name, raw: nowPlayingTitle, at: date, sessionID: id) }
        } else if state.phase != .recording, recordingSegmentID != nil {
            recordingSegmentID = nil
            history.closeCurrent()
            if currentStreamURL != nil, let station = currentStation, !nowPlayingTitle.isEmpty {
                history.note(station: station.name, raw: nowPlayingTitle, sessionID: recordingSessionID)
            }
        }
    }

    // Lautstaerke 0.0 … 1.0  (VLC-Skala: 0…100, 100 = Originalpegel)
    func setVolume(_ v: Float) {
        desiredVolume = v.isFinite ? max(0, min(1, v)) : 0
        applyOutputVolume()
    }

    func configureAudio(_ configuration: AudioConfiguration) {
        guard configuration.isValid else { return }
        audioConfiguration = configuration
        applyAudioSettings()
    }

    private func applyOutputVolume() {
        let base = audioConfiguration.quantizedOutputVolume(desiredVolume, stationID: installedStationID)
        // VLC skaliert kubisch. Der flüchtige Faktor blendet die Amplitude aus,
        // ohne die persönliche Reglerstellung oder Senderkorrektur zu speichern.
        let volume = Int32((Double(base) * pow(sleepTimer.fadeFactor, 1.0 / 3.0)).rounded())
        player.audio?.volume = volume
        effectiveOutputVolume = AudioConfiguration.outputAmplitude(forVLCVolume: volume)
    }

    private func applyAudioSettings() {
        applyOutputVolume()
        guard audioConfiguration.equalizerEnabled else {
            player.equalizer = nil; audioNotice = nil
            return
        }
        let equalizer = VLCAudioEqualizer()
        guard equalizer.bands.count == audioConfiguration.bands.count else {
            player.equalizer = nil
            audioNotice = String(localized: "Der Equalizer ist mit dieser Audiobibliothek nicht verfügbar.")
            return
        }
        equalizer.preAmplification = Float(audioConfiguration.vlcPreampDB)
        for (band, value) in zip(equalizer.bands, audioConfiguration.bands) { band.amplification = Float(value) }
        // VLCKit übernimmt die Werte beim Zuweisen; Änderungen am alten Objekt
        // allein würden einen bereits laufenden Audioausgang nicht aktualisieren.
        player.equalizer = equalizer; audioNotice = nil
    }

    // Sender abspielen. Zuerst evtl. Playlist (.pls/.m3u/Tune.ashx) zur
    // Direkt-URL aufloesen — VLCMediaPlayer spielt Playlist-Container nicht
    // selbst ab. Codec/Redirect uebernimmt dann VLC.
    func play(_ station: Station) {
        sleepTimer.refresh()
        sleepingStationID = nil
        desiredStation = station
        reconnect.beginIntent(stationID: station.id)
        monitorNetwork()
        startAttempt(station)
    }

    private func startAttempt(_ station: Station) {
        sleepTimer.refresh()
        guard desiredStation?.id == station.id else { return }
        let capturedEnd = stopMetadata()
        history.closeCurrent(at: capturedEnd ?? Date())
        resetCapture(at: capturedEnd ?? Date())
        resolveTask?.cancel()
        resolveTask = nil
        let generation = requests.begin()
        recordingSessionID = UUID()

        currentStation = station
        currentStreamURL = nil      // Wechselfenster: alte Stream-URL sofort nullen
        nowPlayingTitle = ""
        statusText = reconnect.retryCount == 0 ? String(localized: "Lade …") : reconnectLoadingText
        isLoading = true
        isPlaying = false
        playStartedAt = nil
        lastState = nil
        let raw = station.url
        guard StreamURLPolicy.validatedURL(raw) != nil else {
            desiredStation = nil
            reconnect.cancel()
            stopMonitoringNetwork()
            stopAttempt()
            statusText = String(localized: "Ungültige URL")
            return
        }
        reconnect.attemptStarted()
        resolveTask = Task { [weak self] in
            let resolved = await PlaylistResolver.resolve(raw)
            guard let self else { return }
            if Task.isCancelled { return }
            guard self.requests.accepts(generation) else { return }
            guard let url = resolved else {
                self.attemptFailed()
                return
            }
            self.start(url: url, generation: generation)
        }
    }

    private func start(url: URL, generation: UInt64) {
        guard requests.accepts(generation) else { return }
        // Ein wiederverwendeter VLC-Player kann die Herkunft spaeter Events
        // nicht unterscheiden. Pro Medium eine Instanz mit fester Generation.
        let previous = player
        previous.delegate = nil
        player = makePlayer()
        let nextShim = PlayerDelegateShim(
            onState: { [weak self] state in self?.handleState(state, generation: generation) },
            onTime: { [weak self] in self?.handleTimeAdvanced(generation: generation) })
        shim = nextShim
        player.delegate = nextShim
        previous.stop()  // trifft ausschliesslich die alte Instanz
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        player.media = media
        installedStationID = currentStation?.id
        applyAudioSettings()
        installedGeneration = generation
        player.play()
        currentStreamURL = url   // AudioTap starten: er tappt die eigene Prozessausgabe

        startMetadata(url: url)
        // Nur Schema/Host/Pfad loggen: Query und Benutzerinfo koennen Tokens oder
        // Passwoerter enthalten und landeten frueher unmaskiert im Unified Log.
        log.notice("play \(self.currentStation?.name ?? "?", privacy: .public) -> \(StreamURLPolicy.redactedForLog(url), privacy: .public)")
    }

    private func startMetadata(url: URL, retry: Bool = false) {
        // Container wie Ogg/FLAC benötigen beim Dateibeginn ihre Streamheader.
        // Die alte Metadatenverbindung zuerst schließen; VLC bleibt unverändert.
        metadataGeneration &+= 1
        let ticket = metadataGeneration
        if !retry, let id = currentStation?.id { metadataReconnect.beginIntent(stationID: id) }
        metadataReconnect.attemptStarted(); metadataActivityUptime = 0
        icy.stop()
        // Die vorhandene ICY-Verbindung bleibt auch ohne Metadaten erhalten.
        // MP3/AAC schalten nur die Dateisenke; Containerheader erneuern bei Bedarf diesen Reader.
        let recorder = self.recorder
        let stationName = currentStation?.name ?? "Sender"
        // Auch bei gleichbleibendem VLC gehört jede ICY-Verbindung zu einer eigenen Aufnahme-Session.
        recordingSessionID = UUID()
        let streamID = recordingSessionID
        recorder.configureCapture(station: stationName, streamID: streamID,
                                  enabled: recordingRequested, revision: recordingRevision, preserveFailure: retry)
        icy.start(url: url, allowAudioOnly: true,
                  onStart: { contentType, _ in recorder.captureFormat(contentType, streamID: streamID) },
                  onBoundary: { title, boundary in recorder.songBoundary(title: title, at: boundary) },
                  onAudioAt: { [weak self] data, date, uptime in
                      recorder.captureAudio(data, at: date, receivedUptime: uptime, streamID: streamID)
                      DispatchQueue.main.async { self?.metadataActivity(ticket: ticket, uptime: uptime) }
                  },
                  onCompletion: { [weak self] date in
                      DispatchQueue.main.async {
                          guard let self, self.metadataGeneration == ticket else { return }
                          self.metadataEnded(at: date)
                      }
                      recorder.finishCapture(streamID: streamID, at: date)
                  })
    }

    private func stopMetadata() -> Date? {
        metadataGeneration &+= 1; metadataReconnect.cancel(); metadataStatus = nil
        return icy.stop()
    }

    private func metadataActivity(ticket: UInt64, uptime: TimeInterval) {
        guard ticket == metadataGeneration, desiredStation != nil, currentStreamURL != nil else { return }
        metadataReconnect.playing()
        if uptime - metadataActivityUptime >= 1 {
            metadataActivityUptime = uptime; metadataReconnect.activity()
        }
    }

    private func metadataEnded(at date: Date) {
        guard desiredStation != nil, currentStreamURL != nil, metadataReconnect.desiredStationID != nil else { return }
        metadataGeneration &+= 1
        let endedAt = icy.stop() ?? date
        recorder.finishCapture(streamID: recordingSessionID, at: endedAt)
        history.closeCurrent(at: endedAt); nowPlayingTitle = ""
        metadataReconnect.failed()
    }

    private func metadataPhaseChanged(_ phase: PlaybackReconnect.Phase) {
        switch phase {
        case .waiting(let attempt, let delay):
            metadataStatus = String(localized: "Titeldaten: neuer Versuch \(attempt)/\(metadataReconnect.maximumRetries) in \(Int(delay)) s")
        case .waitingForNetwork:
            metadataStatus = String(localized: "Titeldaten warten auf das Netzwerk.")
        case .connecting:
            metadataStatus = metadataReconnect.retryCount > 0 ? String(localized: "Titeldaten werden erneut verbunden …") : nil
        case .exhausted:
            metadataStatus = String(localized: "Titeldaten nicht verfügbar. Für einen neuen Versuch den Sender erneut starten.")
        case .playing, .idle: metadataStatus = nil
        }
    }

    func stop() {
        sleepingStationID = nil
        desiredStation = nil
        reconnect.cancel()
        stopMonitoringNetwork()
        stopAttempt()
        sleepTimer.cancel()
        statusText = String(localized: "Gestoppt")
    }

    private func stopAttempt() {
        let endedAt = stopMetadata()
        history.closeCurrent(at: endedAt ?? Date())
        resetCapture(at: endedAt ?? Date())
        resolveTask?.cancel()
        resolveTask = nil
        requests.invalidate()
        installedGeneration = 0
        player.delegate = nil
        player.stop()
        shim = nil
        isPlaying = false
        isLoading = false
        playStartedAt = nil
        currentStreamURL = nil
    }

    // Verlauf + zugehoerige Aufnahmen aelter als `cutoff` loeschen.
    func cleanupHistory(olderThan cutoff: Date) {
        history.remove(olderThan: cutoff)
        recorder.prune(olderThan: cutoff)
    }

    // Klick auf einen Sender: laeuft/laedt er schon -> Stop, sonst Start.
    func toggle(_ station: Station) {
        if (isPlaying || isLoading), currentStation?.id == station.id {
            stop()
        } else {
            play(station)
        }
    }

    // MARK: - intern

    // Erstes Voranschreiten der Zeit = wir spielen wirklich.
    private func handleTimeAdvanced(generation: UInt64) {
        // Nur Zeit-Ereignisse des installierten Mediums der aktuellen Generation zaehlen.
        // `currentStreamURL` ist nil waehrend der Aufloesung und nach Stop/Fehler.
        // Ein Ereignis des alten Mediums kann asynchron auf dem Main-Thread eintreffen
        // und wuerde sonst "Wiedergabe" fuer den neuen Sender melden, obwohl noch der
        // alte hoerbar ist.
        guard generation == installedGeneration, requests.accepts(generation), currentStreamURL != nil else { return }
        reconnect.activity()
        guard !isPlaying else { return }
        reconnect.playing()
        isPlaying = true
        isLoading = false
        playStartedAt = Date()       // B2: Laufzeit ab erstem Audio
        statusText = String(localized: "Wiedergabe")
        log.notice("status=playing \(self.currentStation?.name ?? "?", privacy: .public)")
    }

    private func handleState(_ state: VLCMediaPlayerState, generation: UInt64) {
        guard generation == installedGeneration, requests.accepts(generation) else { return }
        guard state != lastState else { return }
        lastState = state

        switch state {
        case .opening, .buffering:
            if !isPlaying {
                isLoading = true
                statusText = reconnect.retryCount == 0 ? String(localized: "Puffert …") : reconnectLoadingText
            }
        case .esAdded:
            break
        case .playing:
            handleTimeAdvanced(generation: generation)
        case .paused, .stopped, .ended, .error:
            attemptFailed()
        @unknown default:
            break
        }
    }

    private var reconnectLoadingText: String {
        String(localized: "Verbinde erneut (\(reconnect.retryCount)/\(reconnect.maximumRetries)) …")
    }

    private func attemptFailed() {
        guard desiredStation != nil, reconnect.desiredStationID != nil else { return }
        // Die alte Generation zuerst sperren: auf Main wartende VLC-Ereignisse
        // dürfen weder einen zweiten Versuch planen noch die Warteanzeige ersetzen.
        stopAttempt()
        nowPlayingTitle = ""
        reconnect.failed()
    }

    private func reconnectPhaseChanged(_ phase: PlaybackReconnect.Phase) {
        switch phase {
        case .waiting(let attempt, let delay):
            isLoading = true
            statusText = String(localized: "Wiederverbinden \(attempt)/\(reconnect.maximumRetries): Wartezeit \(Int(delay)) s")
        case .waitingForNetwork(let attempt):
            isLoading = true
            statusText = String(localized: "Warte auf Netzwerk (\(attempt)/\(reconnect.maximumRetries)) …")
        case .exhausted:
            desiredStation = nil
            stopMonitoringNetwork()
            isLoading = false
            statusText = String(localized: "Verbindung fehlgeschlagen. Bitte den Sender erneut starten.")
        default: break
        }
    }

    private func monitorNetwork() {
        stopMonitoringNetwork()
        let token = networkToken
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status != .unsatisfied
            DispatchQueue.main.async { [weak self] in
                guard let self, self.networkToken == token, self.desiredStation != nil else { return }
                self.reconnect.setNetworkAvailable(available)
                self.metadataReconnect.setNetworkAvailable(available)
            }
        }
        networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "MuckeBaby.network"))
    }

    private func stopMonitoringNetwork() {
        networkToken = UUID()
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    // Neuer ICY-Live-Titel -> Anzeige + Verlauf.
    private func setNowPlaying(_ title: String, at boundary: Date) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let changed = t != nowPlayingTitle
        if changed { nowPlayingTitle = t }
        // Beim Rollover kann der Titel schon angekommen sein, seine Zuordnung
        // zum geschlossenen Aufnahmeabschnitt muss trotzdem wechseln.
        if let st = currentStation { history.note(station: st.name, raw: t, at: boundary, sessionID: recordingSegmentID ?? recordingSessionID) }
        if changed { log.notice("nowplaying \(t, privacy: .public)") }
    }
}

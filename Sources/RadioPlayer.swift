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
    let history: SongHistory
    let recorder: Recorder
    @Published private(set) var recordingRequested: Bool
    @Published private(set) var timeshiftRequested = false
    @Published private(set) var isHLSStream = false
    @Published private(set) var timeshiftStatus = String(localized: "Zeitversatz ist aus.")
    @Published private(set) var timeshiftTransport = TimeshiftTransport()
    private var timeshiftReader: TimeshiftSegmentStream?
    private var timeshiftTimer: Timer?
    private var outputGeneration = UUID()
    private var outputRevision: UInt64 = 0
    private var receivedTitle = ""
    private var decodedSampleRate: Int?
    var isPaused: Bool { timeshiftTransport.isPaused }
    var hasPlaybackIntent: Bool { desiredStation != nil }
    var canPause: Bool { timeshiftReader != nil && isPlaying }
    var listeningReceivedAt: Date? { timeshift.receivedAt(position: timeshiftTransport.position) }
    var canSeekTimeshift: Bool { timeshiftTransport.timeline.canStart && (!timeshift.requiresDecodedSampleRate || decodedSampleRate != nil) }
    private let makeTimeshiftBuffer: () throws -> TimeshiftSegments
    private lazy var timeshift: TimeshiftCapture = TimeshiftCapture(makeBuffer: makeTimeshiftBuffer, onState: { [weak self] _ in
        DispatchQueue.main.async {
            guard let self else { return }
            switch self.timeshift.currentState {
            case .off: self.timeshiftStatus = String(localized: "Zeitversatz ist aus.")
            case .waiting: self.timeshiftStatus = String(localized: "Zeitversatz wartet auf einen MP3- oder AAC-ADTS-Stream.")
            case .buffering: self.timeshiftStatus = String(localized: "Temporärer MP3-/AAC-Puffer aktiv.")
            case .failed(let message): self.timeshiftStatus = message
            }
            if case .failed = self.timeshift.currentState, self.timeshiftReader != nil {
                self.expireTimeshift()
            }
        }
    })
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
    private var sleepingPlaybackHeld = false
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var systemObservers: [NSObjectProtocol] = []
    private var desiredStation: Station?
    private var networkMonitor: NWPathMonitor?
    private var networkToken = UUID()

    var recognitionContext: RecognitionContext? {
        guard isPlaying, let station = currentStation, currentStreamURL != nil else { return nil }
        return RecognitionContext(generation: outputRevision, stationID: station.id, title: nowPlayingTitle)
    }

    init(reconnect: PlaybackReconnect? = nil, makePlayer: @escaping () -> VLCMediaPlayer = { VLCMediaPlayer() }, recorder: Recorder = Recorder(), preferences: UserDefaults = .standard, metadataReconnect: PlaybackReconnect? = nil, sleepTimer: SleepTimerController? = nil, history: SongHistory? = nil, timeshiftRoot: URL = TimeshiftSegments.defaultRoot, makeTimeshiftBuffer: (() throws -> TimeshiftSegments)? = nil) {
        self.history = history ?? SongHistory()
        self.makeTimeshiftBuffer = makeTimeshiftBuffer ?? { try TimeshiftSegments(root: timeshiftRoot) }
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
        reconnect.onTimeout = { [weak self] in
            guard let self, !self.timeshiftTransport.holdsPlayback else { return }
            self.attemptFailed()
        }
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

    deinit { timeshiftTimer?.invalidate(); for observer in systemObservers { workspaceNotifications.removeObserver(observer) } }

    func prepareForSleep() {
        guard sleepingStationID == nil, let desiredStation else { return }
        sleepingStationID = desiredStation.id
        sleepingPlaybackHeld = timeshiftTransport.holdsPlayback
        reconnect.cancel(); stopMonitoringNetwork(); stopAttempt()
        nowPlayingTitle = ""; statusText = String(localized: "Wiedergabe ruht bis zum Aufwachen.")
    }

    func resumeAfterWake() {
        guard let id = sleepingStationID else { return }
        let held = sleepingPlaybackHeld
        sleepingStationID = nil
        sleepingPlaybackHeld = false
        sleepTimer.refresh()
        guard let station = desiredStation, station.id == id else { return }
        if held {
            timeshiftTransport.phase = .expired
            statusText = String(localized: "Pufferposition nicht mehr verfügbar. Mit Live fortsetzen.")
            return
        }
        play(station)
    }

    func setTimeshiftRequested(_ enabled: Bool) {
        guard enabled != timeshiftRequested else { return }
        let wasLocal = timeshiftReader != nil || timeshiftTransport.holdsPlayback
        closeTimeshiftReader()
        timeshiftRequested = enabled
        timeshift.setEnabled(enabled)
        if enabled { timeshift.noteTitle(receivedTitle, at: history.entries.last?.start, session: recordingSessionID) }
        timeshiftTimer?.invalidate(); timeshiftTimer = nil
        timeshiftTransport = TimeshiftTransport()
        if enabled {
            timeshiftTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshTimeshift() }
            }
        }
        if wasLocal {
            if let url = currentStreamURL { startLiveOutput(url: url, generation: requests.current) }
            else if !enabled, let station = desiredStation { play(station) }
        }
    }

    func pause() {
        guard canPause else { return }
        refreshTimeshift()
        guard timeshiftReader != nil else { return }
        timeshiftTransport.phase = .paused
        player.pause(); isPlaying = false; isLoading = false
        statusText = String(localized: "Pausiert")
    }

    func resume() {
        refreshTimeshift()
        guard isPaused, timeshiftReader != nil else { return }
        timeshiftTransport.phase = .delayed
        isLoading = true; statusText = String(localized: "Puffert …")
        player.play()
    }

    func togglePause() { if isPaused { resume() } else { pause() } }

    func seekTimeshift(to position: TimeInterval) {
        guard timeshiftRequested, currentStreamURL != nil,
              let target = timeshift.timeline.clamped(position) else { return }
        let paused = isPaused
        startTimeshift(at: target, paused: paused, live: false)
    }

    func skipTimeshift(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        seekTimeshift(to: timeshiftTransport.position + seconds)
    }

    func returnToLive() {
        guard let station = desiredStation else { return }
        guard let url = currentStreamURL else { play(station); return }
        let timeline = timeshift.timeline
        if timeshiftRequested, timeline.canStart, !timeshift.requiresDecodedSampleRate || decodedSampleRate != nil {
            startTimeshift(at: timeline.latestStart, paused: false, live: true)
        } else {
            closeTimeshiftReader(); timeshiftTransport = TimeshiftTransport()
            if timeshiftRequested { timeshift.setEnabled(true) }
            startLiveOutput(url: url, generation: requests.current)
        }
    }

    private func invalidateOutput() {
        outputGeneration = UUID(); outputRevision &+= 1
    }

    private func closeTimeshiftReader() {
        guard let reader = timeshiftReader else { return }
        invalidateOutput()
        player.delegate = nil
        player.audio?.volume = 0
        // Erst blockierte Reads wecken, dann VLC beenden und zuletzt Dateien freigeben.
        timeshift.cancelReaders(); player.stop(); reader.close()
        timeshiftReader = nil; shim = nil
    }

    private func expireTimeshift() {
        closeTimeshiftReader()
        invalidateOutput(); player.delegate = nil; player.audio?.volume = 0; player.stop()
        timeshiftTransport.phase = .expired
        isPlaying = false; isLoading = false
        statusText = String(localized: "Pufferposition nicht mehr verfügbar. Mit Live fortsetzen.")
    }

    private func startTimeshift(at position: TimeInterval, paused: Bool, live: Bool) {
        guard !timeshift.requiresDecodedSampleRate || decodedSampleRate != nil else { return }
        let wasLocal = timeshiftReader != nil || timeshiftTransport.holdsPlayback
        closeTimeshiftReader()
        do {
            let reader = try timeshift.makeReader(at: position, decodedSampleRate: decodedSampleRate)
            player.delegate = nil; player.audio?.volume = 0; player.stop()
            invalidateOutput()
            let ticket = outputGeneration
            let next = makePlayer()
            player = next; timeshiftReader = reader
            timeshiftTransport = TimeshiftTransport(phase: paused ? .paused : (live ? .live : .delayed),
                timeline: timeshift.timeline, position: reader.playbackStart)
            nowPlayingTitle = timeshiftTransport.timeline.title(at: reader.playbackStart)
            let delegate = PlayerDelegateShim(onState: { [weak self] state in
                guard let self, self.outputGeneration == ticket else { return }
                switch state {
                case .error, .ended, .stopped: self.expireTimeshift()
                case .playing: self.localTimeAdvanced(ticket: ticket)
                default: break
                }
            }, onTime: { [weak self] in self?.localTimeAdvanced(ticket: ticket) })
            shim = delegate; next.delegate = delegate
            let media = VLCMedia(stream: reader)
            for option in reader.mediaOptions { media.addOption(option) }
            next.media = media; applyAudioSettings()
            isPlaying = false; isLoading = !paused
            statusText = paused ? String(localized: "Pausiert") : String(localized: "Puffert …")
            // Beim Seek in Pause bleibt der neue Leser ungestartet und gepinnt.
            if !paused { next.play() }
        } catch {
            timeshift.rejectPlayback(error)
            if wasLocal { expireTimeshift() }
        }
    }

    private func localTimeAdvanced(ticket: UUID) {
        guard ticket == outputGeneration, timeshiftReader != nil, !isPaused else { return }
        if timeshift.requiresDecodedSampleRate, player.time.intValue > 500,
           let known = decodedSampleRate, let actual = reportedAudioRate, known != actual {
            decodedSampleRate = nil
            timeshift.rejectPlayback(TimeshiftSegmentFailure.decoderFormat)
            expireTimeshift()
            return
        }
        reconnect.playing(); reconnect.activity()
        if !isPlaying { isPlaying = true }
        if isLoading { isLoading = false }
        if playStartedAt == nil { playStartedAt = Date() }
        if statusText != String(localized: "Wiedergabe") { statusText = String(localized: "Wiedergabe") }
        refreshTimeshift()
    }

    private func refreshTimeshift() {
        guard timeshiftRequested else { return }
        let timeline = timeshift.timeline
        var transport = timeshiftTransport
        transport.timeline = timeline
        if let reader = timeshiftReader {
            if !isPaused {
                // audio-desync verschiebt die Ausgabe relativ zur VLC-Uhr.
                // Ihr hörbarer Ursprung ist daher playbackStart, nicht start.
                transport.position = max(reader.playbackStart, reader.playbackStart + Double(player.time.intValue) / 1000)
            }
            guard timeline.canStart, transport.position + 0.001 >= timeline.oldest else {
                timeshiftTransport = transport
                expireTimeshift(); return
            }
            let title = timeline.title(at: transport.position)
            if nowPlayingTitle != title { nowPlayingTitle = title }
        } else if !timeshiftTransport.holdsPlayback, currentStreamURL != nil, timeline.canStart,
                  !timeshift.requiresDecodedSampleRate || decodedSampleRate != nil {
            startTimeshift(at: timeline.latestStart, paused: false, live: true)
            return
        }
        if transport != timeshiftTransport { timeshiftTransport = transport }
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
            if receivedTitle.isEmpty { history.beginSession(station: station.name, at: date, sessionID: id) }
            else { history.note(station: station.name, raw: receivedTitle, at: date, sessionID: id) }
        } else if state.phase != .recording, recordingSegmentID != nil {
            recordingSegmentID = nil
            history.closeCurrent()
            if currentStreamURL != nil, let station = currentStation, !receivedTitle.isEmpty {
                history.note(station: station.name, raw: receivedTitle, sessionID: recordingSessionID)
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
        sleepingPlaybackHeld = false
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
        startLiveOutput(url: url, generation: generation)
        currentStreamURL = url
        startMetadata(url: url)
        log.notice("play \(self.currentStation?.name ?? "?", privacy: .public) -> \(StreamURLPolicy.redactedForLog(url), privacy: .public)")
    }

    private func startLiveOutput(url: URL, generation: UInt64) {
        closeTimeshiftReader()
        decodedSampleRate = nil
        invalidateOutput()
        let outputTicket = outputGeneration
        // Ein wiederverwendeter VLC-Player kann die Herkunft spaeter Events
        // nicht unterscheiden. Pro Medium eine Instanz mit fester Generation.
        let previous = player
        previous.delegate = nil
        previous.audio?.volume = 0
        player = makePlayer()
        let nextShim = PlayerDelegateShim(
            onState: { [weak self] state in
                guard let self, self.outputGeneration == outputTicket else { return }
                self.handleState(state, generation: generation)
            },
            onTime: { [weak self] in
                guard let self, self.outputGeneration == outputTicket else { return }
                self.handleTimeAdvanced(generation: generation)
            })
        shim = nextShim
        player.delegate = nextShim
        previous.stop()  // trifft ausschliesslich die alte Instanz
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        player.media = media
        installedStationID = currentStation?.id
        applyAudioSettings()
        installedGeneration = generation
        lastState = nil; isPlaying = false; isLoading = true
        nowPlayingTitle = receivedTitle
        player.play()
    }

    private func startMetadata(url: URL, retry: Bool = false) {
        // Container wie Ogg/FLAC benötigen beim Dateibeginn ihre Streamheader.
        // Die alte Metadatenverbindung zuerst schließen; VLC bleibt unverändert.
        let wasLocal = timeshiftReader != nil || timeshiftTransport.holdsPlayback
        decodedSampleRate = nil
        isHLSStream = false
        closeTimeshiftReader()
        timeshiftTransport = TimeshiftTransport()
        if wasLocal { expireTimeshift() }
        metadataGeneration &+= 1
        let ticket = metadataGeneration
        if !retry, let id = currentStation?.id { metadataReconnect.beginIntent(stationID: id) }
        metadataReconnect.attemptStarted(); metadataActivityUptime = 0
        icy.stop()
        // Die vorhandene ICY-Verbindung bleibt auch ohne Metadaten erhalten.
        // MP3/AAC schalten nur die Dateisenke; Containerheader erneuern bei Bedarf diesen Reader.
        let recorder = self.recorder
        let timeshift = self.timeshift
        let stationName = currentStation?.name ?? "Sender"
        // Auch bei gleichbleibendem VLC gehört jede ICY-Verbindung zu einer eigenen Aufnahme-Session.
        recordingSessionID = UUID()
        let streamID = recordingSessionID
        timeshift.begin(streamID)
        recorder.configureCapture(station: stationName, streamID: streamID,
                                  enabled: recordingRequested, revision: recordingRevision, preserveFailure: retry)
        if StreamCapturePolicy.isHLS(nil, url: url) {
            hlsCaptureUnavailable(ticket: ticket, streamID: streamID)
            return
        }
        icy.start(url: url, allowAudioOnly: true,
                  onStart: { contentType, _ in
                      recorder.captureFormat(contentType, streamID: streamID)
                      timeshift.accept(contentType, session: streamID)
                  },
                  onBoundary: { title, boundary in
                      recorder.songBoundary(title: title, at: boundary)
                      timeshift.noteTitle(title, at: boundary, session: streamID)
                  },
                  onAudioAt: { [weak self] data, date, uptime in
                      recorder.captureAudio(data, at: date, receivedUptime: uptime, streamID: streamID)
                      timeshift.append(data, at: date, session: streamID)
                      DispatchQueue.main.async { self?.metadataActivity(ticket: ticket, uptime: uptime) }
                  },
                  onCompletion: { [weak self] date in
                      DispatchQueue.main.async {
                          guard let self, self.metadataGeneration == ticket else { return }
                          self.metadataEnded(at: date)
                      }
                      recorder.finishCapture(streamID: streamID, at: date)
                      timeshift.end(streamID)
                  }, onUnsupportedFormat: { [weak self] _ in
                      DispatchQueue.main.async { self?.hlsCaptureUnavailable(ticket: ticket, streamID: streamID) }
                  })
    }

    private func hlsCaptureUnavailable(ticket: UInt64, streamID: UUID) {
        guard metadataGeneration == ticket, recordingSessionID == streamID else { return }
        isHLSStream = true
        metadataReconnect.cancel(); icy.stop()
        metadataStatus = String(localized: "Für HLS sind Aufnahme und Zeitversatz nicht verfügbar. Die Live-Wiedergabe läuft weiter.")
        recorder.captureFormat(StreamCapturePolicy.hlsContentType, streamID: streamID)
        timeshift.accept(StreamCapturePolicy.hlsContentType, session: streamID)
    }

    private func stopMetadata() -> Date? {
        isHLSStream = false
        closeTimeshiftReader()
        timeshiftTransport = TimeshiftTransport()
        receivedTitle = ""
        decodedSampleRate = nil
        metadataGeneration &+= 1; metadataReconnect.cancel(); metadataStatus = nil
        let ended = icy.stop()
        timeshift.end()
        return ended
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
        let wasLocal = timeshiftReader != nil || timeshiftTransport.holdsPlayback
        closeTimeshiftReader(); timeshiftTransport = TimeshiftTransport(); receivedTitle = ""
        timeshift.end()
        if wasLocal { expireTimeshift() }
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
        sleepingPlaybackHeld = false
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
        invalidateOutput()
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
        if hasPlaybackIntent, currentStation?.id == station.id {
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
        decodedSampleRate = reportedAudioRate ?? decodedSampleRate
        reconnect.activity()
        guard !isPlaying else { return }
        reconnect.playing()
        isPlaying = true
        isLoading = false
        playStartedAt = Date()       // B2: Laufzeit ab erstem Audio
        statusText = String(localized: "Wiedergabe")
        log.notice("status=playing \(self.currentStation?.name ?? "?", privacy: .public)")
    }

    private var reportedAudioRate: Int? {
        for case let track as [String: Any] in player.media?.tracksInformation ?? [] {
            if let rate = (track[VLCMediaTracksInformationAudioRate] as? NSNumber)?.intValue, rate > 0 { return rate }
        }
        return nil
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
        receivedTitle = t
        let changed = t != nowPlayingTitle
        if changed, timeshiftReader == nil, !timeshiftTransport.holdsPlayback { nowPlayingTitle = t }
        // Beim Rollover kann der Titel schon angekommen sein, seine Zuordnung
        // zum geschlossenen Aufnahmeabschnitt muss trotzdem wechseln.
        if let st = currentStation { history.note(station: st.name, raw: t, at: boundary, sessionID: recordingSegmentID ?? recordingSessionID) }
        if changed { log.notice("nowplaying \(t, privacy: .public)") }
    }
}

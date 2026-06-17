import Foundation
import VLCKit
import os

private let log = Logger(subsystem: "de.danielmuller.macradio", category: "player")

// Delegate-Bruecke: VLCKit ruft ObjC-Delegate-Methoden auf. Diese kleine
// NSObject-Klasse faengt sie ab und leitet sie als Closures auf den Main-Thread.
final class PlayerDelegateShim: NSObject, VLCMediaPlayerDelegate {
    var onState: (() -> Void)?
    var onTime: (() -> Void)?

    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        DispatchQueue.main.async { self.onState?() }
    }
    // Zeit laeuft -> zuverlaessiges "spielt jetzt"-Signal (state bleibt bei
    // Live-Streams oft auf .buffering haengen).
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        DispatchQueue.main.async { self.onTime?() }
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
    @Published private(set) var lowDiskWarning = false   // Aufnahme wegen Platzmangel gestoppt
    // Fehlerzustand getrennt vom Anzeigetext fuehren: `statusText` ist lokalisiert, darum
    // darf die Zustandslogik NICHT auf seinen Wortlaut pruefen (frueher hasPrefix("Fehler")) —
    // das brach in anderer Sprache. Stattdessen dieses Flag.
    private var isErrorState = false
    // B2: Zeitpunkt, ab dem der aktuelle Sender wirklich spielt (erstes Audio).
    // Footer zeigt daraus die laufende Sender-Laufzeit. nil = spielt nicht.
    @Published private(set) var playStartedAt: Date?
    // Aufgelöste Direkt-Stream-URL des laufenden Senders. Der Audio-Analyse-Player (AudioTap)
    // dekodiert dieselbe URL parallel (stumm) für die Visualizer-Reaktivität.
    @Published private(set) var currentStreamURL: URL?

    let history = SongHistory()
    let recorder = Recorder()

    private let player = VLCMediaPlayer()
    private let shim = PlayerDelegateShim()
    private let icy = ICYMetadataReader()
    private var desiredVolume: Float = 0.77
    private var lastState: VLCMediaPlayerState?
    private var resolveTask: Task<Void, Never>?

    // Mitschnitt standardmaessig AUS; in den Einstellungen aktivierbar.
    static var recordingEnabled: Bool {
        UserDefaults.standard.object(forKey: "recordStreams") as? Bool ?? false
    }

    init() {
        player.delegate = shim
        shim.onState = { [weak self] in self?.handleState() }
        shim.onTime  = { [weak self] in self?.handleTimeAdvanced() }
        icy.onTitle  = { [weak self] title in self?.setNowPlaying(title) }
        recorder.onLowDisk = { [weak self] in self?.lowDiskWarning = true }
    }

    // Lautstaerke 0.0 … 1.0  (VLC-Skala: 0…100, 100 = Originalpegel)
    func setVolume(_ v: Float) {
        desiredVolume = max(0, min(1, v))
        player.audio?.volume = Int32(desiredVolume * 100)
    }

    // Sender abspielen. Zuerst evtl. Playlist (.pls/.m3u/Tune.ashx) zur
    // Direkt-URL aufloesen — VLCMediaPlayer spielt Playlist-Container nicht
    // selbst ab. Codec/Redirect uebernimmt dann VLC.
    func play(_ station: Station) {
        history.closeCurrent()      // Senderwechsel = Songende
        recorder.end()              // alte Aufnahme schliessen
        icy.stop()
        resolveTask?.cancel()
        resolveTask = nil

        currentStation = station
        nowPlayingTitle = ""
        statusText = String(localized: "Lade …")
        isErrorState = false
        isLoading = true
        isPlaying = false
        playStartedAt = nil
        lastState = nil

        let raw = station.url
        resolveTask = Task { [weak self] in
            let resolved = await PlaylistResolver.resolve(raw)
            guard let self else { return }
            if Task.isCancelled { return }
            guard let url = resolved else {
                self.isLoading = false
                self.statusText = String(localized: "Ungültige URL")
                return
            }
            self.start(url: url)
        }
    }

    private func start(url: URL) {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        player.media = media
        player.audio?.volume = Int32(desiredVolume * 100)
        player.play()
        currentStreamURL = url   // Analyse-Player (AudioTap) hängt sich an dieselbe URL

        // ICY-Reader: Now-Playing-Titel + (bei aktivierter Aufnahme) Audio mitschneiden.
        let recorder = self.recorder
        let stationName = currentStation?.name ?? "Sender"
        let rec = Self.recordingEnabled
        // B1: Bei aktivierter Aufnahme sofort einen Platzhalter-Verlaufseintrag anlegen,
        // damit der Mitschnitt auch bei Sendern OHNE ICY-Titel ueber den Verlauf
        // exportierbar ist. `sessionStart` wird unten an `begin()` durchgereicht, sodass
        // Clip-Start == Platzhalter-Start gilt (Export-Offset 0, Clip deckt den Eintrag).
        let sessionStart = Date()
        if rec { history.beginSession(station: stationName, at: sessionStart) }
        icy.onContentType = { ct in if rec { recorder.begin(station: stationName, contentType: ct, at: sessionStart) } }
        icy.onAudio = { data in if rec { recorder.write(data) } }
        icy.start(url: url, allowAudioOnly: rec)
        log.notice("play \(self.currentStation?.name ?? "?", privacy: .public) -> \(url.absoluteString, privacy: .public)")
    }

    func stop() {
        history.closeCurrent()
        recorder.end()
        icy.stop()
        resolveTask?.cancel()
        resolveTask = nil
        player.stop()
        isPlaying = false
        isLoading = false
        playStartedAt = nil
        currentStreamURL = nil
        if !isErrorState { statusText = String(localized: "Gestoppt") }
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
    private func handleTimeAdvanced() {
        guard !isPlaying else { return }
        isPlaying = true
        isLoading = false
        playStartedAt = Date()       // B2: Laufzeit ab erstem Audio
        statusText = String(localized: "Wiedergabe")
        isErrorState = false
        log.notice("status=playing \(self.currentStation?.name ?? "?", privacy: .public)")
    }

    private func handleState() {
        let state = player.state
        guard state != lastState else { return }
        lastState = state

        switch state {
        case .opening, .buffering:
            if !isPlaying { isLoading = true; statusText = String(localized: "Puffert …") }
        case .playing:
            handleTimeAdvanced()
        case .paused, .stopped, .ended:
            isPlaying = false
            isLoading = false
            playStartedAt = nil
            history.closeCurrent()
            if !isErrorState { statusText = String(localized: "Gestoppt") }
            log.notice("status=stopped \(self.currentStation?.name ?? "?", privacy: .public)")
        case .error:
            isPlaying = false
            isLoading = false
            playStartedAt = nil
            history.closeCurrent()
            statusText = String(localized: "Fehler: Stream nicht abspielbar")
            isErrorState = true
            log.notice("status=failed \(self.currentStation?.name ?? "?", privacy: .public)")
        @unknown default:
            break
        }
    }

    // Neuer ICY-Live-Titel -> Anzeige + Verlauf.
    private func setNowPlaying(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != nowPlayingTitle else { return }
        nowPlayingTitle = t
        if let st = currentStation { history.note(station: st.name, raw: t) }
        recorder.songBoundary()      // ggf. 24h-Rollover an Songgrenze
        log.notice("nowplaying \(t, privacy: .public)")
    }
}

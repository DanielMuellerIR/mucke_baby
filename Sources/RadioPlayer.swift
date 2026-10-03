import Foundation
import VLCKit
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
    // Aufnahme wegen Platzmangel gestoppt (< 10 GB frei). Wird im Now-Playing-Fuss
    // angezeigt und beim naechsten Senderstart in play() zurueckgesetzt.
    @Published private(set) var lowDiskWarning = false
    // Fehlerzustand getrennt vom Anzeigetext fuehren: `statusText` ist lokalisiert, darum
    // darf die Zustandslogik NICHT auf seinen Wortlaut pruefen (frueher hasPrefix("Fehler")) —
    // das brach in anderer Sprache. Stattdessen dieses Flag.
    private var isErrorState = false
    // B2: Zeitpunkt, ab dem der aktuelle Sender wirklich spielt (erstes Audio).
    // Footer zeigt daraus die laufende Sender-Laufzeit. nil = spielt nicht.
    @Published private(set) var playStartedAt: Date?
    // Aufgelöste Direkt-Stream-URL des laufenden Senders. Der AudioTap dekodiert NICHT parallel;
    // er nutzt diese Published-URL nur als Start/Stop-Signal und tappt dann die Prozessausgabe.
    @Published private(set) var currentStreamURL: URL?

    let history = SongHistory()
    let recorder = Recorder()

    private var player = VLCMediaPlayer()
    private var shim: PlayerDelegateShim?
    private let icy = ICYMetadataReader()
    private var desiredVolume: Float = 0.77
    private var lastState: VLCMediaPlayerState?
    private var resolveTask: Task<Void, Never>?
    private var requests = LatestRequestGeneration()
    private var installedGeneration: UInt64 = 0

    // Mitschnitt standardmaessig AUS; in den Einstellungen aktivierbar.
    static var recordingEnabled: Bool {
        UserDefaults.standard.object(forKey: "recordStreams") as? Bool ?? false
    }

    init() {
        // codereview-ok: icy/recorder sind app-lebenslange Member mit [weak self]-Closures — kein Retain-Cycle/Leak (2026-07-01)
        icy.onTitle  = { [weak self] title, boundary in self?.setNowPlaying(title, at: boundary) }
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
        icy.stop()                  // erst alle noch laufenden Senken abwarten
        recorder.end()              // danach kann kein alter begin-Auftrag mehr folgen
        resolveTask?.cancel()
        resolveTask = nil
        let generation = requests.begin()

        currentStation = station
        currentStreamURL = nil      // Wechselfenster: alte Stream-URL sofort nullen
        nowPlayingTitle = ""
        statusText = String(localized: "Lade …")
        isErrorState = false
        isLoading = true
        isPlaying = false
        playStartedAt = nil
        lastState = nil
        // Neuer Senderstart = neuer Aufnahme-Versuch: alte Platzmangel-Warnung
        // zuruecksetzen. Ist der Speicher weiterhin knapp, setzt der Recorder sie
        // beim naechsten Platz-Check sofort wieder.
        lowDiskWarning = false

        let raw = station.url
        resolveTask = Task { [weak self] in
            let resolved = await PlaylistResolver.resolve(raw)
            guard let self else { return }
            if Task.isCancelled { return }
            guard self.requests.accepts(generation) else { return }
            guard let url = resolved else {
                // Fail-closed-Ende ohne neues Medium: Der VORHERIGE Sender spielt
                // sonst hoerbar weiter, waehrend UI/currentStation schon den neuen
                // (gescheiterten) Sender zeigen. Der Stop ist hier sicher, weil
                // kein neues Medium mehr gestartet wird (vgl. AGENTS-Invariante:
                // kein asynchroner Stop VOR einem Medienwechsel).
                self.player.stop()
                self.isPlaying = false
                self.isLoading = false
                self.playStartedAt = nil
                self.currentStreamURL = nil
                self.statusText = String(localized: "Ungültige URL")
                // Wie ein Abspielfehler behandeln: das spaete .stopped-Ereignis des
                // gestoppten Players darf den Text nicht mit "Gestoppt" ueberschreiben.
                self.isErrorState = true
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
        player = VLCMediaPlayer()
        let nextShim = PlayerDelegateShim(
            onState: { [weak self] state in self?.handleState(state, generation: generation) },
            onTime: { [weak self] in self?.handleTimeAdvanced(generation: generation) })
        shim = nextShim
        player.delegate = nextShim
        previous.stop()  // trifft ausschliesslich die alte Instanz
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        player.media = media
        player.audio?.volume = Int32(desiredVolume * 100)
        installedGeneration = generation
        player.play()
        currentStreamURL = url   // AudioTap starten: er tappt die eigene Prozessausgabe

        // ICY-Reader: Now-Playing-Titel + (bei aktivierter Aufnahme) Audio mitschneiden.
        let recorder = self.recorder
        let stationName = currentStation?.name ?? "Sender"
        let rec = Self.recordingEnabled
        // Aufnahme und Platzhalter beginnen mit den ersten Audiobytes. Wartezeit
        // für HTTP-Header gehört nicht in die Zeitachse der gespeicherten Datei.
        // Die Pro-Session-Senken werden an start() uebergeben (nicht als Property gesetzt),
        // damit der ICY-Reader sie intern queue-serialisiert halten kann (Race-frei beim
        // Senderwechsel).
        icy.start(url: url, allowAudioOnly: rec,
                  onStart: { [weak self] ct, startedAt in
                      guard rec else { return }
                      recorder.begin(station: stationName, contentType: ct, at: startedAt)
                      DispatchQueue.main.async {
                          guard let self, self.requests.accepts(generation), self.currentStreamURL != nil else { return }
                          self.history.beginSession(station: stationName, at: startedAt)
                      }
                  },
                  onBoundary: { _, boundary in if rec { recorder.songBoundary(at: boundary) } },
                  onAudio: { data in if rec { recorder.write(data) } },
                  onCompletion: { endedAt in if rec { recorder.end(at: endedAt) } })
        // Nur Schema/Host/Pfad loggen: Query und Benutzerinfo koennen Tokens oder
        // Passwoerter enthalten und landeten frueher unmaskiert im Unified Log.
        log.notice("play \(self.currentStation?.name ?? "?", privacy: .public) -> \(StreamURLPolicy.redactedForLog(url), privacy: .public)")
    }

    func stop() {
        history.closeCurrent()
        icy.stop()
        recorder.end()
        resolveTask?.cancel()
        resolveTask = nil
        requests.invalidate()
        installedGeneration = 0
        player.stop()
        isPlaying = false
        isLoading = false
        playStartedAt = nil
        currentStreamURL = nil
        // Fehlerzustand beim manuellen Stop immer zuruecksetzen: andernfalls bliebe
        // statusText dauerhaft auf "Fehler: Stream nicht abspielbar", selbst wenn
        // der Nutzer explizit stoppt und damit den Fehler quittiert.
        isErrorState = false
        statusText = String(localized: "Gestoppt")
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
        guard !isPlaying else { return }
        isPlaying = true
        isLoading = false
        playStartedAt = Date()       // B2: Laufzeit ab erstem Audio
        statusText = String(localized: "Wiedergabe")
        isErrorState = false
        log.notice("status=playing \(self.currentStation?.name ?? "?", privacy: .public)")
    }

    private func handleState(_ state: VLCMediaPlayerState, generation: UInt64) {
        guard generation == installedGeneration, requests.accepts(generation) else { return }
        guard state != lastState else { return }
        lastState = state

        switch state {
        case .opening, .buffering:
            if !isPlaying { isLoading = true; statusText = String(localized: "Puffert …") }
        case .esAdded:
            break
        case .playing:
            handleTimeAdvanced(generation: generation)
        case .paused, .stopped, .ended:
            isPlaying = false
            isLoading = false
            playStartedAt = nil
            history.closeCurrent()
            // Stirbt der Stream von selbst (Senderabbruch/Netzverlust), raeumen die
            // Seitenressourcen sonst nie auf — nur stop()/play() taten das bisher.
            // Alle drei Aufrufe sind idempotent (no-op, wenn nichts laeuft).
            icy.stop()                  // laufende Senken abschliessen
            recorder.end()              // danach die letzte Aufnahme schliessen
            currentStreamURL = nil      // AudioTap stoppen (onChange -> setStream(nil))
            if !isErrorState { statusText = String(localized: "Gestoppt") }
            log.notice("status=stopped \(self.currentStation?.name ?? "?", privacy: .public)")
        case .error:
            isPlaying = false
            isLoading = false
            playStartedAt = nil
            history.closeCurrent()
            icy.stop()
            recorder.end()
            currentStreamURL = nil
            statusText = String(localized: "Fehler: Stream nicht abspielbar")
            isErrorState = true
            log.notice("status=failed \(self.currentStation?.name ?? "?", privacy: .public)")
        @unknown default:
            break
        }
    }

    // Neuer ICY-Live-Titel -> Anzeige + Verlauf.
    private func setNowPlaying(_ title: String, at boundary: Date) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != nowPlayingTitle else { return }
        nowPlayingTitle = t
        if let st = currentStation { history.note(station: st.name, raw: t, at: boundary) }
        log.notice("nowplaying \(t, privacy: .public)")
    }
}

// Testdoubles fuer VLC und Seiteneffekte. RadioPlayer/PreviewPlayer/Shim werden
// unveraendert aus den Produktquellen kompiliert; nur die Main-Queue ist steuerbar.
import Foundation
import Combine

protocol VLCMediaPlayerDelegate: AnyObject {
    func mediaPlayerStateChanged(_ notification: Notification)
    func mediaPlayerTimeChanged(_ notification: Notification)
}
enum VLCMediaPlayerState { case opening, buffering, esAdded, playing, paused, stopped, ended, error }
final class VLCAudioEqualizer {
    final class Band { var amplification: Float = 0 }
    var bands = (0..<10).map { _ in Band() }
    var preAmplification: Float = 0
}
final class VLCAudio { var volume: Int32 = 0 }
final class VLCMedia { init(url: URL) {}; func addOption(_ option: String) {} }
final class VLCMediaPlayer {
    static var latest: VLCMediaPlayer!
    weak var delegate: VLCMediaPlayerDelegate?
    var audio: VLCAudio? = VLCAudio()
    var equalizer: VLCAudioEqualizer?
    var media: VLCMedia?
    var state = VLCMediaPlayerState.stopped
    var isPlaying = false
    init() { Self.latest = self }
    func play() { state = .playing }
    func stop() { state = .stopped }
    func timeEvent() { delegate?.mediaPlayerTimeChanged(Notification(name: Notification.Name("time"))) }
    func stateEvent() { delegate?.mediaPlayerStateChanged(Notification(name: Notification.Name("state"), object: self)) }
}
struct Station { var id = UUID(); var name: String; var url: String }
struct RBStation { var stationuuid: String; var streamURL: String }
enum RadioBrowserAPI { static func countClick(stationUUID: String) {} }
enum PlaylistResolver { static func resolve(_ raw: String) async -> URL? { URL(string: raw) } }
struct FixtureSongEntry { var start: Date; var station: String = ""; var end: Date? = nil }
final class SongHistory {
    var entries: [FixtureSongEntry] = []
    var closedAt: Date?
    func closeCurrent(at: Date = Date()) { closedAt = at }
    func beginSession(station: String, at: Date, sessionID: UUID?) { entries.append(FixtureSongEntry(start: at, station: station)) }
    func note(station: String, raw: String, at: Date = Date(), sessionID: UUID?) {}
    func remove(olderThan: Date) {}
}
final class Recorder {
    var onLowDisk: (() -> Void)?
    var onCaptureState: ((RecordingState) -> Void)?
    var changes: [(Bool, UInt64)] = []
    var streamID: UUID?
    func configureCapture(station: String, streamID: UUID, enabled: Bool, revision: UInt64, preserveFailure: Bool = false) { self.streamID = streamID }
    func setCaptureEnabled(_ enabled: Bool, revision: UInt64) { changes.append((enabled, revision)) }
    func clearCapture(enabled: Bool, revision: UInt64, at: Date = Date()) {}
    func captureFormat(_ contentType: String?, streamID: UUID) {}
    func captureAudio(_ data: Data, at: Date, receivedUptime: TimeInterval, streamID: UUID) {}
    func finishCapture(streamID: UUID, at: Date) {}
    func end(at: Date = Date()) {}
    func begin(station: String, contentType: String?, at: Date, sessionID: UUID) {}
    func write(_ data: Data) {}
    func prune(olderThan: Date) {}
    func songBoundary(title: String? = nil, at: Date) {}
}
final class ICYMetadataReader {
    static var latest: ICYMetadataReader!
    var startCount = 0
    var audioAt: ((Data, Date, TimeInterval) -> Void)?
    var completion: ((Date) -> Void)?
    var lastAudioAt: Date?
    init() { Self.latest = self }
    var onTitle: ((String, Date) -> Void)?
    @discardableResult func stop() -> Date? { let end = lastAudioAt; lastAudioAt = nil; return end }
    func start(url: URL, allowAudioOnly: Bool, onStart: @escaping (String?, Date) -> Void,
               onBoundary: @escaping (String, Date) -> Void, onAudioAt: @escaping (Data, Date, TimeInterval) -> Void, onCompletion: @escaping (Date) -> Void) { startCount += 1; audioAt = onAudioAt; completion = onCompletion }
}
enum TestEvents {
    static let queue = DispatchQueue(label: "fixture.events", target: .main)
    static func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
        queue.async { MainActor.assumeIsolated(action) }
    }
}

@main
struct PlayerHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }
    @MainActor
    static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Player-Fixture wurde nicht installiert")
    }
    static func drainEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TestEvents.queue.async { continuation.resume() }
        }
    }
    @MainActor
    static func main() async {
        let audioRadio = RadioPlayer(reconnect: PlaybackReconnect(delays: [0.01]))
        let gainA = Station(name: "Quiet correction", url: "https://fixture.invalid/gain-a")
        let gainB = Station(name: "Loud correction", url: "https://fixture.invalid/gain-b")
        var audio = AudioConfiguration()
        audio.stationGainDB[gainA.id.uuidString] = -6
        audio.stationGainDB[gainB.id.uuidString] = 6
        audioRadio.configureAudio(audio); audioRadio.setVolume(0.5)
        audioRadio.play(gainA)
        await waitFor { audioRadio.currentStreamURL?.lastPathComponent == "gain-a" }
        let firstAudio = VLCMediaPlayer.latest!
        check(firstAudio.audio?.volume == 40 && abs(audioRadio.effectiveOutputVolume - 0.064) < 0.00001 && firstAudio.equalizer == nil, "Senderkorrektur oder neutraler EQ-Pfad falsch")
        audio.equalizerEnabled = true; audio.bands[5] = 6
        audioRadio.configureAudio(audio)
        check(VLCMediaPlayer.latest === firstAudio && abs((firstAudio.equalizer?.preAmplification ?? 0) - 6.0412) < 0.001
              && firstAudio.equalizer?.bands[5].amplification == 6, "Live-EQ ersetzt Player oder verliert Headroom")
        audioRadio.play(gainB)
        await waitFor { audioRadio.currentStreamURL?.lastPathComponent == "gain-b" }
        let secondAudio = VLCMediaPlayer.latest!
        check(secondAudio !== firstAudio && secondAudio.audio?.volume == 63
              && secondAudio.equalizer?.bands[5].amplification == 6, "Neue Playerinstanz erhält falsche Audioeinstellungen")
        secondAudio.state = .error; secondAudio.stateEvent()
        await waitFor { VLCMediaPlayer.latest !== secondAudio && audioRadio.currentStreamURL != nil }
        check(VLCMediaPlayer.latest.audio?.volume == 63 && abs((VLCMediaPlayer.latest.equalizer?.preAmplification ?? 0) - 6.0412) < 0.001,
              "Retry verliert Senderkorrektur oder Equalizer")
        audioRadio.setVolume(0)
        check(VLCMediaPlayer.latest.audio?.volume == 0 && audioRadio.effectiveOutputVolume == 0, "Stumm liefert Signal")
        audioRadio.setVolume(.nan)
        check(VLCMediaPlayer.latest.audio?.volume == 0, "Ungültige globale Lautstärke ist nicht stumm")
        audio.equalizerEnabled = false; audioRadio.configureAudio(audio)
        check(VLCMediaPlayer.latest.equalizer == nil, "Deaktivierter EQ bleibt im Audiopfad")
        audioRadio.stop()

        let radio = RadioPlayer(reconnect: PlaybackReconnect(delays: []))
        radio.play(Station(name: "A", url: "https://fixture.invalid/a"))
        await waitFor { radio.currentStreamURL?.lastPathComponent == "a" }
        let old = VLCMediaPlayer.latest!
        TestEvents.queue.suspend()
        old.timeEvent()
        old.state = .error
        old.stateEvent()
        radio.play(Station(name: "B", url: "https://fixture.invalid/b"))
        await waitFor { radio.currentStreamURL?.lastPathComponent == "b" }
        check(VLCMediaPlayer.latest !== old, "B verwendet noch die VLC-Instanz von A")
        TestEvents.queue.resume()
        await drainEvents()
        check(!radio.isPlaying && radio.isLoading, "A-Ereignis hat B als spielend markiert")
        VLCMediaPlayer.latest.timeEvent()
        await waitFor { radio.isPlaying }
        radio.stop()

        let radioStopped = VLCMediaPlayer.latest!
        radio.play(Station(name: "Failure", url: "https://fixture.invalid/failure"))
        await waitFor { VLCMediaPlayer.latest !== radioStopped && radio.currentStreamURL != nil }
        let radioFailing = VLCMediaPlayer.latest!
        TestEvents.queue.suspend()
        radioFailing.state = .error
        radioFailing.stateEvent()
        radioFailing.state = .stopped
        radioFailing.stateEvent()
        TestEvents.queue.resume()
        await drainEvents()
        check(radio.statusText == String(localized: "Verbindung fehlgeschlagen. Bitte den Sender erneut starten.") && !radio.isPlaying && !radio.isLoading,
              "Spaeter Stopp hat den Hauptplayer-Fehler verdeckt")
        radio.stop()

        let clock = ReconnectClock()
        let retryPolicy = PlaybackReconnect(schedule: clock.schedule)
        let retryRadio = RadioPlayer(reconnect: retryPolicy)
        let retryStation = Station(name: "Retry", url: "https://fixture.invalid/retry")
        retryRadio.play(retryStation)
        await waitFor { retryRadio.currentStreamURL?.lastPathComponent == "retry" }
        var current = VLCMediaPlayer.latest!
        ICYMetadataReader.latest.onTitle?("Fixture - Old title", Date())
        check(!retryRadio.nowPlayingTitle.isEmpty, "Titelfixture fehlt")
        current.state = .error; current.stateEvent()
        await drainEvents()
        check(retryRadio.isLoading && !retryRadio.isPlaying && retryRadio.currentStreamURL == nil && retryRadio.nowPlayingTitle.isEmpty,
              "Fehler hinterlässt aktive Seitenverbindung oder keinen bedienbaren Wartezustand")
        let pending = clock.events.last!
        retryRadio.stop(); pending.action(); clock.advance(100)
        await drainEvents()
        check(VLCMediaPlayer.latest === current && !retryRadio.isLoading && retryRadio.currentStreamURL == nil,
              "Stop während Wartezeit startet später erneut")
        retryRadio.play(retryStation)
        await waitFor { retryRadio.currentStreamURL != nil }
        current = VLCMediaPlayer.latest!
        current.state = .ended; current.stateEvent(); await drainEvents()
        clock.advance(2)
        await waitFor { VLCMediaPlayer.latest !== current && retryRadio.currentStreamURL != nil }
        let restarted = VLCMediaPlayer.latest!
        TestEvents.queue.suspend()
        current.timeEvent(); current.state = .error; current.stateEvent()
        TestEvents.queue.resume(); await drainEvents()
        check(!retryRadio.isPlaying && retryRadio.isLoading, "Alte Generation verändert Wiederverbindung")
        restarted.timeEvent(); await waitFor { retryRadio.isPlaying }
        retryRadio.stop()
        let previous = VLCMediaPlayer.latest!
        retryRadio.play(Station(name: "Unsafe", url: "file:///tmp/untrusted.mp3"))
        clock.advance(100); await drainEvents()
        check(VLCMediaPlayer.latest === previous && retryRadio.currentStreamURL == nil && !retryRadio.isLoading,
              "Ungültige URL wird automatisch wiederholt oder an VLC übergeben")
        retryRadio.stop()

        let suite = "MuckeCaptureFixture-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recordingRadio = RadioPlayer(preferences: preferences)
        check(!recordingRadio.recordingRequested, "Aufnahme ist bei neuer Installation an")
        recordingRadio.play(Station(name: "Capture", url: "https://fixture.invalid/capture"))
        await waitFor { recordingRadio.currentStreamURL != nil }
        let capturePlayer = VLCMediaPlayer.latest!
        capturePlayer.timeEvent(); await drainEvents()
        let streamURL = recordingRadio.currentStreamURL
        recordingRadio.setRecordingRequested(true)
        recordingRadio.setRecordingRequested(false)
        check(VLCMediaPlayer.latest === capturePlayer && recordingRadio.currentStreamURL == streamURL && recordingRadio.isPlaying,
              "Aufnahmeschalter startet oder stoppt den Audioplayer")
        let changes = recordingRadio.recorder.changes
        check(changes.count == 2 && changes[0].0 && !changes[1].0, "Aufnahmepräferenz erreicht die Dateisenke nicht")
        recordingRadio.recorder.onCaptureState?(RecordingState(phase: .recording, revision: changes[0].1))
        check(recordingRadio.recordingState.phase != .recording, "Verspäteter aktiver Aufnahmestatus überholt Ausschalten")
        recordingRadio.setRecordingRequested(true)
        let startedAt = Date()
        recordingRadio.history.entries = [FixtureSongEntry(start: startedAt.addingTimeInterval(1000), station: "Other", end: startedAt.addingTimeInterval(1001))]
        recordingRadio.recorder.onCaptureState?(RecordingState(phase: .recording, revision: recordingRadio.recorder.changes.last!.1,
            streamID: recordingRadio.recorder.streamID, segmentID: UUID(), startedAt: startedAt, bytes: 1))
        check(recordingRadio.history.entries.last?.start == startedAt, "Alte fremde Verlaufzeit verschiebt neuen Aufnahmebeginn")
        let metadata = ICYMetadataReader.latest!, starts = metadata.startCount
        recordingRadio.recorder.onCaptureState?(RecordingState(phase: .needsStreamHeader,
            revision: recordingRadio.recorder.changes.last!.1, streamID: recordingRadio.recorder.streamID))
        check(metadata.startCount == starts + 1 && VLCMediaPlayer.latest === capturePlayer,
              "Containerheader ersetzen die Audiowiedergabe oder erneuern die Metadatenverbindung nicht")
        recordingRadio.stop()

        let metadataClock = ReconnectClock()
        let metadataPolicy = PlaybackReconnect(schedule: metadataClock.schedule)
        let metadataRadio = RadioPlayer(metadataReconnect: metadataPolicy)
        let metadataStation = Station(name: "Metadata", url: "https://fixture.invalid/metadata")
        metadataRadio.play(metadataStation); await waitFor { metadataRadio.currentStreamURL != nil }
        let audioPlayer = VLCMediaPlayer.latest!, metadataReader = ICYMetadataReader.latest!
        audioPlayer.timeEvent(); await drainEvents()
        metadataReader.audioAt?(Data([1]), Date(), 100); await drainEvents()
        metadataReader.onTitle?("Fixture - Before loss", Date())
        let oldCompletion = metadataReader.completion!
        oldCompletion(Date()); await drainEvents()
        check(metadataRadio.isPlaying && metadataRadio.currentStreamURL != nil && metadataRadio.nowPlayingTitle.isEmpty && metadataRadio.metadataStatus != nil,
              "ICY-Ausfall stoppt Audio oder lässt unbemerkt einen alten Titel stehen")
        let firstStarts = metadataReader.startCount
        metadataClock.advance(2); await drainEvents()
        check(metadataReader.startCount == firstStarts + 1 && VLCMediaPlayer.latest === audioPlayer,
              "Nur ICY wird nicht unabhängig wiederverbunden")
        oldCompletion(Date()); await drainEvents()
        check(metadataPolicy.phase == .connecting, "Alter ICY-Abschluss beendet neue Verbindung")
        let receivedEnd = Date(timeIntervalSince1970: 1_700_000_000)
        metadataReader.lastAudioAt = receivedEnd
        metadataRadio.stop(); metadataClock.advance(100); await drainEvents()
        check(metadataRadio.history.closedAt == receivedEnd, "Stop verlängert den Verlauf über die letzte Empfangsgrenze")
        check(metadataReader.startCount == firstStarts + 1 && metadataRadio.currentStreamURL == nil,
              "Metadaten-Retry überholt manuellen Stop")
        metadataRadio.play(metadataStation); await waitFor { metadataRadio.currentStreamURL != nil }
        metadataRadio.prepareForSleep(); metadataRadio.stop(); metadataRadio.resumeAfterWake(); metadataClock.advance(100); await drainEvents()
        check(metadataRadio.currentStreamURL == nil && !metadataRadio.isLoading, "Aufwachen reaktiviert gestoppte Wiedergabe")
        metadataRadio.play(metadataStation); await waitFor { metadataRadio.currentStreamURL != nil }
        let beforeSleep = VLCMediaPlayer.latest!
        metadataRadio.prepareForSleep(); check(metadataRadio.currentStreamURL == nil, "Ruhezustand lässt Verbindung offen")
        metadataRadio.resumeAfterWake(); await waitFor { metadataRadio.currentStreamURL != nil && VLCMediaPlayer.latest !== beforeSleep }
        let afterWake = VLCMediaPlayer.latest!
        metadataRadio.resumeAfterWake(); await drainEvents()
        check(VLCMediaPlayer.latest === afterWake, "Doppeltes Aufwachereignis startet zweimal")
        metadataRadio.stop()

        let preview = PreviewPlayer()
        preview.toggle(RBStation(stationuuid: "A", streamURL: "https://fixture.invalid/a"), volume: 0)
        await waitFor { VLCMediaPlayer.latest.media != nil }
        let previewOld = VLCMediaPlayer.latest!
        TestEvents.queue.suspend()
        previewOld.timeEvent()
        previewOld.state = .error
        previewOld.stateEvent()
        preview.toggle(RBStation(stationuuid: "B", streamURL: "https://fixture.invalid/b"), volume: 0)
        await waitFor { VLCMediaPlayer.latest !== previewOld && VLCMediaPlayer.latest.media != nil }
        TestEvents.queue.resume()
        await drainEvents()
        check(preview.isLoading && preview.currentID == "B", "A-Ereignis hat B-Vorschau veraendert")
        VLCMediaPlayer.latest.timeEvent()
        await waitFor { !preview.isLoading }
        preview.stop()

        let previewStopped = VLCMediaPlayer.latest!
        let failureStation = RBStation(stationuuid: "failure", streamURL: "https://fixture.invalid/failure")
        preview.toggle(failureStation, volume: 0)
        await waitFor { VLCMediaPlayer.latest !== previewStopped && VLCMediaPlayer.latest.media != nil }
        let failing = VLCMediaPlayer.latest!
        TestEvents.queue.suspend()
        failing.state = .error
        failing.stateEvent()
        failing.state = .stopped
        failing.stateEvent()
        TestEvents.queue.resume()
        await drainEvents()
        check(preview.failedID == "failure" && preview.currentID == nil && !preview.isLoading,
              "Spaeter Stopp hat den Vorschaufehler verdeckt")
        preview.toggle(failureStation, volume: 0)
        await waitFor { VLCMediaPlayer.latest !== failing && VLCMediaPlayer.latest.media != nil }
        VLCMediaPlayer.latest.timeEvent()
        await waitFor { !preview.isLoading }
        check(preview.failedID == nil && preview.currentID == "failure", "Neustart behaelt den alten Fehler")
        preview.stop()
        print("PlayerHarness: OK")
    }
}

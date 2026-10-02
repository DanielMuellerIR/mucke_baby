// Testdoubles fuer VLC und Seiteneffekte. RadioPlayer/PreviewPlayer/Shim werden
// unveraendert aus den Produktquellen kompiliert; nur die Main-Queue ist steuerbar.
import Foundation
import Combine

protocol VLCMediaPlayerDelegate: AnyObject {
    func mediaPlayerStateChanged(_ notification: Notification)
    func mediaPlayerTimeChanged(_ notification: Notification)
}
enum VLCMediaPlayerState { case opening, buffering, esAdded, playing, paused, stopped, ended, error }
final class VLCAudio { var volume: Int32 = 0 }
final class VLCMedia { init(url: URL) {}; func addOption(_ option: String) {} }
final class VLCMediaPlayer {
    static var latest: VLCMediaPlayer!
    weak var delegate: VLCMediaPlayerDelegate?
    var audio: VLCAudio? = VLCAudio()
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
final class SongHistory {
    func closeCurrent() {}
    func beginSession(station: String, at: Date) {}
    func note(station: String, raw: String, at: Date) {}
    func remove(olderThan: Date) {}
}
final class Recorder {
    var onLowDisk: (() -> Void)?
    func end(at: Date = Date()) {}
    func begin(station: String, contentType: String?, at: Date) {}
    func write(_ data: Data) {}
    func prune(olderThan: Date) {}
    func songBoundary(at: Date) {}
}
final class ICYMetadataReader {
    var onTitle: ((String) -> Void)?
    func stop() {}
    func start(url: URL, allowAudioOnly: Bool, onStart: @escaping (String?, Date) -> Void,
               onAudio: @escaping (Data) -> Void, onCompletion: @escaping (Date) -> Void) {}
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
        let radio = RadioPlayer()
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
        check(radio.statusText == String(localized: "Fehler: Stream nicht abspielbar") && !radio.isPlaying && !radio.isLoading,
              "Spaeter Stopp hat den Hauptplayer-Fehler verdeckt")
        radio.stop()

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

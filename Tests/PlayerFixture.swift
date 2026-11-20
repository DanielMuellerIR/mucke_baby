// Doubles für Seiteneffekte des Live-Players und seiner Katalogvorschau.
import Foundation

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
    var format: ((String?, Date) -> Void)?
    var boundary: ((String, Date) -> Void)?
    var audioAt: ((Data, Date, TimeInterval) -> Void)?
    var completion: ((Date) -> Void)?
    var unsupported: ((String) -> Void)?
    var lastAudioAt: Date?
    init() { Self.latest = self }
    var onTitle: ((String, Date) -> Void)?
    @discardableResult func stop() -> Date? { let end = lastAudioAt; lastAudioAt = nil; return end }
    func start(url: URL, allowAudioOnly: Bool, onStart: @escaping (String?, Date) -> Void,
               onBoundary: @escaping (String, Date) -> Void, onAudioAt: @escaping (Data, Date, TimeInterval) -> Void, onCompletion: @escaping (Date) -> Void, onUnsupportedFormat: ((String) -> Void)? = nil) { unsupported = onUnsupportedFormat; startCount += 1; format = onStart; boundary = onBoundary; audioAt = onAudioAt; completion = onCompletion }
}
enum TestEvents {
    static let queue = DispatchQueue(label: "fixture.events", target: .main)
    static let enqueue: PlayerEventDelivery = { action in
        queue.async { MainActor.assumeIsolated(action) }
    }
}

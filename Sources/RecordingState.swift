import Foundation

struct RecordingState: Equatable, Sendable {
    struct Rollover: Equatable, Sendable {
        var title: String
        var receivedAt: Date
    }
    enum Phase: Equatable, Sendable { case off, waiting, needsStreamHeader, recording, lowDisk, indexUnavailable, streamEnded, writeFailed }
    var phase: Phase = .off
    var revision: UInt64 = 0
    var streamID: UUID?
    var segmentID: UUID?
    var startedAt: Date?
    var bytes: Int64 = 0
    var rollover: Rollover?
}

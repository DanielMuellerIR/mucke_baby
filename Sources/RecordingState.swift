import Foundation

struct RecordingState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case off, waiting, recording, lowDisk, indexUnavailable, streamEnded, writeFailed }
    var phase: Phase = .off
    var revision: UInt64 = 0
    var streamID: UUID?
    var segmentID: UUID?
    var startedAt: Date?
    var bytes: Int64 = 0
}

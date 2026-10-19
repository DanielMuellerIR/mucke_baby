import Foundation

struct RecordingState: Equatable, Sendable {
    struct Rollover: Equatable, Sendable {
        var title: String
        var receivedAt: Date
    }
    enum Phase: Equatable, Sendable { case off, waiting, needsStreamHeader, recording, lowDisk, indexUnavailable, streamEnded, writeFailed, unsupportedFormat }
    var phase: Phase = .off
    var revision: UInt64 = 0
    var streamID: UUID?
    var segmentID: UUID?
    var startedAt: Date?
    var bytes: Int64 = 0
    var rollover: Rollover?
}

enum StreamCapturePolicy {
    static let hlsContentType = "application/vnd.apple.mpegurl"

    static func isHLS(_ contentType: String?, url: URL? = nil) -> Bool {
        if url?.path.lowercased().hasSuffix(".m3u8") == true { return true }
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return [hlsContentType, "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(type)
    }
}

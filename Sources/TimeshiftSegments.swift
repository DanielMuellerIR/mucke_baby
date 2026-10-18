import Foundation
import Darwin

enum TimeshiftSegmentFailure: Error, Equatable {
    case readerOverrun, formatChanged, tooManyReaders, invalidStorage
}

struct TimeshiftSegmentLimits {
    let duration: TimeInterval
    let bytes: Int
    let segmentDuration: TimeInterval
    let minimumFreeBytes: Int64

    init(duration: TimeInterval = 300, bytes: Int = 32 * 1024 * 1024,
         segmentDuration: TimeInterval = 2, minimumFreeBytes: Int64 = 10 * 1024 * 1024 * 1024) {
        precondition(duration.isFinite && (2...300).contains(duration))
        precondition((16_384...32 * 1024 * 1024).contains(bytes))
        precondition(segmentDuration.isFinite && (0.1...2).contains(segmentDuration))
        precondition(minimumFreeBytes >= 0)
        self.duration = duration; self.bytes = bytes; self.segmentDuration = segmentDuration
        self.minimumFreeBytes = minimumFreeBytes
    }
}

struct TimeshiftSegment: Codable {
    let id: Int
    let file: String
    let start: TimeInterval
    var end: TimeInterval
    let prefixBytes: Int
    let prefixDuration: TimeInterval
    var audioBytes: Int
    var titles: [TimeshiftTitleEntry]
    var fileBytes: Int { prefixBytes + audioBytes }
}

struct TimeshiftTitleEntry: Codable {
    let offset: TimeInterval
    let raw: String
    var receivedAt: Date? = nil
}

// Der Index dient der Diagnose, niemals der Wiederaufnahme alter Audiodaten.
// Ausschließlich eigene, exklusiv gesperrte Sitzungsverzeichnisse werden entfernt.
final class TimeshiftSegments {
    struct Metrics {
        let bytes: Int
        let oldest: TimeInterval
        let live: TimeInterval
        let segments: Int
        let readers: Int
        var duration: TimeInterval { live - oldest }
    }
    private struct Cursor { var segment: Int; var offset: Int; var cancelled = false }
    private let condition = NSCondition()
    private(set) var directory: URL
    let limits: TimeshiftSegmentLimits
    private let freeBytes: (URL) -> Int64
    private var ownership: Int32 = -1
    private var segments: [TimeshiftSegment] = []
    private var cursors: [UUID: Cursor] = [:]
    private var writer: FileHandle?
    private var pending = Data()
    private var preroll: [(Data, TimeInterval)] = []
    private var format: Int?
    private var frameDuration: TimeInterval = 0
    private var accepted = false
    private var closed = false
    private var receptionEnded = false
    private var nextID = 0
    private var storedBytes = 0
    private var live: TimeInterval = 0
    private var title = ""
    private var pendingTitle = ""
    private var titleReceivedAt: Date?
    private var pendingTitleReceivedAt: Date?
    private var discarded = 0

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby/Timeshift-v1", isDirectory: true)
    }

    init(root: URL = TimeshiftSegments.defaultRoot, limits: TimeshiftSegmentLimits = TimeshiftSegmentLimits(),
         freeBytes: ((URL) -> Int64)? = nil) throws {
        self.limits = limits
        self.freeBytes = freeBytes ?? { url in
            ((try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        }
        try Self.prepareRoot(root)
        let management = try Self.lockRoot(root)
        defer { Darwin.close(management) }
        try Self.cleanupUnlocked(root: root)
        let sessionID = UUID().uuidString
        directory = root.appendingPathComponent(".creating-" + sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        ownership = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownership >= 0, flock(ownership, LOCK_EX | LOCK_NB) == 0 else {
            if ownership >= 0 { Darwin.close(ownership) }
            ownership = -1; throw TimeshiftSegmentFailure.invalidStorage
        }
        do {
            try Data("MuckeTimeshift-v1".utf8).write(to: directory.appendingPathComponent("owner"))
            guard self.freeBytes(directory) >= limits.minimumFreeBytes else { throw TimeshiftFailure.lowDisk }
            try writeIndex()
            let ready = root.appendingPathComponent(sessionID, isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: ready)
            directory = ready
        } catch {
            try? FileManager.default.removeItem(at: directory)
            Darwin.close(ownership); ownership = -1; throw error
        }
    }

    deinit { try? close(); if ownership >= 0 { Darwin.close(ownership) } }

    private static func prepareRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let info = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw TimeshiftSegmentFailure.invalidStorage }
    }

    private static func lockRoot(_ root: URL) throws -> Int32 {
        let fd = Darwin.open(root.appendingPathComponent("manager.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TimeshiftSegmentFailure.invalidStorage }
        guard flock(fd, LOCK_EX) == 0 else { Darwin.close(fd); throw TimeshiftSegmentFailure.invalidStorage }
        return fd
    }
    static func cleanupAbandoned(root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw TimeshiftSegmentFailure.invalidStorage }
        let management = try lockRoot(root)
        defer { Darwin.close(management) }
        try cleanupUnlocked(root: root)
    }
    private static func cleanupUnlocked(root: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let name = child.lastPathComponent
            let creating = name.hasPrefix(".creating-") && UUID(uuidString: String(name.dropFirst(10))) != nil
            guard UUID(uuidString: name) != nil || creating,
                  try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let owned = (try? Data(contentsOf: child.appendingPathComponent("owner"))) == Data("MuckeTimeshift-v1".utf8)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
            // Vor der atomaren Freigabe können nach einem Crash nur diese
            // leeren Verwaltungsdateien existieren, noch keine Audiosegmente.
            guard owned || (creating && Set(contents).isSubset(of: ["owner", "owner.lock", "index.json"])) else { continue }
            let fd = Darwin.open(child.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if creating && contents.isEmpty { try FileManager.default.removeItem(at: child) }
                continue
            }
            defer { Darwin.close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try FileManager.default.removeItem(at: child) }
        }
    }

    func accept(contentType: String?) throws {
        try locked {
            guard !closed && !receptionEnded else { throw TimeshiftFailure.closed }
            let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "audio/mpeg" || type == "audio/mp3" else { throw TimeshiftFailure.unsupportedFormat }
            accepted = true
        }
    }

    func noteTitle(_ value: String, at date: Date? = nil) { locked {
        title = String(decoding: Array(value.utf8.prefix(1024)), as: UTF8.self)
        titleReceivedAt = date
    } }

    func append(_ data: Data) throws {
        try locked {
            guard !closed && !receptionEnded else { throw TimeshiftFailure.closed }
            guard accepted else { throw TimeshiftFailure.unsupportedFormat }
            guard freeBytes(directory) >= limits.minimumFreeBytes else { throw TimeshiftFailure.lowDisk }
            for offset in stride(from: 0, to: data.count, by: 4096) {
                if pending.isEmpty { pendingTitle = title; pendingTitleReceivedAt = titleReceivedAt }
                pending.append(data.subdata(in: data.startIndex + offset..<data.startIndex + min(offset + 4096, data.count)))
                while pending.count >= 4 {
                    guard let header = MP3FrameHeader(Array(pending.prefix(4))) else {
                        // Nur vor dem ersten Frame ist ein begrenzter Tag-/Header-Vorlauf erlaubt.
                        guard format == nil, discarded < 65_536 else { throw TimeshiftFailure.invalidAudio }
                        pending.removeFirst(); discarded += 1; continue
                    }
                    guard format == nil || format == header.format else { throw TimeshiftSegmentFailure.formatChanged }
                    guard pending.count >= header.bytes else { break }
                    let frame = Data(pending.prefix(header.bytes))
                    try store(frame, duration: header.duration, title: pendingTitle, receivedAt: pendingTitleReceivedAt)
                    format = header.format; pending.removeFirst(header.bytes); pendingTitle = title
                    frameDuration = header.duration
                    pendingTitleReceivedAt = titleReceivedAt
                }
            }
            condition.broadcast()
        }
    }

    var metrics: Metrics { locked {
        Metrics(bytes: storedBytes, oldest: segments.first.map { $0.start - $0.prefixDuration } ?? live, live: live,
                segments: segments.count, readers: cursors.count)
    } }
    var index: [TimeshiftSegment] { locked { segments } }

    var timeline: MetadataTimeline { locked {
        var anchors: [MetadataAnchor] = []
        for segment in segments {
            for entry in segment.titles where anchors.last?.title != entry.raw {
                anchors.append(MetadataAnchor(position: segment.start + entry.offset, title: entry.raw, receivedAt: entry.receivedAt))
            }
        }
        // Die erste Netzwerkaudiosekunde kann noch einen fremden MP3-Reservoir
        // benötigen. Sie dient nur dem Decoder, nie als Produktions-Hörziel.
        let oldest = segments.first.map { first in
            min(live, first.start + (first.prefixDuration == 0 ? ceil(1 / frameDuration) * frameDuration : 0))
        } ?? live
        if let initial = anchors.last(where: { $0.position <= oldest }) {
            anchors.removeAll(where: { $0.position <= oldest })
            anchors.insert(MetadataAnchor(position: oldest, title: initial.title, receivedAt: initial.receivedAt), at: 0)
        }
        return MetadataTimeline(oldest: oldest, live: live, bytes: storedBytes, titles: anchors)
    } }

    func makeReader(delay: TimeInterval) throws -> TimeshiftSegmentStream {
        guard delay.isFinite, delay > 0 else { throw TimeshiftFailure.notReady }
        return try makeReader(at: metrics.live - delay)
    }

    func makeReader(at position: TimeInterval) throws -> TimeshiftSegmentStream {
        try locked {
            guard !closed && !receptionEnded else { throw TimeshiftFailure.closed }
            guard position.isFinite, let first = segments.first else { throw TimeshiftFailure.notReady }
            guard cursors.isEmpty else { throw TimeshiftSegmentFailure.tooManyReaders }
            let reserve = min(MetadataTimeline.startReserve, limits.duration / 2)
            guard live - first.start + 0.000001 >= reserve else { throw TimeshiftFailure.notReady }
            let requested = min(live - reserve, max(first.start, position))
            let chosen = segments.last(where: { $0.start <= requested }) ?? first
            // VLC braucht neben Decoder-Vorlauf eine echte Startreserve.
            // Kleine Fixture-Fenster behalten mindestens ihr halbes Fenster.
            guard live - requested + 0.000001 >= reserve else { throw TimeshiftFailure.notReady }
            let target = chosen.start + floor((requested - chosen.start) / frameDuration + 0.000001) * frameDuration
            let id = UUID()
            cursors[id] = Cursor(segment: chosen.id, offset: 0)
            return TimeshiftSegmentStream(buffer: self, id: id, start: chosen.start - chosen.prefixDuration,
                                          decoderPreroll: chosen.prefixDuration, playbackStart: target, frameDuration: frameDuration)
        }
    }

    fileprivate func read(_ id: UUID, into output: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        while let cursor = cursors[id], !cursor.cancelled, !closed {
            guard let slot = segments.firstIndex(where: { $0.id == cursor.segment }) else { return -1 }
            let segment = segments[slot]
            if cursor.offset < segment.fileBytes {
                do {
                    let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(segment.file))
                    defer { try? file.close() }
                    try file.seek(toOffset: UInt64(cursor.offset))
                    let bytes = try file.read(upToCount: min(count, 65_536, segment.fileBytes - cursor.offset)) ?? Data()
                    guard !bytes.isEmpty else { return -1 }
                    bytes.copyBytes(to: output, count: bytes.count)
                    cursors[id]?.offset += bytes.count
                    return bytes.count
                } catch { return -1 }
            }
            if slot + 1 < segments.count {
                let next = segments[slot + 1]
                // Nur beim Einstieg wird der Decoder-Vorlauf gelesen. Fortlaufende
                // Wiedergabe erhält jeden ursprünglichen Frame genau einmal.
                cursors[id] = Cursor(segment: next.id, offset: next.prefixBytes)
                continue
            }
            if receptionEnded { return 0 }
            condition.wait()
        }
        return 0
    }

    fileprivate func release(_ id: UUID) {
        locked {
            cursors.removeValue(forKey: id); condition.broadcast()
            if closed && cursors.isEmpty { try? removeDirectory() }
        }
    }

    func finishReception() throws { try locked {
        receptionEnded = true
        try writer?.synchronize(); try writeIndex(); condition.broadcast()
    } }

    func cancelReaders() { locked {
        for id in cursors.keys { cursors[id]?.cancelled = true }
        condition.broadcast()
    } }

    func close() throws {
        try locked {
            closed = true; condition.broadcast()
            try writer?.close(); writer = nil; pending.removeAll(); preroll.removeAll()
            if cursors.isEmpty { try removeDirectory() }
        }
    }

    private func store(_ frame: Data, duration: TimeInterval, title: String, receivedAt: Date?) throws {
        let roll = segments.last.map { live - $0.start + duration > limits.segmentDuration || $0.audioBytes + frame.count > 65_536 } ?? true
        let prefix = roll ? preroll.reduce(into: Data()) { $0.append($1.0) } : Data()
        let added = frame.count + prefix.count
        while let first = segments.first,
              storedBytes + added > limits.bytes || live + duration - (first.start - first.prefixDuration) > limits.duration || (roll && segments.count >= 256) {
            guard !cursors.values.contains(where: { $0.segment == first.id }) else { throw TimeshiftSegmentFailure.readerOverrun }
            // Der offene Schreibabschnitt kann bei sehr kleinen Limits ebenfalls auslaufen.
            guard roll || segments.count > 1 else { throw TimeshiftFailure.notReady }
            if segments.count == 1 { try writer?.close(); writer = nil }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(first.file))
            storedBytes -= first.fileBytes; segments.removeFirst()
        }
        guard added <= limits.bytes else { throw TimeshiftFailure.notReady }
        if roll || writer == nil {
            try writer?.synchronize(); try writer?.close(); writer = nil
            let name = String(format: "%08d.mp3", nextID)
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            writer = try FileHandle(forWritingTo: url)
            try writer?.write(contentsOf: prefix)
            segments.append(TimeshiftSegment(id: nextID, file: name, start: live, end: live,
                prefixBytes: prefix.count, prefixDuration: roll ? preroll.reduce(0, { $0 + $1.1 }) : 0, audioBytes: 0, titles: []))
            nextID += 1; storedBytes += prefix.count
        }
        let slot = segments.count - 1
        if segments[slot].titles.last?.raw != title && segments[slot].titles.count >= 64 { throw TimeshiftFailure.invalidAudio }
        try writer?.write(contentsOf: frame)
        if segments[slot].titles.last?.raw != title {
            segments[slot].titles.append(TimeshiftTitleEntry(offset: live - segments[slot].start, raw: title, receivedAt: receivedAt))
        }
        live += duration; storedBytes += frame.count
        segments[slot].end = live; segments[slot].audioBytes += frame.count
        preroll.append((frame, duration))
        while preroll.reduce(0, { $0 + $1.1 }) > 1 || preroll.reduce(0, { $0 + $1.0.count }) > 65_536 { preroll.removeFirst() }
        // Maximal 256 Abschnitte mit höchstens zwei Sekunden Titelankern.
        // Atomarer Index am Segmentwechsel; Crash-Recovery liest ihn nie ein.
        if roll { try writeIndex() }
    }

    private func writeIndex() throws {
        let data = try JSONEncoder().encode(segments)
        guard data.count <= 1_048_576 else { throw TimeshiftFailure.invalidAudio }
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
    private func removeDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if ownership >= 0 { Darwin.close(ownership); ownership = -1 }
        segments.removeAll(); storedBytes = 0
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock(); defer { condition.unlock() }; return try body()
    }
}

final class TimeshiftSegmentStream: InputStream {
    private let buffer: TimeshiftSegments
    private let id: UUID
    let start: TimeInterval
    let decoderPreroll: TimeInterval
    let playbackStart: TimeInterval
    private let frameDuration: TimeInterval
    var mediaOptions: [String] {
        var options = [":demux=mpga", ":file-caching=1000"]
        let frames = Int(((playbackStart - start) / frameDuration).rounded())
        if frames > 0 {
            // Beim gepinnten VLC verschiebt audio-desync die Ausgabe nach der
            // Decodierung. Zwei zusätzliche Frames kompensieren den gemessenen
            // Startversatz; das native Seek-Gate prüft diese Bindung an VLCKit.
            let milliseconds = Int((Double(frames + 2) * frameDuration * 1000).rounded(.down))
            options.append(":audio-desync=-\(milliseconds)")
        }
        return options
    }
    private let state = NSLock()
    private var status: Stream.Status = .notOpen
    init(buffer: TimeshiftSegments, id: UUID, start: TimeInterval, decoderPreroll: TimeInterval,
         playbackStart: TimeInterval, frameDuration: TimeInterval) {
        self.buffer = buffer; self.id = id; self.start = start; self.decoderPreroll = decoderPreroll
        self.playbackStart = playbackStart; self.frameDuration = frameDuration
        super.init(data: Data())
    }
    deinit { close() }
    override func open() { state.lock(); if status == .notOpen { status = .open }; state.unlock() }
    override func close() { state.lock(); status = .closed; state.unlock(); buffer.release(id) }
    override var streamStatus: Stream.Status { state.lock(); defer { state.unlock() }; return status }
    override var hasBytesAvailable: Bool { streamStatus == .open }
    override func read(_ output: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0, streamStatus == .open else { return 0 }
        let result = buffer.read(id, into: output, count: len)
        state.lock()
        if status != .closed { if result == 0 { status = .atEnd } else if result < 0 { status = .error } }
        state.unlock()
        return result
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}

import Foundation

enum TimeshiftFailure: Error, Equatable {
    case unsupportedFormat, invalidAudio, lowDisk, notReady, snapshotInUse, closed
}

struct TimeshiftLimits {
    let duration: TimeInterval
    let compressedBytes: Int
    let minimumFreeBytes: Int64

    init(duration: TimeInterval = 30, compressedBytes: Int = 2 * 1024 * 1024,
         minimumFreeBytes: Int64 = 10 * 1024 * 1024 * 1024) {
        precondition(duration.isFinite && (2...300).contains(duration))
        precondition((16_384...8 * 1024 * 1024).contains(compressedBytes))
        precondition(minimumFreeBytes >= 0)
        self.duration = duration; self.compressedBytes = compressedBytes
        self.minimumFreeBytes = minimumFreeBytes
    }
}

struct TimeshiftTitle: Equatable {
    let offset: TimeInterval
    let raw: String
}

struct TimeshiftSnapshot {
    let id: UUID
    let url: URL
    let start: TimeInterval
    let end: TimeInterval
    let bytes: Int
    let titles: [TimeshiftTitle]
    var duration: TimeInterval { end - start }

    func title(at seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        return titles.last(where: { $0.offset <= max(0, seconds) })?.raw ?? ""
    }
}

struct TimeshiftMetrics {
    let bufferedBytes: Int
    let snapshotBytes: Int
    let pendingBytes: Int
    let oldest: TimeInterval
    let live: TimeInterval
    var duration: TimeInterval { live - oldest }
}

struct TimeshiftEndGuard {
    private var lastPosition: TimeInterval = 0
    private var lastAdvance: TimeInterval?

    mutating func reset() { lastPosition = 0; lastAdvance = nil }

    // Der lokale VLC-Ausgang kann nach langer Pause vor seinem EOF-Ereignis
    // stehen bleiben. Nur die letzte halbe Sekunde eines bekannten Ausschnitts
    // darf nach zwei Sekunden ohne Fortschritt kontrolliert beendet werden.
    mutating func observe(position: TimeInterval, duration: TimeInterval, uptime: TimeInterval) -> Bool {
        guard position.isFinite, duration.isFinite, uptime.isFinite, duration > 0, position >= 0 else { return false }
        if lastAdvance == nil || position > lastPosition + 0.01 || uptime < lastAdvance! {
            lastPosition = position; lastAdvance = uptime; return false
        }
        return position >= max(0.5, duration - 0.5) && uptime - lastAdvance! >= 2
    }
}

// Vollständige MP3-Frames im begrenzten RAM-Puffer, genau ein lokaler
// Wiedergabeausschnitt. Der Ausschnitt bleibt während Pause/Abspielen unverändert.
// Empfangs- und Wiedergabezeit sind getrennt; ICY markiert die nächste Framegrenze.
final class TimeshiftBuffer {
    private struct Frame {
        let data: Data
        let start: TimeInterval
        let duration: TimeInterval
        let title: String
    }

    let limits: TimeshiftLimits
    let directory: URL
    private let lock = NSLock()
    private let freeBytes: (URL) -> Int64
    private var frames: [Frame] = []
    private var pending = Data()
    private var storedBytes = 0
    private var discardedBytes = 0
    private var live: TimeInterval = 0
    private var title = ""
    private var pendingTitle = ""
    private var formatAccepted = false
    private var closed = false
    private var snapshot: TimeshiftSnapshot?

    init(parentDirectory: URL = FileManager.default.temporaryDirectory,
         limits: TimeshiftLimits = TimeshiftLimits(), freeBytes: ((URL) -> Int64)? = nil) throws {
        self.limits = limits
        self.freeBytes = freeBytes ?? { url in
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        directory = parentDirectory.appendingPathComponent("MuckeTimeshift-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard self.freeBytes(directory) >= limits.minimumFreeBytes else {
            try FileManager.default.removeItem(at: directory)
            throw TimeshiftFailure.lowDisk
        }
    }

    deinit { try? close() }

    func accept(contentType: String?) throws {
        try locked {
            guard !closed else { throw TimeshiftFailure.closed }
            let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "audio/mpeg" || type == "audio/mp3" else { throw TimeshiftFailure.unsupportedFormat }
            formatAccepted = true
        }
    }

    func noteTitle(_ raw: String) {
        locked { if !closed { title = String(raw.prefix(1024)) } }
    }

    func append(_ data: Data) throws {
        try locked {
            guard !closed else { throw TimeshiftFailure.closed }
            guard formatAccepted else { throw TimeshiftFailure.unsupportedFormat }
            guard freeBytes(directory) >= limits.minimumFreeBytes else { throw TimeshiftFailure.lowDisk }
            // Auch eine einzelne große URLSession-Lieferung darf den Parserpuffer
            // nicht vergrößern. Ein MP3-Frame ist hier höchstens 2.881 Bytes lang.
            for offset in stride(from: 0, to: data.count, by: 4096) {
                if pending.isEmpty { pendingTitle = title }
                let lower = data.startIndex + offset
                let upper = data.startIndex + min(offset + 4096, data.count)
                pending.append(data.subdata(in: lower..<upper))
                try parseFrames()
            }
        }
    }

    var metrics: TimeshiftMetrics {
        locked { TimeshiftMetrics(bufferedBytes: storedBytes, snapshotBytes: snapshot?.bytes ?? 0,
                                  pendingBytes: pending.count, oldest: frames.first?.start ?? live, live: live) }
    }

    func makeSnapshot(delay: TimeInterval) throws -> TimeshiftSnapshot {
        try locked {
            guard !closed else { throw TimeshiftFailure.closed }
            guard snapshot == nil else { throw TimeshiftFailure.snapshotInUse }
            guard delay.isFinite, delay > 0, let oldest = frames.first else { throw TimeshiftFailure.notReady }
            guard freeBytes(directory) >= limits.minimumFreeBytes else { throw TimeshiftFailure.lowDisk }
            let requested = max(oldest.start, live - delay)
            // Auf die erste vollständige Framegrenze hinter dem gewünschten Punkt.
            let selection = frames.filter { $0.start >= requested }
            guard let first = selection.first, live - first.start >= 0.5 else { throw TimeshiftFailure.notReady }
            let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".mp3")
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                for frame in selection { try handle.write(contentsOf: frame.data) }
                try handle.synchronize()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            var titles: [TimeshiftTitle] = []
            for frame in selection where titles.last?.raw != frame.title {
                titles.append(TimeshiftTitle(offset: frame.start - first.start, raw: frame.title))
            }
            let value = TimeshiftSnapshot(id: id, url: url, start: first.start, end: live,
                                         bytes: selection.reduce(0) { $0 + $1.data.count }, titles: titles)
            snapshot = value
            return value
        }
    }

    // Erst nach dem vollständigen Stop des VLC-Lesers aufrufen.
    func releaseSnapshot(_ id: UUID) throws {
        try locked {
            guard let value = snapshot, value.id == id else { return }
            try FileManager.default.removeItem(at: value.url)
            snapshot = nil
        }
    }

    func close() throws {
        try locked {
            guard !closed else { return }
            // Ausschließlich die bei init neu erzeugte private Wurzel entfernen.
            // Kein Aufnahmen-/Verlaufspfad wird angenommen oder durchsucht.
            try FileManager.default.removeItem(at: directory)
            closed = true; snapshot = nil; frames.removeAll(); pending.removeAll(); storedBytes = 0
        }
    }

    private func parseFrames() throws {
        while pending.count >= 4 {
            let bytes = [UInt8](pending.prefix(4))
            guard let header = MP3FrameHeader(bytes) else {
                pending.removeFirst(); discardedBytes += 1
                guard discardedBytes <= 65_536 else { throw TimeshiftFailure.invalidAudio }
                continue
            }
            guard pending.count >= header.bytes else { return }
            let frame = Data(pending.prefix(header.bytes)); pending.removeFirst(header.bytes)
            discardedBytes = 0
            frames.append(Frame(data: frame, start: live, duration: header.duration, title: pendingTitle))
            pendingTitle = title
            storedBytes += frame.count; live += header.duration
            while let first = frames.first,
                  storedBytes > limits.compressedBytes || live - first.start > limits.duration {
                storedBytes -= first.data.count; frames.removeFirst()
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

struct MP3FrameHeader {
    let bytes: Int
    let duration: TimeInterval
    let format: Int

    init?(_ header: [UInt8]) {
        guard header.count == 4, header[0] == 0xff, header[1] & 0xe0 == 0xe0,
              header[1] & 0x06 == 0x02 else { return nil } // Layer III
        let version = Int((header[1] >> 3) & 3)
        let bitrateIndex = Int(header[2] >> 4), rateIndex = Int((header[2] >> 2) & 3)
        guard version != 1, (1...14).contains(bitrateIndex), rateIndex < 3,
              header[3] & 3 != 2 else { return nil }
        let rates = [44_100, 48_000, 32_000]
        let rate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let mpeg1 = [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320]
        let mpeg2 = [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]
        let bitrate = (version == 3 ? mpeg1 : mpeg2)[bitrateIndex] * 1000
        bytes = (version == 3 ? 144 : 72) * bitrate / rate + Int((header[2] >> 1) & 1)
        duration = Double(version == 3 ? 1152 : 576) / Double(rate)
        format = rate * 10 + version * 2 + (header[3] >> 6 == 3 ? 1 : 0)
    }
}

struct ADTSFrameHeader {
    let bytes: Int
    let duration: TimeInterval
    let format: Int

    init?(_ header: [UInt8]) {
        guard header.count >= 7, header[0] == 0xff, header[1] & 0xf6 == 0xf0,
              header[2] >> 6 == 1, header[6] & 3 == 0 else { return nil }
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        let index = Int((header[2] >> 2) & 15)
        let channels = Int((header[2] & 1) << 2 | header[3] >> 6)
        guard index < rates.count, (1...2).contains(channels) else { return nil }
        bytes = Int(header[3] & 3) << 11 | Int(header[4]) << 3 | Int(header[5] >> 5)
        guard bytes > (header[1] & 1 == 0 ? 9 : 7) else { return nil }
        // HE-AAC verdoppelt Ausgaberate und Samples; die ADTS-Kernzeit bleibt gleich.
        duration = 1024 / Double(rates[index])
        format = rates[index] * 10 + Int((header[1] >> 3) & 1) * 4 + channels
    }
}

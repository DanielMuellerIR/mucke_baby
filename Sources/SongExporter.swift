import Foundation
import AVFoundation
import Darwin

// Schneidet einen Song aus einer Aufnahme-Datei heraus (Zeitfenster), optional
// mit Ein-/Ausblendung, und exportiert als .m4a. Die lesbaren Quellcodecs
// hängen von der macOS-Version ab; unlesbare Dateien werden ohne Zieländerung abgewiesen.
enum SongExporter {
    enum Mode: Hashable, Sendable { case hardCut, faded }
    enum ExportError: LocalizedError {
        case tooShort, noSession, notReadable, failed(String)
        var errorDescription: String? {
            switch self {
            case .tooShort:    return String(localized: "Ausschnitt zu kurz.")
            case .noSession:   return String(localized: "Export nicht möglich.")
            case .notReadable: return String(localized: "Aufnahme nicht lesbar.")
            case .failed(let m): return m
            }
        }
    }

    static func inspect(source: URL) async throws -> ExportAudioBounds {
        try Task.checkCancellation()
        do {
            try validateAudioFile(source)
            let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw ExportError.notReadable }
            let range = try await track.load(.timeRange)
            try Task.checkCancellation()
            let start = max(0, CMTimeGetSeconds(range.start))
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite, end > start else { throw ExportError.notReadable }
            return ExportAudioBounds(start: start, end: end)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw ExportError.notReadable
        }
    }

    static func export(source: URL, offset: Double, duration: Double,
                       mode: Mode, metadata: SongExportMetadata? = nil,
                       replaceExisting: Bool = true, to dest: URL) async throws {
        try Task.checkCancellation()
        guard duration.isFinite, offset.isFinite, duration > 0.5 else { throw ExportError.tooShort }
        try protectSource(source, destination: dest)
        let asset = AVURLAsset(url: source)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        try Task.checkCancellation()
        guard !tracks.isEmpty else { throw ExportError.notReadable }
        // Wall-Clock-Zeit im Index kann durch Pufferung von der Medienlänge
        // abweichen. Auch der gefadete Schnitt darf nie hinter das Audioende greifen.
        let trackRange = try await tracks[0].load(.timeRange)
        let available = CMTimeGetSeconds(CMTimeRangeGetEnd(trackRange)) - max(0, offset)
        guard available.isFinite else { throw ExportError.notReadable }
        let duration = min(duration, available)
        guard duration > 0.5 else { throw ExportError.tooShort }
        let start = CMTime(seconds: max(0, offset), preferredTimescale: 600)
        let dur = CMTime(seconds: duration, preferredTimescale: 600)
        // Beide Modi schneiden dieselbe Medienzeit ab Null. Direktes Asset-Trim
        // verschob Codec-Vorlauf gegenüber dem Fade-Pfad und kürzte Ogg/Opus.
        let composition = AVMutableComposition()
        guard let mixTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.noSession
        }
        try mixTrack.insertTimeRange(CMTimeRange(start: start, duration: dur), of: tracks[0], at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.noSession
        }
        // Erst im Zielordner fertigstellen, dann atomar ersetzen. Fehler und
        // Abbruch dürfen weder die Aufnahme noch ein vorhandenes Exportziel löschen.
        let stagingDirectory = dest.deletingLastPathComponent()
            .appendingPathComponent(".mucke-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("audio.m4a")
        session.outputURL = staged
        session.outputFileType = .m4a
        if let metadata { session.metadata = metadataItems(metadata) }

        session.timeRange = CMTimeRange(start: .zero, duration: dur)

        if mode == .faded {
            let p = AVMutableAudioMixInputParameters(track: mixTrack)
            let fade = CMTime(seconds: min(2.0, duration / 4), preferredTimescale: 600)
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                            timeRange: CMTimeRange(start: .zero, duration: fade))
            let outStart = CMTimeSubtract(dur, fade)
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                            timeRange: CMTimeRange(start: outStart, duration: fade))
            let mix = AVMutableAudioMix(); mix.inputParameters = [p]
            session.audioMix = mix
        }

        let operation = ExportOperation(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        if session.status != .completed {
            throw ExportError.failed(session.error?.localizedDescription ?? String(localized: "Export fehlgeschlagen."))
        }
        let commit = PreparedExportCommit()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try protectSource(source, destination: dest)
            try commit.install(staged, at: dest, replaceExisting: replaceExisting)
        } onCancel: { commit.cancel() }
    }

    static func savePrepared(_ rendered: URL, originalSource source: URL, to dest: URL) async throws {
        try Task.checkCancellation()
        try protectSource(source, destination: dest)
        try protectSource(rendered, destination: dest)
        let staged = dest.deletingLastPathComponent().appendingPathComponent(".mucke-export-\(UUID().uuidString).m4a")
        let descriptor = open(staged.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close(); try? FileManager.default.removeItem(at: staged) }
        let reader = try FileHandle(forReadingFrom: rendered)
        defer { try? reader.close() }
        let commit = PreparedExportCommit()
        try await withTaskCancellationHandler {
            while let data = try reader.read(upToCount: 512 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            try writer.close()
            try Task.checkCancellation()
            try protectSource(source, destination: dest)
            try protectSource(rendered, destination: dest)
            try commit.install(staged, at: dest)
        } onCancel: { commit.cancel() }
    }

    private static func validateAudioFile(_ source: URL) throws {
        guard source.isFileURL else { throw ExportError.notReadable }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0,
              FileManager.default.isReadableFile(atPath: source.path) else { throw ExportError.notReadable }
    }

    private static func protectSource(_ source: URL, destination: URL) throws {
        let fm = FileManager.default
        guard source.isFileURL, destination.isFileURL else {
            throw ExportError.notReadable
        }
        try validateAudioFile(source)
        let samePath = source.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath()
        let src = try fm.attributesOfItem(atPath: source.path)
        let dst = try? fm.attributesOfItem(atPath: destination.path)
        // Auch zwei verschiedene Hardlink-Namen können dieselbe Aufnahme bezeichnen.
        let sameFile = dst != nil && src[.systemFileNumber] as? NSNumber == dst?[.systemFileNumber] as? NSNumber
            && src[.systemNumber] as? NSNumber == dst?[.systemNumber] as? NSNumber
        guard !samePath, !sameFile else {
            throw ExportError.failed(String(localized: "Exportziel darf nicht die Aufnahme sein."))
        }
    }

    static func safeFileBase(_ raw: String) -> String {
        ExportFileNaming.safeBase(raw)
    }

    static func exportUnique(source: URL, offset: Double, duration: Double, mode: Mode,
                             metadata: SongExportMetadata, directory: URL) async throws -> URL {
        let prepared = directory.appendingPathComponent(".mucke-batch-\(UUID().uuidString).m4a")
        var ownsPrepared = false
        defer { if ownsPrepared { try? FileManager.default.removeItem(at: prepared) } }
        try await export(source: source, offset: offset, duration: duration, mode: mode,
                         metadata: metadata, replaceExisting: false, to: prepared)
        ownsPrepared = true
        let commit = PreparedExportCommit()
        return try await withTaskCancellationHandler {
            for number in 1...10_000 {
                try Task.checkCancellation()
                let suffix = number == 1 ? "" : " (\(number))"
                let destination = directory.appendingPathComponent(metadata.fileBase + suffix + ".m4a")
                do {
                    try commit.install(prepared, at: destination, replaceExisting: false)
                    return destination
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                    continue
                }
            }
            throw ExportError.failed(String(localized: "Kein freier Dateiname für diesen Export gefunden."))
        } onCancel: { commit.cancel() }
    }

    private static func metadataItems(_ metadata: SongExportMetadata) -> [AVMetadataItem] {
        var values: [(AVMetadataIdentifier, String)] = [(.iTunesMetadataSongName, metadata.title),
                                                       (.iTunesMetadataUserComment, metadata.comment)]
        if let artist = metadata.artist { values.append((.iTunesMetadataArtist, artist)) }
        if !metadata.station.isEmpty { values.append((.iTunesMetadataAlbum, metadata.station)) }
        return values.map { key, value in
            let item = AVMutableMetadataItem()
            item.identifier = key; item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
    }

    static func exportTemporary(source: URL, offset: Double, duration: Double,
                                name: String, metadata: SongExportMetadata? = nil) async throws -> URL {
        let directory = try temporaryExports.makeDirectory()
        let destination = directory.appendingPathComponent(safeFileBase(name) + ".m4a")
        do {
            try await export(source: source, offset: offset, duration: duration, mode: .hardCut,
                             metadata: metadata, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // CoreTransferable liest nach Rückkehr der Export-Closure. Erfolgreiche
    // Drag-Dateien deshalb bis zum App-Ende behalten, nicht vor der Übernahme löschen.
    static func cleanupTemporaryExports() { temporaryExports.cleanup() }
    private static let temporaryExports = TemporaryExports()
}

// Abbruch und atomarer Austausch haben einen eindeutigen Gewinner. Nach erfolgreichem
// rename darf ein gleichzeitig eintreffender Abbruch keinen Fehlabschluss vortäuschen.
private final class PreparedExportCommit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func install(_ source: URL, at destination: URL, replaceExisting: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        let result = replaceExisting ? rename(source.path, destination.path)
            : renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private final class ExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let session: AVAssetExportSession
    private var cancelled = false
    init(_ session: AVAssetExportSession) { self.session = session }
    func start(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { continuation.resume(); return }
        session.exportAsynchronously { continuation.resume() }
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        session.cancelExport()
    }
}

private final class TemporaryExports: @unchecked Sendable {
    private let lock = NSLock()
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MuckeBaby-Exports-\(UUID().uuidString)", isDirectory: true)
    func makeDirectory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
    }
}

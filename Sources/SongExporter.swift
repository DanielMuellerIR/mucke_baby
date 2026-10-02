import Foundation
import AVFoundation
import Darwin

// Schneidet einen Song aus einer Aufnahme-Datei heraus (Zeitfenster), optional
// mit Ein-/Ausblendung, und exportiert als .m4a. Die lesbaren Quellcodecs
// hängen von der macOS-Version ab; unlesbare Dateien werden ohne Zieländerung abgewiesen.
enum SongExporter {
    enum Mode { case hardCut, faded }
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

    static func export(source: URL, offset: Double, duration: Double,
                       mode: Mode, to dest: URL) async throws {
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
        var exportAsset: AVAsset = asset
        var mixTrack = tracks[0]
        var outputStart = start
        if mode == .faded {
            // Die Rampen beziehen sich auf den ausgeschnittenen Song ab Zeit null.
            // Beim direkten Asset-Trim gelangte Decoder-Vorlauf laut in die Einblendung.
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.noSession
            }
            try track.insertTimeRange(CMTimeRange(start: start, duration: dur), of: tracks[0], at: .zero)
            exportAsset = composition
            mixTrack = track
            outputStart = .zero
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.noSession
        }
        // Erst im Zielordner fertigstellen, dann atomar ersetzen. Fehler und
        // Abbruch dürfen weder die Aufnahme noch ein vorhandenes Exportziel löschen.
        let staged = dest.deletingLastPathComponent()
            .appendingPathComponent(".mucke-export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        session.outputURL = staged
        session.outputFileType = .m4a

        session.timeRange = CMTimeRange(start: outputStart, duration: dur)

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
            throw ExportError.failed(session.error?.localizedDescription ?? "Export fehlgeschlagen.")
        }
        try protectSource(source, destination: dest)
        guard rename(staged.path, dest.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func protectSource(_ source: URL, destination: URL) throws {
        let fm = FileManager.default
        guard source.isFileURL, destination.isFileURL else {
            throw ExportError.notReadable
        }
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
        var safe = raw.replacingOccurrences(of: #"[^A-Za-z0-9 _.-]"#, with: "_",
                                            options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if safe.isEmpty || safe.hasPrefix(".") { safe = "Song_" + safe }
        // Ein einzelnes Pfadsegment bleibt auch bei sehr langen ICY-Titeln gültig.
        return String(safe.prefix(180))
    }

    static func exportTemporary(source: URL, offset: Double, duration: Double,
                                name: String) async throws -> URL {
        let directory = try temporaryExports.makeDirectory()
        let destination = directory.appendingPathComponent(safeFileBase(name) + ".m4a")
        do {
            try await export(source: source, offset: offset, duration: duration, mode: .hardCut, to: destination)
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

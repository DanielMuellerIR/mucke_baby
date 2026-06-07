import Foundation
import AVFoundation

// Schneidet einen Song aus einer Aufnahme-Datei heraus (Zeitfenster), optional
// mit Ein-/Ausblendung, und exportiert als .m4a. mp3/aac werden nativ gelesen;
// ogg/opus kann AVFoundation NICHT -> Fehler (dafuer braeuchte es ffmpeg).
enum SongExporter {
    enum Mode { case hardCut, faded }
    enum ExportError: LocalizedError {
        case tooShort, noSession, notReadable, failed(String)
        var errorDescription: String? {
            switch self {
            case .tooShort:    return String(localized: "Ausschnitt zu kurz.")
            case .noSession:   return String(localized: "Export nicht möglich.")
            case .notReadable: return String(localized: "Aufnahme nicht lesbar (ogg/opus brauchen ffmpeg).")
            case .failed(let m): return m
            }
        }
    }

    static func export(source: URL, offset: Double, duration: Double,
                       mode: Mode, to dest: URL) async throws {
        guard duration > 0.5 else { throw ExportError.tooShort }
        let asset = AVURLAsset(url: source)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw ExportError.notReadable }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.noSession
        }
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .m4a

        let start = CMTime(seconds: max(0, offset), preferredTimescale: 600)
        let dur = CMTime(seconds: duration, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, duration: dur)

        if mode == .faded, let track = tracks.first {
            let p = AVMutableAudioMixInputParameters(track: track)
            let fade = CMTime(seconds: min(2.0, duration / 4), preferredTimescale: 600)
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                            timeRange: CMTimeRange(start: start, duration: fade))
            let outStart = CMTimeSubtract(CMTimeAdd(start, dur), fade)
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                            timeRange: CMTimeRange(start: outStart, duration: fade))
            let mix = AVMutableAudioMix(); mix.inputParameters = [p]
            session.audioMix = mix
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if session.status != .completed {
            throw ExportError.failed(session.error?.localizedDescription ?? "Export fehlgeschlagen.")
        }
    }
}

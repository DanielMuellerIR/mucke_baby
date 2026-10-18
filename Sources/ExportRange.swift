import Foundation

struct ExportAudioBounds: Equatable, Sendable {
    let start: Double
    let end: Double
}

struct ExportCut: Hashable, Sendable {
    let start: Double
    let end: Double
    var duration: Double { end - start }
}

enum ExportRangeError: LocalizedError {
    case invalidValue, outsideAudio, tooShort
    var errorDescription: String? {
        switch self {
        case .invalidValue: return String(localized: "Bitte gültige Sekundenwerte eingeben.")
        case .outsideAudio: return String(localized: "Der Ausschnitt muss innerhalb des verfügbaren Audios liegen.")
        case .tooShort: return String(localized: "Der Ausschnitt muss länger als 0,5 Sekunden sein.")
        }
    }
}

struct ExportRange: Sendable {
    let audio: ExportAudioBounds
    let baseline: ExportCut
    let isPartial: Bool

    init(offset: Double, duration: Double, audio: ExportAudioBounds) throws {
        guard offset.isFinite, duration.isFinite, audio.start.isFinite, audio.end.isFinite,
              offset >= 0, duration > 0, audio.start >= 0, audio.end > audio.start,
              (offset + duration).isFinite else { throw ExportRangeError.invalidValue }
        self.audio = audio
        let start = min(audio.end, max(audio.start, offset))
        let end = min(audio.end, max(start, offset + duration))
        baseline = ExportCut(start: start, end: end)
        isPartial = start != offset || end != offset + duration
    }

    func cut(startAdjustment: Double, endAdjustment: Double) throws -> ExportCut {
        let start = baseline.start + startAdjustment
        let end = baseline.end + endAdjustment
        guard start.isFinite, end.isFinite else { throw ExportRangeError.invalidValue }
        guard start >= audio.start, start <= audio.end, end >= audio.start, end <= audio.end else {
            throw ExportRangeError.outsideAudio
        }
        guard end - start > 0.5 else { throw ExportRangeError.tooShort }
        return ExportCut(start: start, end: end)
    }
}

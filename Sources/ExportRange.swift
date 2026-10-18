import Foundation

enum ExportAdjustmentText {
    static func parse(_ text: String, locale: Locale) -> Double? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf8.count <= 64 else { return nil }
        var sign = ""
        if body.first == "-" || body.first == "+" { sign = String(body.removeFirst()) }
        let separator = locale.decimalSeparator ?? "."
        let parts = body.components(separatedBy: separator)
        func digits(_ value: String) -> Bool { value.allSatisfy { $0 >= "0" && $0 <= "9" } }
        guard parts.count <= 2, parts.allSatisfy(digits),
              !parts[0].isEmpty || parts.count == 2,
              parts.count == 1 || !parts[1].isEmpty else { return nil }
        let normalized = sign + body.replacingOccurrences(of: separator, with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...2)).grouping(.never))
    }
}

enum ExportTimeText {
    static func format(_ value: Double, locale: Locale) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max / 100) else { return "—" }
        let units = Int((value * 100).rounded())
        let hours = units / 360_000, minutes = units / 6_000 % 60, seconds = units / 100 % 60
        return "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
            + (locale.decimalSeparator ?? ".") + String(format: "%02d", units % 100)
    }
}

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

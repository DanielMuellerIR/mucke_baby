import Foundation

struct RecognitionContext: Equatable, Sendable {
    let generation: UInt64
    let stationID: UUID
    let title: String
    var listening: RecognitionListeningContext? = nil

    // Position und Empfangszeit sind ein eingefrorener Beleg des Aufrufs.
    // Normales Weiterhören ändert sie, aber beendet nicht denselben Ausschnitt.
    func isCurrent(_ current: RecognitionContext?) -> Bool {
        guard let current else { return false }
        return generation == current.generation && stationID == current.stationID
            && title == current.title && listening?.outputID == current.listening?.outputID
    }
}

struct RecognizedTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let shazamID: String?
    let appleMusicURL: URL?

    init?(title: String?, artist: String?, shazamID: String?, appleMusicURL: URL?) {
        let cleanTitle = Self.clean(title)
        guard !cleanTitle.isEmpty else { return nil }
        self.title = cleanTitle; self.artist = Self.clean(artist)
        let id = Self.clean(shazamID, byteLimit: 256); self.shazamID = id.isEmpty ? nil : id
        self.appleMusicURL = SongRecognition.safeAppleMusicURL(appleMusicURL)
    }

    private static func clean(_ value: String?, byteLimit: Int = 1024) -> String {
        let filtered = (value ?? "").unicodeScalars.prefix(4096)
            .filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        var result = "", bytes = 0
        for character in filtered.prefix(256) {
            let count = String(character).utf8.count
            guard bytes + count <= byteLimit else { break }
            result.append(character); bytes += count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RecognitionResult: Equatable, Sendable {
    let track: RecognizedTrack
    let context: RecognitionContext
    let capturedAt: Date
    let recognizedAt: Date
}

enum RecognitionFailure: Error, LocalizedError, Equatable, Sendable {
    case noPlayback, muted, audioUnavailable, audioChanged, notEnoughAudio, invalidAudio, silent, offline, serviceUnavailable, timedOut, playbackChanged
    var errorDescription: String? {
        switch self {
        case .noPlayback: return String(localized: "Für die Erkennung muss Audio spielen. Starte einen Sender oder setze die Wiedergabe fort.")
        case .muted: return String(localized: "Die Wiedergabe ist stumm. Erhöhe die Lautstärke für die Erkennung.")
        case .audioUnavailable: return String(localized: "Audiozugriff nicht verfügbar. Prüfe die Audiofreigabe in den Systemeinstellungen und starte den Sender erneut.")
        case .audioChanged: return String(localized: "Der Audiozugriff wurde unterbrochen. Bitte erneut versuchen.")
        case .notEnoughAudio: return String(localized: "Der hörbare Ausschnitt war zu kurz. Bitte erneut versuchen.")
        case .invalidAudio: return String(localized: "Dieser Audioausschnitt konnte nicht erkannt werden.")
        case .silent: return String(localized: "Kein hörbares Audio erkannt.")
        case .offline: return String(localized: "Keine Internetverbindung. Bitte verbinden und erneut versuchen.")
        case .serviceUnavailable: return String(localized: "Musikerkennung ist derzeit nicht verfügbar. Bitte später erneut versuchen.")
        case .timedOut: return String(localized: "Die Musikerkennung hat zu lange gedauert. Bitte erneut versuchen.")
        case .playbackChanged: return String(localized: "Die Wiedergabe oder der Titel hat sich geändert. Bitte erneut erkennen.")
        }
    }
}

enum RecognitionPhase: Equatable {
    case idle, listening, matching, matched(RecognizedTrack), noMatch, cancelled, failed(RecognitionFailure)
    var isBusy: Bool { self == .listening || self == .matching }
}

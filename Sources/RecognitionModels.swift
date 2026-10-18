import Foundation

struct RecognitionContext: Equatable, Sendable {
    let generation: UInt64
    let stationID: UUID
    let title: String
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
        let id = Self.clean(shazamID); self.shazamID = id.isEmpty ? nil : id
        if let url = appleMusicURL, url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.apple.com",
           url.user == nil, url.password == nil, url.port == nil || url.port == 443 { self.appleMusicURL = url }
        else { self.appleMusicURL = nil }
    }

    private static func clean(_ value: String?) -> String {
        String((value ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(256))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecognitionFailure: Error, LocalizedError, Equatable, Sendable {
    case noPlayback, muted, audioUnavailable, audioChanged, notEnoughAudio, invalidAudio, silent, offline, serviceUnavailable, timedOut, playbackChanged
    var errorDescription: String? {
        switch self {
        case .noPlayback: return String(localized: "Starte einen Sender, um Musik zu erkennen.")
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

import Foundation

struct RecognitionListeningContext: Codable, Equatable, Sendable {
    let outputID: UUID
    let revision: UInt64
    let position: TimeInterval?
    let receivedAt: Date?

    var isValid: Bool {
        (position.map { $0.isFinite && $0 >= 0 } ?? true)
            && (receivedAt.map { Self.validDate($0) } ?? true)
            && ((position == nil) == (receivedAt == nil))
    }

    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
            && (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}

struct SongRecognition: Codable, Equatable, Sendable {
    let source: String
    let recognizedAt: Date
    let stationID: UUID
    let originalICY: String
    let shazamID: String?
    let appleMusicURL: URL?
    let listening: RecognitionListeningContext?

    init(recognizedAt: Date, stationID: UUID, originalICY: String,
         shazamID: String?, appleMusicURL: URL?, listening: RecognitionListeningContext? = nil) {
        source = "shazam"; self.recognizedAt = recognizedAt; self.stationID = stationID
        self.originalICY = originalICY; self.shazamID = shazamID
        self.appleMusicURL = Self.safeAppleMusicURL(appleMusicURL)
        self.listening = listening
    }

    enum CodingKeys: CodingKey { case source, recognizedAt, stationID, originalICY, shazamID, appleMusicURL, listening }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        recognizedAt = try c.decode(Date.self, forKey: .recognizedAt)
        stationID = try c.decode(UUID.self, forKey: .stationID)
        originalICY = try c.decode(String.self, forKey: .originalICY)
        shazamID = try c.decodeIfPresent(String.self, forKey: .shazamID)
        appleMusicURL = try c.decodeIfPresent(URL.self, forKey: .appleMusicURL)
        listening = try c.decodeIfPresent(RecognitionListeningContext.self, forKey: .listening)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid music recognition provenance"))
        }
    }

    var isValid: Bool {
        source == "shazam" && RecognitionListeningContext.validDate(recognizedAt)
            && (listening?.isValid ?? true)
            && originalICY.utf8.count <= 4096
            && !originalICY.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }
            && (shazamID.map { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } ?? true)
            && (appleMusicURL == nil || Self.safeAppleMusicURL(appleMusicURL) != nil)
    }

    static func safeAppleMusicURL(_ url: URL?) -> URL? {
        guard let url, url.absoluteString.utf8.count <= 4096,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.apple.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return url
    }
}

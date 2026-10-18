import Foundation

struct SongExportMetadata: Equatable, Sendable {
    let artist: String?
    let title: String
    let station: String
    let original: String
    let recordedAt: Date

    init(raw: String, artist: String?, title: String?, station: String, recordedAt: Date) {
        let artist = Self.clean(artist ?? "")
        self.artist = artist.isEmpty ? nil : artist
        let title = Self.clean(title ?? "")
        original = Self.clean(raw)
        self.title = title.isEmpty ? (original.isEmpty ? "Song" : original) : title
        self.station = Self.clean(station)
        self.recordedAt = recordedAt
    }

    var displayName: String { (artist.map { $0 + " - " } ?? "") + title }
    var fileBase: String { ExportFileNaming.safeBase(displayName) }
    var comment: String {
        let date = ISO8601DateFormatter().string(from: recordedAt)
        return "Station: \(station)\nOriginal ICY: \(original)\nRecorded: \(date)"
    }

    private static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.prefix(4096).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) {
                return CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : ""
            }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return ExportFileNaming.prefix(scalars.precomposedStringWithCanonicalMapping, bytes: 4096)
    }
}

enum ExportFileNaming {
    static func safeBase(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " _.-()"))
        var value = raw.unicodeScalars.prefix(4096).map { allowed.contains($0) ? String($0) : "_" }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix(".") { value = "Song_" + value }
        // Die Dateisystemgrenze gilt für UTF-8-Bytes, nicht für die Zahl der Zeichen.
        return prefix(value.precomposedStringWithCanonicalMapping, bytes: 180)
    }

    static func prefix(_ value: String, bytes: Int) -> String {
        var result = "", count = 0
        for character in value {
            let size = String(character).utf8.count
            guard count + size <= bytes else { break }
            result.append(character); count += size
        }
        return result.isEmpty && !value.isEmpty ? "Song" : result
    }
}

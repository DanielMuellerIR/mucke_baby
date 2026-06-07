import Foundation

// Datenmodell eines Radiosenders.
// `id` ist stabil (wird einmal vergeben und in stations.json gespeichert),
// damit Favorit/zuletzt-gespielt zuverlaessig referenziert werden koennen.
struct Station: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var enabled: Bool = true   // entspricht "Show in list" (inc) aus Radio++
    var favorite: Bool = false // genau ein Sender ist Favorit -> Autostart

    init(id: UUID = UUID(), name: String, url: String, enabled: Bool = true, favorite: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.favorite = favorite
    }

    // Toleranter Decoder: fehlende Felder in handgepflegten stations.json
    // brechen das Laden nicht ab, sondern bekommen sinnvolle Defaults.
    enum CodingKeys: String, CodingKey { case id, name, url, enabled, favorite }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        favorite = (try? c.decode(Bool.self, forKey: .favorite)) ?? false
    }
}

// Eintrag aus der gebuendelten Seed-Datei (seed-stations.json).
// Hat keine id — die wird beim erstmaligen Import vergeben.
struct SeedStation: Decodable {
    let name: String
    let url: String
    var enabled: Bool = true
    var favorite: Bool = false

    enum CodingKeys: String, CodingKey { case name, url, enabled, favorite }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        favorite = (try? c.decode(Bool.self, forKey: .favorite)) ?? false
    }

    func toStation() -> Station {
        Station(name: name, url: url, enabled: enabled, favorite: favorite)
    }
}

// App-Version an einer Stelle. Wird auch in der Info.plist gespiegelt.
enum AppInfo {
    static let version = "1.7.27"
}

/// Verschiebt einmalig den alten Daten-Ordner „MacRadio" auf den neuen Namen „MuckeBaby"
/// (im jeweiligen Basis-Verzeichnis: Application Support bzw. Music), damit beim Umbenennen
/// keine Sender/Verlauf/Aufnahmen verloren gehen. Idempotent: läuft nur, wenn der alte Ordner
/// existiert und der neue noch nicht — danach No-Op. (Bundle-ID/EXE bleiben aus Kontinuität.)
func migrateLegacyAppDir(in base: FileManager.SearchPathDirectory) {
    let fm = FileManager.default
    guard let root = fm.urls(for: base, in: .userDomainMask).first else { return }
    let oldURL = root.appendingPathComponent("MacRadio", isDirectory: true)
    let newURL = root.appendingPathComponent("MuckeBaby", isDirectory: true)
    if fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) {
        try? fm.moveItem(at: oldURL, to: newURL)
    }
}

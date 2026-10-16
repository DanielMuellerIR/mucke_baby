import Foundation

@main
enum StartupHarness {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeBaby-Startup-\(UUID())")
        let suite = "MuckeBaby-Startup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = Station(name: "First", url: "https://example.com/first")
        let favorite = Station(name: "Favorite", url: "https://example.com/favorite", favorite: true)
        let hidden = Station(name: "Hidden", url: "https://example.com/hidden", enabled: false, favorite: true)
        let stations = [first, hidden, favorite]
        func settings(_ name: String, stations: [Station] = stations) -> StartupSettings {
            StartupSettings(directory: root.appendingPathComponent(name), defaults: defaults, stations: stations)
        }
        defaults.set(first.id.uuidString, forKey: "lastStationID")
        let legacy = settings("legacy")
        check(legacy.configuration.mode == .lastStation && legacy.configuration.target(in: stations) == first,
              "Bisheriger letzter Sender muss Vorrang behalten")
        defaults.set(hidden.id.uuidString, forKey: "lastStationID")
        check(settings("hidden-legacy").configuration.target(in: stations) == favorite,
              "Migration darf ausgeblendete Favoriten nicht starten")
        defaults.set(UUID().uuidString, forKey: "lastStationID")
        check(settings("orphan-legacy").configuration.target(in: stations) == favorite,
              "Migration muss bisherigen sichtbaren Ersatz erhalten")
        check(settings("first-legacy", stations: [first]).configuration.target(in: [first]) == first,
              "Migration ohne Favorit muss ersten sichtbaren Sender erhalten")
        defaults.set(false, forKey: "autoplayOnLaunch")
        let off = settings("off")
        check(off.configuration.mode == .none && off.configuration.target(in: stations) == nil,
              "Deaktiviertes Autoplay muss deaktiviert bleiben")
        off.selectStation(favorite.id)
        off.setMode(.selectedStation)
        off.rememberStation(first.id)
        check(off.configuration.target(in: stations) == favorite, "Letzter Sender darf feste Auswahl nicht ändern")
        defaults.set(true, forKey: "autoplayOnLaunch")
        let restarted = settings("off")
        check(restarted.configuration == off.configuration, "Neustart darf alte Präferenzen nicht erneut migrieren")
        restarted.setMode(.lastStation)
        check(restarted.configuration.target(in: stations) == first, "Letzter Sender muss auch im festen Modus gemerkt werden")
        check(restarted.configuration.target(in: [favorite]) == nil, "Gelöschter letzter Sender darf keinen Ersatz starten")
        restarted.setMode(.selectedStation)
        var disabled = favorite; disabled.enabled = false
        check(restarted.configuration.target(in: [first, disabled]) == nil,
              "Ausgeblendetes festes Ziel darf keinen Ersatz starten")
        var unsafe = favorite; unsafe.url = "file:///tmp/audio"
        check(restarted.configuration.target(in: [unsafe]) == nil, "Nicht-Web-Ziel darf nicht automatisch starten")
        restarted.selectStation(nil)
        check(restarted.configuration.target(in: stations) == nil, "Leere feste Auswahl muss still bleiben")
        check(settings("empty", stations: []).configuration.target(in: []) == nil, "Leere Liste muss still bleiben")

        for (name, content) in [("broken", "not JSON"), ("unknown-mode", "{\"formatVersion\":1,\"mode\":\"unknown\"}")] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: dir.appendingPathComponent("startup.json"))
            let damaged = settings(name)
            check(damaged.configuration.mode == .none && damaged.notice != nil, "Beschädigung muss Autostart ausschalten und erklären")
            let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".broken-") }
            check(try backups.contains { try Data(contentsOf: $0) == Data(content.utf8) }, "Beschädigte Konfiguration muss gesichert bleiben")
        }
        let futureDir = root.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: futureDir, withIntermediateDirectories: true)
        let future = Data("{\"formatVersion\":2,\"future\":true}".utf8)
        let futureURL = futureDir.appendingPathComponent("startup.json")
        try future.write(to: futureURL)
        let unknown = settings("future")
        unknown.setMode(.lastStation)
        unknown.rememberStation(first.id)
        check(unknown.isReadOnly && unknown.configuration.target(in: stations) == nil, "Neuere Version muss sicher schreibgeschützt sein")
        check(try Data(contentsOf: futureURL) == future, "Neuere Version darf nicht überschrieben werden")

        let blockedDir = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedDir.appendingPathComponent("startup.json"), withIntermediateDirectories: true)
        let unreadable = settings("blocked")
        check(unreadable.isReadOnly && unreadable.notice != nil, "Lesefehler muss sichtbar sperren")
        let unwritableDir = root.appendingPathComponent("unwritable")
        try FileManager.default.createDirectory(at: unwritableDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritableDir.path)
        let unwritable = settings("unwritable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritableDir.path)
        check(unwritable.isReadOnly && unwritable.configuration.target(in: stations) == nil,
              "Fehlgeschlagene Migration darf keine ungesicherte automatische Wiedergabe zulassen")
        let failure = settings("failure")
        let previous = failure.configuration
        let held = root.appendingPathComponent("held")
        let failureDir = root.appendingPathComponent("failure")
        let bytes = try Data(contentsOf: failureDir.appendingPathComponent("startup.json"))
        try FileManager.default.moveItem(at: failureDir, to: held)
        try Data("blocked".utf8).write(to: failureDir)
        failure.setMode(.selectedStation)
        failure.selectStation(first.id)
        failure.rememberStation(first.id)
        check(failure.configuration == previous && failure.showNotice, "Schreibfehler darf ungesicherte Auswahl nicht veröffentlichen")
        check(try Data(contentsOf: held.appendingPathComponent("startup.json")) == bytes, "Schreibfehler darf Bestand nicht ändern")
        print("StartupHarness: Migration, Auswahl, Neustart und Fehlerfälle OK")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}

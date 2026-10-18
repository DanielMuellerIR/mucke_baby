import Foundation

@main
enum ExchangeCodecHarness {
    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = Station(name: "Eigener Name — Grüße 東京", url: "https://radio.example.org/a?x=1", favorite: true, radioBrowserID: UUID())
        let second = Station(name: "Second", url: "http://radio.example.org/b", enabled: false)
        let group = StationGroup(name: "Meine Gruppe", stationIDs: [second.id, first.id])
        let bookmark = SongBookmark(id: UUID(), station: first.name, raw: "Artist - Track (Live Mix)", artist: "Artist", title: "Track (Live Mix)", heardAt: date, savedAt: date)
        let library = ExchangeLibrary(stations: [first, second], groups: [group], bookmarks: [bookmark])
        let data = try ExchangeCodec.encode(library, at: date)
        let decoded = try ExchangeCodec.decode(data)
        check(decoded == library, "Roundtrip verliert Identität, Reihenfolge oder Metadaten")
        var precise = library; precise.bookmarks[0].heardAt = date.addingTimeInterval(0.123)
        let preciseDecoded = try ExchangeCodec.decode(ExchangeCodec.encode(precise))
        check(abs(preciseDecoded.bookmarks[0].heardAt.timeIntervalSince(precise.bookmarks[0].heardAt)) < 0.001, "Millisekunden gehen verloren")
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(Set(object.keys) == ["format", "formatVersion", "exportedAt", "stations", "groups", "bookmarks"], "Export enthält fremde lokale Zustände")
        var legacyStation = ["name": "Old", "url": "https://radio.example.org/legacy", "favorite": true] as [String: Any]
        let legacy = try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: [legacyStation]))
        check(legacy.isLegacy && legacy.stations[0].favorite && legacy.stations[0].enabled, "Legacy-Array nicht lesbar")
        legacyStation["id"] = first.id.uuidString
        let old: [String: Any] = ["formatVersion": 2, "stations": [legacyStation], "groups": [], "quickSlots": [first.id.uuidString]]
        try check(try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: old)).stations[0].id == first.id, "Bestehende Datei verliert gültige ID")
        func rejected(_ description: String, _ mutate: (inout [String: Any]) -> Void) throws {
            var value = object; mutate(&value)
            expectFailure(description) { _ = try ExchangeCodec.decode(JSONSerialization.data(withJSONObject: value)) }
        }
        func stationChange(_ field: String, _ value: Any) throws {
            try rejected("Ungültiges Senderfeld akzeptiert: " + field) { var s = $0["stations"] as! [[String: Any]]; s[0][field] = value; $0["stations"] = s }
        }
        try rejected("Unbekannte Version akzeptiert") { $0["formatVersion"] = 99 }
        try rejected("Fremdes Format akzeptiert") { $0["format"] = "other" }
        try rejected("Doppelte ID akzeptiert") { var s = $0["stations"] as! [[String: Any]]; s[1]["id"] = s[0]["id"]; $0["stations"] = s }
        try rejected("Fehlende neue ID akzeptiert") { var s = $0["stations"] as! [[String: Any]]; s[0].removeValue(forKey: "id"); $0["stations"] = s }
        try stationChange("url", "file:///etc/passwd")
        var credentialFixture = URLComponents(string: "https://radio.example.org/a")!
        credentialFixture.user = "fixture-user"; credentialFixture.password = "fixture-password"
        try stationChange("url", credentialFixture.string!)
        try stationChange("radioBrowserID", "broken")
        try stationChange("favorite", "true")
        try stationChange("name", String(repeating: "a", count: 257))
        try rejected("Fehlender Gruppenbezug akzeptiert") { var g = $0["groups"] as! [[String: Any]]; g[0]["stationIDs"] = [UUID().uuidString]; $0["groups"] = g }
        try rejected("Doppelter Gruppenbezug akzeptiert") { var g = $0["groups"] as! [[String: Any]]; g[0]["stationIDs"] = [first.id.uuidString, first.id.uuidString]; $0["groups"] = g }
        try rejected("Doppelte Bookmark-ID akzeptiert") { let b = $0["bookmarks"] as! [[String: Any]]; $0["bookmarks"] = b + b }
        try rejected("Falsches Datum akzeptiert") { var b = $0["bookmarks"] as! [[String: Any]]; b[0]["heardAt"] = "2026-10-18T12:00:00Z trailing"; $0["bookmarks"] = b }
        try rejected("Kalenderfehler still normalisiert") { var b = $0["bookmarks"] as! [[String: Any]]; b[0]["heardAt"] = "2026-02-30T12:00:00Z"; $0["bookmarks"] = b }
        try rejected("Leerer Titel akzeptiert") { var b = $0["bookmarks"] as! [[String: Any]]; b[0]["raw"] = " \n "; $0["bookmarks"] = b }
        expectFailure("Größenlimit fehlt") { _ = try ExchangeCodec.decode(Data(repeating: 32, count: ExchangeCodec.byteLimit + 1)) }
        expectFailure("Kaputtes JSON akzeptiert") { _ = try ExchangeCodec.decode(Data("{broken".utf8)) }

        var imported = first; imported.id = UUID(); imported.name = "Katalogname"; imported.favorite = false; imported.enabled = false
        var importedBookmark = bookmark; importedBookmark.id = UUID(); importedBookmark.station = "Anderer Sender"; importedBookmark.savedAt = date.addingTimeInterval(200)
        let newStation = Station(name: "New", url: "https://radio.example.org/new")
        let newGroup = StationGroup(name: group.name, stationIDs: [imported.id, newStation.id])
        let incoming = ExchangeLibrary(stations: [imported, newStation], groups: [newGroup], bookmarks: [importedBookmark])
        let plan = try ExchangeMergePlan(local: library, incoming: incoming)
        check(plan.rows.filter { $0.state == .conflict }.count == 3 && plan.rows.filter { $0.state == .new }.count == 1, "Vorschau versteckt Konflikte")
        let defaults = try plan.resolved(selections: [:])
        check(defaults.stations[0] == first && defaults.groups == library.groups && defaults.bookmarks == library.bookmarks, "Standardimport überschreibt lokale Daten")
        let sk = ExchangeMergePlan.Key(kind: .station, id: imported.id)
        let gk = ExchangeMergePlan.Key(kind: .group, id: newGroup.id)
        let bk = ExchangeMergePlan.Key(kind: .bookmark, id: importedBookmark.id)
        let replaced = try plan.resolved(selections: [sk: .useIncoming, gk: .useIncoming, bk: .useIncoming])
        check(replaced.stations[0].id == first.id && replaced.stations[0].name == imported.name && !replaced.stations[0].favorite, "Konfliktübernahme verändert lokale Identität")
        check(replaced.groups[0].id == group.id && replaced.groups[0].stationIDs == [first.id, newStation.id], "Gruppenreferenzen falsch abgebildet")
        check(replaced.bookmarks[0].id == bookmark.id && replaced.bookmarks[0].station == importedBookmark.station, "Bookmark-ID ersetzt")
        let choices: [ExchangeMergePlan.Key: ExchangeMergePlan.Choice] = [sk: .keepBoth, gk: .keepBoth, bk: .keepBoth]
        let both = try plan.resolved(selections: choices)
        check(both.stations.count == 4 && both.groups.count == 2 && both.bookmarks.count == 2, "Beide behalten verliert Einträge")
        let additional = both.stations.first { $0.name == imported.name }!
        check(additional.id != first.id && both.groups[1].stationIDs.contains(additional.id), "Neue Gruppe verweist auf falschen Sender")
        try check(both == (try plan.resolved(selections: choices)), "Vorschau vergibt wiederholt neue IDs")
        check(library.stations[0] == first && library.bookmarks[0] == bookmark, "Vorschau verändert Altbestand")
        let skipped = try plan.resolved(selections: [ExchangeMergePlan.Key(kind: .station, id: newStation.id): .keepLocal, gk: .useIncoming])
        check(skipped.groups[0].stationIDs == [first.id], "Überspringen hinterlässt ungültigen Gruppenbezug")
        let same = try ExchangeMergePlan(local: library, incoming: decoded)
        check(same.rows.allSatisfy { $0.state == .unchanged }, "Roundtrip zeigt falsche Konflikte")
        var primary = first; primary.url = "https://radio.example.org/repaired"
        var secondary = first; secondary.id = UUID(); secondary.name = "Secondary"
        let collision = try ExchangeMergePlan(local: library, incoming: ExchangeLibrary(stations: [secondary, primary], groups: [], bookmarks: []))
        check(collision.rows[0].state == .new && collision.rows[1].localID == first.id, "URL-Zuordnung beansprucht ID eines anderen Importdatensatzes")
        let neutralFixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/library-exchange-v1.json"))
        let neutral = try ExchangeCodec.decode(neutralFixture)
        check(neutral.stations.count == 2 && neutral.groups.count == 1 && neutral.bookmarks.count == 1, "Dokumentierte Fixture nicht lesbar")
        print("ExchangeCodec/Merge: Legacy, Roundtrip, Grenzen, Konflikte und lokale Identität OK")
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }
}

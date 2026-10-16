import Foundation

@main
enum StationSelectionHarness {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeBaby-Groups-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stations = [Station(name: "Björk 東京 FM", url: "https://example.com/Live?Genre=Rock", favorite: true),
                        Station(name: "Quiet FM", url: "https://example.com/quiet"),
                        Station(name: "Hidden FM", url: "https://example.com/hidden", enabled: false, favorite: true)]
        let file = root.appendingPathComponent("stations.json")
        let oldBytes = try JSONEncoder().encode(stations)
        try oldBytes.write(to: file)
        let store = Store(directory: root, seedURL: nil)
        check(store.stations == stations && store.groups.isEmpty && store.quickSlots.count == 5, "Legacy-Migration muss Sender erhalten")
        check(try Data(contentsOf: file) == oldBytes, "Lesen darf Legacy-Array nicht umschreiben")
        try store.saveGroup(name: "  Rock  ")
        let rock = store.groups[0].id
        try store.saveGroup(name: "Night")
        let night = store.groups[1].id
        try store.saveGroup(name: "Empty")
        let empty = store.groups[2].id
        rejectName { try store.saveGroup(name: "rock") }
        rejectName { try store.saveGroup(name: "\n ") }
        try store.update(stations[0], groupIDs: [rock, night])
        try store.update(stations[2], groupIDs: [rock])
        try store.setQuickSlot(0, stationID: stations[0].id)
        try store.setQuickSlot(4, stationID: stations[2].id)
        check(store.quickStation(at: 0) == stations[0] && store.quickStation(at: 4) == nil,
              "Schnellplätze dürfen nur verfügbare Sender starten")
        let initial = Store(directory: root, seedURL: nil)
        check(initial.stations == stations && initial.groups == store.groups && initial.quickSlots == store.quickSlots,
              "Gruppen und Schnellplätze müssen Neustart überstehen")
        check(try JSONDecoder().decode(StationCollection.self, from: Data(contentsOf: file)).formatVersion == 2,
              "Speicherung muss versioniertes Dokument schreiben")

        func matches(_ query: String = "", _ scope: StationListScope = .all) -> [Station] {
            StationSelection.filtered(store.stations, groups: store.groups, query: query, scope: scope)
        }
        check(matches("BJORK 東京 rock", .group(rock)) == [stations[0]], "Suche muss Namen, Akzente und URL mit Gruppe kombinieren")
        check(matches("fm", .favorites) == [stations[0]], "Favoritenfilter darf ausgeblendete Sender nicht zeigen")
        check(matches("", .ungrouped) == [stations[1]], "Ohne-Gruppe-Filter muss Mehrfachmitgliedschaft berücksichtigen")
        check(matches("", .group(empty)).isEmpty && matches("[.*]").isEmpty, "Leere Gruppe und wörtliche Suche müssen leer bleiben")
        check(matches().map(\.id) == stations.prefix(2).map(\.id), "Suche darf gespeicherte Reihenfolge nicht sortieren")
        try store.saveGroup(id: rock, name: "Rock renamed")
        check(store.groups[0].id == rock && matches("", .group(rock)) == [stations[0]], "Umbenennen darf Mitgliedschaft nicht verlieren")
        try store.moveGroups(from: IndexSet(integer: 0), to: 3)
        check(store.groups.map(\.id) == [night, empty, rock], "Gruppenreihenfolge muss gespeichert werden")
        try store.deleteGroup(rock)
        check(store.stations == stations && matches("", .group(night)) == [stations[0]], "Gruppenlöschung darf keine Sender oder andere Zuordnung entfernen")
        check(store.quickStation(at: 0) == stations[0], "Gruppenlöschung darf Schnellplatz nicht ändern")
        store.move(from: IndexSet(integer: 0), to: 3)
        check(matches().map(\.id) == [stations[1].id, stations[0].id], "Gefilterte Liste muss neue Senderreihenfolge übernehmen")
        check(store.delete(stations[0]), "Senderlöschung muss speichern")
        check(store.groups.allSatisfy { !$0.stationIDs.contains(stations[0].id) } && store.quickStation(at: 0) == nil,
              "Gelöschte Sender dürfen weder Gruppenmitglied noch aktiver Schnellplatz bleiben")

        let snapshot = store.stations, groups = store.groups, slots = store.quickSlots
        let before = try Data(contentsOf: file)
        let held = root.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: file, to: held)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        rejectSave { try store.saveGroup(name: "Unsaved") }
        rejectSave { try store.deleteGroup(night) }
        rejectSave { try store.setQuickSlot(1, stationID: stations[1].id) }
        rejectSave { try store.update(stations[1], groupIDs: [night]) }
        check(store.stations == snapshot && store.groups == groups && store.quickSlots == slots,
              "Speicherfehler darf keine Teiländerung veröffentlichen")
        check(try Data(contentsOf: held) == before, "Speicherfehler muss Bestandsdatei erhalten")
        try FileManager.default.removeItem(at: file)
        let future = Data("{\"formatVersion\":3,\"future\":true}".utf8)
        try future.write(to: file)
        let unknown = Store(directory: root, seedURL: nil)
        rejectSave { try unknown.saveGroup(name: "Unsafe") }
        check(unknown.persistenceFailed && unknown.loadNotice != nil && unknown.stations.isEmpty, "Unbekannte Version muss sichtbar schreibgesperrt sein")
        check(try Data(contentsOf: file) == future, "Unbekannte Version darf nicht überschrieben werden")
        print("StationSelectionHarness: Migration, Gruppen, Suche, Reihenfolge, Schnellplätze und Fehlerfälle OK")
    }

    private static func check(_ condition: Bool, _ message: String) { guard condition else { fatalError(message) } }
    private static func rejectName(_ action: () throws -> Void) {
        do { try action(); fatalError("Ungültiger Gruppenname akzeptiert") }
        catch StationSaveError.invalidGroupName {} catch { fatalError("Falscher Namensfehler: \(error)") }
    }
    private static func rejectSave(_ action: () throws -> Void) {
        do { try action(); fatalError("Speicherfehler nicht gemeldet") }
        catch StationSaveError.persistenceFailed {} catch { fatalError("Falscher Speicherfehler: \(error)") }
    }
}

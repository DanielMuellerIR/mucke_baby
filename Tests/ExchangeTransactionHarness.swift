import Foundation

@main struct ExchangeTransactionHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    struct Interrupted: Error {}
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-ExchangeTransaction-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("stations.json"), b = root.appendingPathComponent("bookmarks.json")
        let oldA = Data("old-A".utf8), oldB = Data("old-B".utf8), newA = Data("new-A".utf8), newB = Data("new-B".utf8)
        let validate: ExchangeTransaction.Validator = { _, data in guard data.starts(with: Data("new-".utf8)) else { throw Interrupted() } }
        let changes = [ExchangeTransaction.Change(name: "stations.json", before: oldA, after: newA),
                       ExchangeTransaction.Change(name: "bookmarks.json", before: oldB, after: newB)]
        try oldA.write(to: a);try oldB.write(to: b)
        do {
            _ = try ExchangeTransaction.commit(changes, in: root, validate: validate) { phase in if case .beforeCommit = phase { throw Interrupted() } }
            fatalError("Fehler vor Commit ignoriert")
        } catch is Interrupted {}
        check(try Data(contentsOf: a) == oldA, "Fehler vor Commit verändert Sender")
        check(try Data(contentsOf: b) == oldB, "Fehler vor Commit verändert Merkliste")
        check(!fm.fileExists(atPath: root.appendingPathComponent(ExchangeTransaction.journalName).path), "Fehler vor Commit hinterlässt Journal")
        let interrupted = try ExchangeTransaction.commit(changes, in: root, validate: validate) { phase in if case .afterCommit = phase { throw Interrupted() } }
        check(interrupted.pending && interrupted.values["stations.json"] == newA && interrupted.values["bookmarks.json"] == newB,
              "Unterbrechung nach Commit verliert vollständigen neuen Bestand")
        check(try Data(contentsOf: a) == oldA, "Unterbrechung sollte kanonische Dateien noch nicht ändern")
        let recovered = try ExchangeTransaction.recover(in: root, validate: validate)!
        let recoveredA = try Data(contentsOf: a)
        check(!recovered.pending && recoveredA == newA, "Neustart stellt Sender nicht fertig")
        check(try Data(contentsOf: b) == newB, "Neustart stellt Merkliste nicht fertig")
        check(try ExchangeTransaction.recover(in: root, validate: validate) == nil, "Recovery ist nicht idempotent")
        let mode = try fm.attributesOfItem(atPath: a.path)[.posixPermissions] as! NSNumber
        check(mode.intValue == 0o600, "Importdatei ist nicht privat")

        try oldA.write(to: a);try oldB.write(to: b)
        let blocked = try ExchangeTransaction.commit(changes, in: root, validate: validate) { phase in
            if case .afterCommit = phase { try fm.setAttributes([.immutable: true], ofItemAtPath: b.path) }
        }
        check(blocked.pending && blocked.values["stations.json"] == newA && blocked.values["bookmarks.json"] == newB,
              "Fehler beim zweiten Schreiben verliert gemeinsamen Commit")
        check(try Data(contentsOf: a) == newA, "Erstes kanonisches Schreiben fehlt")
        check(try Data(contentsOf: b) == oldB, "Schreibschutz wird umgangen")
        try fm.setAttributes([.immutable: false], ofItemAtPath: b.path)
        check(!(try ExchangeTransaction.recover(in: root, validate: validate)!.pending), "Wiederaufnahme nach Schreibfehler scheitert")
        check(try Data(contentsOf: b) == newB, "Zweite Datei nach Wiederaufnahme falsch")

        try oldA.write(to: a);try oldB.write(to: b)
        let external = Data("external".utf8)
        let changed = try ExchangeTransaction.commit(changes, in: root, validate: validate) { phase in
            if case .afterCommit = phase { try external.write(to: b) }
        }
        check(changed.pending && changed.values["bookmarks.json"] == newB, "Externes Schreiben verliert Journalwert")
        check(try Data(contentsOf: b) == external, "Fremde Änderung überschrieben")
        let journal = root.appendingPathComponent(ExchangeTransaction.journalName)
        let journalBytes = try Data(contentsOf: journal)
        try Data("{broken".utf8).write(to: journal)
        do { _ = try ExchangeTransaction.recover(in: root, validate: validate);fatalError("Kaputtes Journal übernommen") }
        catch ExchangeDiskError.invalidJournal {}
        check(try Data(contentsOf: b) == external, "Kaputtes Journal verändert Bestand")
        try journalBytes.write(to: journal);try oldB.write(to: b)
        _ = try ExchangeTransaction.recover(in: root, validate: validate)
        print("ExchangeTransactionHarness: Commitpunkt, Abbruch, Zwei-Datei-Schreibfehler, Neustart, externe Änderung und Journalschutz OK")
    }
}

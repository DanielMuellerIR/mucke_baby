import Foundation

@main
struct RecordingLibraryHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }
    static let base = Date(timeIntervalSince1970: 1_792_200_000)
    static func clip(_ name: String, session: UUID? = nil, end: Double? = 120) -> Recorder.Clip {
        Recorder.Clip(file: name, station: "Sender — 東京", start: base,
                      end: end.map { base.addingTimeInterval($0) }, ext: "mp3", sessionID: session)
    }
    static func seed(_ directory: URL, _ clips: [Recorder.Clip]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.isoPretty.encode(clips).write(to: directory.appendingPathComponent("recordings-index.json"))
    }
    static func file(_ directory: URL, _ name: String) throws {
        try Data(repeating: 42, count: 128).write(to: directory.appendingPathComponent(name))
    }
    static func expect(_ expected: RecordingLibraryError, _ body: () async throws -> Void) async {
        do { try await body(); fatalError("Erwarteter Bibliotheksfehler fehlt") }
        catch let actual as RecordingLibraryError { check(String(describing: actual) == String(describing: expected), "Falscher Fehler: \(actual)") }
        catch { fatalError("Unerwarteter Fehler: \(error)") }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeLibrary-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("recordings")
        let session = UUID()
        let complete = clip("complete.mp3", session: session), missing = clip("missing.mp3")
        let link = clip("link.mp3"), folder = clip("folder.mp3"), empty = clip("empty.mp3")
        try seed(directory, [complete, missing, link, folder, empty, clip("../outside.mp3")])
        try file(directory, complete.file)
        let outside = root.appendingPathComponent("outside.mp3")
        try Data("outside must survive".utf8).write(to: outside)
        try fm.createSymbolicLink(at: directory.appendingPathComponent(link.file), withDestinationURL: outside)
        try fm.createDirectory(at: directory.appendingPathComponent(folder.file), withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent(empty.file))
        let recorder = Recorder(directory: directory, minimumFreeBytes: -1)
        var inventory = await recorder.librarySnapshot()
        check(inventory.items.count == 5, "Unsicherer Indexpfad gelangt in die Bibliothek")
        check(inventory.items.first { $0.id == complete.id }?.bytes == 128, "Dateigröße fehlt")
        check(inventory.items.first { $0.id == missing.id }?.status == .missing, "Fehlende Datei nicht erkannt")
        check(inventory.items.first { $0.id == link.id }?.status == .unreadable, "Symlink wird als Audio angeboten")
        check(inventory.items.first { $0.id == folder.id }?.status == .unreadable, "Verzeichnis wird als Audio angeboten")
        check(inventory.items.first { $0.id == empty.id }?.status == .empty, "Leere Datei wird als Audio angeboten")
        let entry = SongEntry(station: complete.station, raw: "Artist - Track", start: base.addingTimeInterval(10),
                              end: base.addingTimeInterval(90), sessionID: session)
        check(inventory.audio(for: entry).status == .complete, "Vollständiges Audio nicht erkannt")
        check(!recorder.audioAvailability(for: entry).isPartial, "Vollständiger Titel wird als Teilaudio markiert")
        check(inventory.audio(for: entry).source?.duration == 80, "Vollständige Zeitspanne falsch")
        var partial = entry; partial.end = base.addingTimeInterval(180)
        check(inventory.audio(for: partial).status == .partial && inventory.audio(for: partial).source?.duration == 110, "Abgeschnittenes Audio wird als vollständig angeboten")
        check(recorder.audioAvailability(for: partial).isPartial, "Frisch begrenzte Exportquelle verliert Teilaufnahme-Kennzeichnung")
        partial.start = base.addingTimeInterval(-10)
        check(inventory.audio(for: partial).source?.offset == 0, "Negativer Vorlauf wird exportiert")
        var wrong = entry; wrong.sessionID = UUID()
        check(inventory.audio(for: wrong).status == .none && recorder.exportSource(for: wrong) == nil, "Fremde Session erhält Audio")
        var absent = entry; absent.sessionID = nil; absent.station = "Anderer Sender"
        check(inventory.audio(for: absent).status == .none, "Senderzuordnung wird ignoriert")
        check(try await recorder.previewURL(id: complete.id) == directory.appendingPathComponent(complete.file), "Vorhörquelle falsch")
        await expect(.unreadable) { _ = try await recorder.previewURL(id: link.id) }
        await expect(.unreadable) { try await recorder.removeCompleted(id: link.id) }
        await expect(.unreadable) { try await recorder.removeCompleted(id: folder.id) }
        check(try Data(contentsOf: outside) == Data("outside must survive".utf8), "Manipulierter Pfad beschädigt Fremddatei")

        let history = SongHistory(directory: root.appendingPathComponent("history"))
        history.note(station: complete.station, raw: "Artist - Track", at: base)
        history.closeCurrent(at: base.addingTimeInterval(60))
        let historyFile = root.appendingPathComponent("history/verlauf.json")
        let historyBefore = try Data(contentsOf: historyFile)
        let index = directory.appendingPathComponent("recordings-index.json")
        let held = directory.appendingPathComponent("held-index.json")
        try fm.moveItem(at: index, to: held); try fm.createDirectory(at: index, withIntermediateDirectories: false)
        await expect(.indexUnavailable) { try await recorder.removeCompleted(id: complete.id) }
        check(fm.fileExists(atPath: directory.appendingPathComponent(complete.file).path), "Index-Schreibfehler löscht Audio")
        check(recorder.snapshot().contains { $0.id == complete.id }, "Index-Schreibfehler entfernt Eintrag")
        try fm.removeItem(at: index); try fm.moveItem(at: held, to: index)
        try await recorder.removeCompleted(id: complete.id)
        check(!fm.fileExists(atPath: directory.appendingPathComponent(complete.file).path), "Ausgewählte Datei bleibt erhalten")
        check(!recorder.snapshot().contains { $0.id == complete.id }, "Gelöschte Datei bleibt im Index")
        check(try Data(contentsOf: historyFile) == historyBefore, "Aufnahme löschen verändert Verlauf")
        try await recorder.removeCompleted(id: missing.id)
        check(!recorder.snapshot().contains { $0.id == missing.id }, "Fehlender Eintrag lässt sich nicht entfernen")
        history.clear()
        check(recorder.snapshot().count == 3, "Verlauf leeren verändert Aufnahmebibliothek")

        let active = Recorder(directory: root.appendingPathComponent("active"), minimumFreeBytes: -1)
        let streamID = UUID()
        active.configureCapture(station: "Active", streamID: streamID, enabled: true, revision: 1, at: base, uptime: 0)
        active.captureFormat("audio/mpeg", streamID: streamID)
        active.captureAudio(Data([1,2,3]), at: base, receivedUptime: 1, streamID: streamID); active.flush()
        let activeID = active.snapshot().last!.id
        await expect(.active) { try await active.removeCompleted(id: activeID) }
        await expect(.active) { _ = try await active.previewURL(id: activeID) }
        inventory = await active.librarySnapshot()
        check(inventory.items.last?.isActive == true, "Aktive Aufnahme wird abgeschlossen angezeigt")
        active.finishCapture(streamID: streamID, at: base.addingTimeInterval(60)); active.flush()

        let deniedDir = root.appendingPathComponent("denied"), deniedClip = clip("denied.mp3")
        try seed(deniedDir, [deniedClip]); try file(deniedDir, deniedClip.file)
        let denied = Recorder(directory: deniedDir, minimumFreeBytes: -1, removeAudio: { _ in throw CocoaError(.fileWriteNoPermission) })
        let deniedIndex = try Data(contentsOf: deniedDir.appendingPathComponent("recordings-index.json"))
        await expect(.removalFailed) { try await denied.removeCompleted(id: deniedClip.id) }
        check(denied.snapshot().count == 1 && fm.fileExists(atPath: deniedDir.appendingPathComponent(deniedClip.file).path), "Löschfehler verliert Datei oder Index")
        check(try Data(contentsOf: deniedDir.appendingPathComponent("recordings-index.json")) == deniedIndex, "Löschfehler persistiert entfernten Eintrag")

        let crashDir = root.appendingPathComponent("crash"), crashClip = clip("crash.mp3")
        try seed(crashDir, []); try file(crashDir, crashClip.file)
        try JSONEncoder.isoPretty.encode(crashClip).write(to: crashDir.appendingPathComponent(".recording-removal.json"))
        let recovered = Recorder(directory: crashDir, minimumFreeBytes: -1)
        check(recovered.snapshot().first?.id == crashClip.id, "Crash zwischen Index und Dateientfernung verwaist Audio")
        check(!fm.fileExists(atPath: crashDir.appendingPathComponent(".recording-removal.json").path), "Erfolgreiche Recovery behält Journal")
        try await recovered.removeCompleted(id: crashClip.id)
        try JSONEncoder.isoPretty.encode(crashClip).write(to: crashDir.appendingPathComponent(".recording-removal.json"))
        let deletedRecovery = Recorder(directory: crashDir, minimumFreeBytes: -1)
        check(deletedRecovery.snapshot().isEmpty, "Crash nach Entfernung erfindet Aufnahme")

        let rollbackDir = root.appendingPathComponent("rollback"), rollbackClip = clip("rollback.mp3")
        try seed(rollbackDir, [rollbackClip]); try file(rollbackDir, rollbackClip.file)
        let rollbackIndex = rollbackDir.appendingPathComponent("recordings-index.json")
        let nextIndex = rollbackDir.appendingPathComponent("next-index.json")
        let rollback = Recorder(directory: rollbackDir, minimumFreeBytes: -1, removeAudio: { _ in
            try FileManager.default.moveItem(at: rollbackIndex, to: nextIndex)
            try FileManager.default.createDirectory(at: rollbackIndex, withIntermediateDirectories: false)
            throw CocoaError(.fileWriteNoPermission)
        })
        await expect(.indexRestoreFailed) { try await rollback.removeCompleted(id: rollbackClip.id) }
        check(fm.fileExists(atPath: rollbackDir.appendingPathComponent(rollbackClip.file).path), "Fehlgeschlagene Index-Rücknahme verliert Audio")
        let blockedSnapshot = await rollback.librarySnapshot()
        check(!blockedSnapshot.indexWritable, "Fehlgeschlagene Rücknahme erlaubt weiteres Schreiben")
        try fm.removeItem(at: rollbackIndex); try fm.moveItem(at: nextIndex, to: rollbackIndex)
        let rollbackRecovered = Recorder(directory: rollbackDir, minimumFreeBytes: -1)
        check(rollbackRecovered.snapshot().first?.id == rollbackClip.id, "Journal stellt erhaltene Datei nach Schreib-/Löschfehler nicht wieder her")

        let unsafeJournalDir = root.appendingPathComponent("unsafe-journal")
        try seed(unsafeJournalDir, [])
        try JSONEncoder.isoPretty.encode(clip("../outside.mp3")).write(to: unsafeJournalDir.appendingPathComponent(".recording-removal.json"))
        let unsafeJournal = Recorder(directory: unsafeJournalDir, minimumFreeBytes: -1)
        let unsafeSnapshot = await unsafeJournal.librarySnapshot()
        check(!unsafeSnapshot.indexWritable && unsafeSnapshot.items.isEmpty, "Manipuliertes Journal wird übernommen")
        check(try Data(contentsOf: outside) == Data("outside must survive".utf8), "Journal greift auf fremde Datei zu")

        let danglingDir = root.appendingPathComponent("dangling"), danglingClip = clip("dangling.mp3", end: nil)
        try seed(danglingDir, [danglingClip]); try file(danglingDir, danglingClip.file)
        try fm.setAttributes([.modificationDate: base.addingTimeInterval(70)], ofItemAtPath: danglingDir.appendingPathComponent(danglingClip.file).path)
        let dangling = Recorder(directory: danglingDir, minimumFreeBytes: -1)
        check(dangling.snapshot().first?.end == base.addingTimeInterval(70), "Crash-Recovery setzt bestehende Aufnahme auf Länge null")
        let corruptDir = root.appendingPathComponent("corrupt")
        try seed(corruptDir, []); try Data("{bad".utf8).write(to: corruptDir.appendingPathComponent("recordings-index.json"))
        try file(corruptDir, "preserved.mp3")
        let corrupt = Recorder(directory: corruptDir, minimumFreeBytes: -1)
        let corruptSnapshot = await corrupt.librarySnapshot()
        check(corruptSnapshot.indexRecovered && fm.fileExists(atPath: corruptDir.appendingPathComponent("preserved.mp3").path), "Beschädigter Index wird nicht sichtbar gesichert")
        check(try fm.contentsOfDirectory(atPath: corruptDir.path).contains { $0.hasPrefix("recordings-index.json.broken-") }, "Beschädigtes Original wurde nicht aufbewahrt")
        print("RecordingLibraryHarness: Bestand, Audioverfügbarkeit, Zeitgrenzen, aktive/fehlende/manipulierte Dateien, getrennte Daten, Schreib-/Löschfehler und Crash-Recovery OK")
    }
}

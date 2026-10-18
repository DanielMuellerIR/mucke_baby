import Foundation
import AVFoundation

actor ExportGate {
    let blocked: Set<UUID>
    let failing: Set<UUID>
    private var released = Set<UUID>()
    private(set) var started: [UUID] = []
    private var active = 0
    private(set) var peak = 0
    init(blocked: Set<UUID> = [], failing: Set<UUID> = []) { self.blocked = blocked; self.failing = failing }
    func release(_ id: UUID) { released.insert(id) }
    func render(_ job: ExportJob, _ directory: URL) async throws -> URL {
        started.append(job.id); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        while blocked.contains(job.id) && !released.contains(job.id) { try await Task.sleep(nanoseconds: 1_000_000) }
        try Task.checkCancellation()
        if failing.contains(job.id) { throw NSError(domain: "fixture", code: 1) }
        return directory.appendingPathComponent(job.id.uuidString + ".m4a")
    }
}

actor CommittedExportGate {
    private(set) var committed = false
    private var released = false
    func release() { released = true }
    func render(_ job: ExportJob, _ directory: URL) async throws -> URL {
        let result = directory.appendingPathComponent(job.id.uuidString + ".m4a")
        try Data("finished export".utf8).write(to: result, options: .atomic)
        committed = true
        while !released { await Task.yield() }
        return result
    }
}

@main enum ExportQueueHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 20)
        while !(await predicate()) {
            check(Date() < deadline, "Exportwarteschlange hängt")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func tone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for i in 0..<96_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.2) }
        try file.write(from: buffer)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-BatchTest-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let metadata = SongExportMetadata(raw: "Björk - Grüße (Live Remix)", artist: "Björk", title: "Grüße (Live Remix)",
                                          station: "Fixture 東京", recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        check(metadata.fileBase == "Björk - Grüße (Live Remix)", "Mix oder Unicode geht im Dateinamen verloren")
        for text in ["../\0evil:bad", String(repeating: "東京", count: 500), "\u{202e}hidden", "", ".hidden"] {
            let name = ExportFileNaming.safeBase(text)
            check(!name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":"), "unsicherer Exportname")
            check(name.utf8.count <= 180 && !name.contains("\0"), "Exportname überschreitet Dateisystemgrenze")
        }
        let dirty = SongExportMetadata(raw: "raw\0\ntext", artist: "\0", title: "", station: " A ", recordedAt: Date())
        check(dirty.artist == nil && dirty.title == "raw text" && dirty.station == "A", "fehlende Felder/Steuerzeichen")
        func job(_ source: URL? = nil) -> ExportJob { ExportJob(id: UUID(), metadata: metadata, source: source, offset: 0, duration: 1.5) }
        let jobs = (0..<4).map { _ in job() }
        let gate = ExportGate(blocked: [jobs[0].id], failing: [jobs[1].id])
        let queue = ExportQueue(jobs: jobs) { j, dir, _ in try await gate.render(j, dir) }
        queue.start(directory: root, mode: .hardCut)
        try await wait { await gate.started.count == 1 }
        queue.cancel(jobs[2].id); await gate.release(jobs[0].id)
        try await wait { !queue.isRunning }
        check(queue.succeededCount == 2 && queue.failedCount == 1 && queue.cancelledCount == 1 && queue.finishedCount == 4,
              "Teilergebnisse oder Einzelabbruch gehen verloren")
        let started = await gate.started, peak = await gate.peak
        check(started == [jobs[0].id, jobs[1].id, jobs[3].id] && peak == 1, "Reihenfolge oder Parallelitätsgrenze")
        queue.start(directory: root, mode: .faded)
        check(await gate.started == started, "fertiger Stapel wurde versehentlich erneut gestartet")

        let second = [job(), job()]; let secondGate = ExportGate(blocked: [second[0].id])
        let singleCancel = ExportQueue(jobs: second) { j, dir, _ in try await secondGate.render(j, dir) }
        singleCancel.start(directory: root, mode: .hardCut)
        try await wait { await secondGate.started.count == 1 }
        singleCancel.cancel(second[0].id); try await wait { !singleCancel.isRunning }
        check(singleCancel.cancelledCount == 1 && singleCancel.succeededCount == 1, "Einzelabbruch stoppt übrigen Stapel")

        let third = [job(), job(), job()]; let thirdGate = ExportGate(blocked: [third[1].id])
        let allCancel = ExportQueue(jobs: third) { j, dir, _ in try await thirdGate.render(j, dir) }
        allCancel.start(directory: root, mode: .hardCut)
        try await wait { await thirdGate.started.count == 2 }
        allCancel.cancelAll(); try await wait { !allCancel.isRunning }
        check(allCancel.succeededCount == 1 && allCancel.cancelledCount == 2, "Gesamtabbruch verliert fertiges Ergebnis")
        check(ExportQueue(jobs: []).items.isEmpty && ExportQueue(jobs: Array(repeating: jobs[0], count: 101)).items.isEmpty
              && ExportQueue(jobs: [jobs[0], jobs[0]]).items.isEmpty, "Stapelgrenzen/Dubletten werden nicht abgewiesen")
        let maximum = (0..<ExportQueue.limit).map { _ in job() }, maximumGate = ExportGate()
        let maximumQueue = ExportQueue(jobs: maximum) { j, dir, _ in try await maximumGate.render(j, dir) }
        maximumQueue.start(directory: root, mode: .hardCut); try await wait { !maximumQueue.isRunning }
        let maximumStarted = await maximumGate.started
        check(maximumQueue.succeededCount == 100 && maximumStarted == maximum.map(\.id),
              "Zulässiger voller Stapel verliert Einträge oder Reihenfolge")
        let committedGate = CommittedExportGate(), committedJob = job()
        let lateCancel = ExportQueue(jobs: [committedJob]) { j, dir, _ in try await committedGate.render(j, dir) }
        lateCancel.start(directory: root, mode: .hardCut)
        try await wait { await committedGate.committed }
        lateCancel.cancelAll(); await committedGate.release(); try await wait { !lateCancel.isRunning }
        check(lateCancel.succeededCount == 1 && lateCancel.cancelledCount == 0,
              "Später Abbruch erklärt eine bereits fertige Datei zum Fehlschlag")
        check(try Data(contentsOf: root.appendingPathComponent(committedJob.id.uuidString + ".m4a")) == Data("finished export".utf8),
              "Später Abbruch verändert fertige Datei")

        let source = root.appendingPathComponent("tone.wav"); try tone(source)
        let original = try Data(contentsOf: source)
        let destination = root.appendingPathComponent(metadata.fileBase + ".m4a"), sentinel = Data("unverändert".utf8)
        try sentinel.write(to: destination)
        let native = ExportQueue(jobs: [job(source), job(root.appendingPathComponent("missing.mp3")), job(source)])
        native.start(directory: root, mode: .hardCut); try await wait { !native.isRunning }
        check(native.succeededCount == 2 && native.failedCount == 1, "Realer Stapel mit fehlender Quelle")
        let files = native.items.compactMap { item -> URL? in if case .succeeded(let url) = item.status { return url }; return nil }
        check(files.map(\.lastPathComponent) == [metadata.fileBase + " (2).m4a", metadata.fileBase + " (3).m4a"], "Kollisionsfolge")
        check(try Data(contentsOf: source) == original && Data(contentsOf: destination) == sentinel, "Quelle oder vorhandenes Ziel verändert")
        check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".mucke-") }, "Staging nach Stapel übrig")
        let noReplace = root.appendingPathComponent("existing.m4a"); try sentinel.write(to: noReplace)
        do {
            try await SongExporter.export(source: source, offset: 0, duration: 1.5, mode: .hardCut,
                                          metadata: metadata, replaceExisting: false, to: noReplace)
            fatalError("Exklusiver Export ersetzt vorhandene Datei")
        } catch let error as NSError { check(error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST), "falscher Kollisionsfehler") }
        check(try Data(contentsOf: noReplace) == sentinel, "Exklusiver Export hat Sentinel verändert")
        let readOnly = root.appendingPathComponent("read-only", isDirectory: true)
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: false)
        let preserved = readOnly.appendingPathComponent("preserved.m4a")
        try sentinel.write(to: preserved)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        let writeFailure = ExportQueue(jobs: [job(source), job(source)])
        writeFailure.start(directory: readOnly, mode: .faded); try await wait { !writeFailure.isRunning }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
        check(writeFailure.failedCount == 2 && writeFailure.succeededCount == 0, "Schreibfehler beendet übrigen Stapel nicht sichtbar")
        check(try Data(contentsOf: preserved) == sentinel && fm.contentsOfDirectory(atPath: readOnly.path) == ["preserved.m4a"],
              "Schreibfehler verändert vorhandene Datei oder hinterlässt Staging")
        check(try Data(contentsOf: source) == original, "Schreibfehler verändert Quelle")
        if let path = ProcessInfo.processInfo.environment["MUCKE_BATCH_EVIDENCE"] {
            let evidence = URL(fileURLWithPath: path)
            try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
            for (index, file) in files.enumerated() { try fm.copyItem(at: file, to: evidence.appendingPathComponent("batch-\(index).m4a")) }
            let rendered = try await SongExporter.exportTemporary(source: source, offset: 0, duration: 1.5,
                                                                  name: metadata.fileBase, metadata: metadata)
            try fm.copyItem(at: rendered, to: evidence.appendingPathComponent("drag.m4a"))
            SongExporter.cleanupTemporaryExports()
        }
        print("ExportQueue: seriell, Einzel-/Gesamtabbruch, Teilerfolg, Grenzen, reale Kollisionen, Schreibfehler und Quellschutz OK")
    }
}

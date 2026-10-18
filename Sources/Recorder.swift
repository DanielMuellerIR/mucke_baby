import Foundation
import AVFAudio
import os
import Darwin

enum RecordingFileStatus: Equatable, Sendable {
    case available, missing, unreadable, empty
}

struct RecordingLibraryItem: Identifiable, Sendable {
    let clip: Recorder.Clip
    let status: RecordingFileStatus
    let bytes: Int64
    var id: UUID { clip.id }
    var isActive: Bool { clip.end == nil }
    var canPreview: Bool { !isActive && status == .available }
}

struct RecordedAudioSource: Sendable {
    let clipID: UUID
    let url: URL
    let offset: Double
    let duration: Double
}

struct RecordedAudioAvailability: Sendable {
    enum Status: Equatable, Sendable { case complete, partial, recording, missing, unreadable, none }
    let status: Status
    let source: RecordedAudioSource?
    var isPartial = false
    var label: String {
        switch status {
        case .complete: return String(localized: "Audio vollständig vorhanden")
        case .partial: return String(localized: "Audio teilweise vorhanden")
        case .recording: return String(localized: "Audio wird aufgenommen")
        case .missing: return String(localized: "Aufnahmedatei fehlt")
        case .unreadable: return String(localized: "Aufnahme nicht lesbar")
        case .none: return String(localized: "Keine Aufnahme")
        }
    }
}

struct RecordingLibrarySnapshot: Sendable {
    var items: [RecordingLibraryItem] = []
    var indexWritable = true
    var indexRecovered = false
    var directory: URL

    func audio(for entry: SongEntry, now: Date = Date()) -> RecordedAudioAvailability {
        let end = entry.end ?? now
        let candidates = items.filter {
            guard $0.clip.station == entry.station else { return false }
            if let id = entry.sessionID {
                return $0.clip.sessionID == id && $0.clip.start < end && ($0.clip.end ?? now) > entry.start
            }
            return $0.clip.start < end && ($0.clip.receivedEnd ?? $0.clip.end ?? now) > entry.start
        }
        guard let item = candidates.max(by: { $0.clip.start < $1.clip.start }) else {
            return RecordedAudioAvailability(status: .none, source: nil)
        }
        guard item.status == .available else {
            return RecordedAudioAvailability(status: item.status == .missing ? .missing : .unreadable, source: nil)
        }
        let start = max(entry.start, item.clip.start)
        let availableEnd = min(end, item.clip.end ?? now)
        let duration = availableEnd.timeIntervalSince(start)
        guard duration > 0.5 else { return RecordedAudioAvailability(status: .none, source: nil) }
        let source = RecordedAudioSource(clipID: item.id, url: directory.appendingPathComponent(item.clip.file),
                                         offset: start.timeIntervalSince(item.clip.start), duration: duration)
        let partial = start > entry.start || availableEnd < end
        return RecordedAudioAvailability(status: item.isActive ? .recording : partial ? .partial : .complete,
                                         source: source, isPartial: partial)
    }
}

enum RecordingLibraryError: LocalizedError {
    case missing, active, unreadable, indexUnavailable, removalFailed, indexRestoreFailed
    var errorDescription: String? {
        switch self {
        case .missing: return String(localized: "Diese Aufnahme ist nicht mehr vorhanden. Bitte die Liste aktualisieren.")
        case .active: return String(localized: "Eine laufende Aufnahme kann weder gelöscht noch vorgehört werden.")
        case .unreadable: return String(localized: "Die Aufnahme ist keine lesbare, reguläre Audiodatei.")
        case .indexUnavailable: return String(localized: "Der Aufnahmeindex konnte nicht gespeichert werden. Es wurde keine Datei gelöscht.")
        case .removalFailed: return String(localized: "Die Aufnahmedatei konnte nicht gelöscht werden. Sie bleibt in der Bibliothek.")
        case .indexRestoreFailed: return String(localized: "Die Datei wurde nicht gelöscht, aber der Aufnahmeindex konnte nicht wiederhergestellt werden. Bitte den Aufnahmeordner im Finder prüfen.")
        }
    }
}

private let log = Logger(subsystem: "de.danielmuller.macradio", category: "recorder")

// Schreibt den laufenden Stream als Roh-Audio-Dump in Dateien unter
// ~/Music/MuckeBaby/Aufnahmen/. Eine Datei pro Sender-Session; Rollover am
// naechsten Songwechsel nach 24 h. Stoppt bei < 10 GiB frei. Thread-sicher
// ueber eine serielle Queue (alle Datei-/Index-Operationen laufen dort).
//
// Mitschnitt ist Default AUS (seit v1.7.37, `recordStreams ?? false`); der Nutzer
// aktiviert ihn bewusst im Hauptfenster oder in den Einstellungen. Die Wahl bleibt erhalten.
//
// @unchecked Sendable: aller veraenderlicher Zustand wird ausschliesslich ueber die
// serielle Queue `q` angefasst -> thread-sicher. Erlaubt, den Recorder in einem
// Transferable (Drag&Drop-Export) ueber Concurrency-Grenzen mitzunehmen.
final class Recorder: @unchecked Sendable {

    // Ein aufgenommenes Stueck (Datei).
    struct Clip: Codable, Identifiable, Sendable {
        var id = UUID()
        var file: String
        var station: String
        var start: Date
        // Medienende für den Export; receivedEnd begrenzt die Empfangs-Session.
        var end: Date?
        var ext: String
        var sessionID: UUID? = nil
        var receivedEnd: Date? = nil
    }

    static let minFreeBytes: Int64 = 10 * 1024 * 1024 * 1024   // 10 GiB

    let dir: URL
    var onLowDisk: (() -> Void)?           // Main-Thread
    // Vor Benutzung einmal setzen; Zustellung erfolgt in Queue-Reihenfolge auf Main.
    var onCaptureState: ((RecordingState) -> Void)?
    private struct Capture {
        var station: String
        var streamID: UUID
        var contentType: String?
        var receivedAudio = false
        var canStartMidstream: Bool {
            let type = contentType?.lowercased().split(separator: ";").first.map(String.init) ?? ""
            return ["audio/mpeg", "audio/mp3", "audio/aac", "audio/aacp"].contains(type)
        }
        var segmentID = UUID()
        var enabledUptime: TimeInterval
    }
    private var capture: Capture?
    private var captureRequested = false
    private var captureHasEnded = false
    private var captureRevision: UInt64 = 0
    private var captureBlocked: RecordingState.Phase?
    private var captureBytes: Int64 = 0
    private var publishedBytes: Int64 = -1
    private var capacityTimer: DispatchSourceTimer?
    private let capacityCheckInterval: TimeInterval
    private let writeAudio: @Sendable (FileHandle, Data) throws -> Void
    private let removeAudio: @Sendable (URL) throws -> Void

    private let indexURL: URL
    private let removalURL: URL
    private let minimumFreeBytes: Int64
    private let availableCapacity: (@Sendable () -> Int64?)?
    private let q = DispatchQueue(label: "de.danielmuller.macradio.recorder")
    private var handle: FileHandle?
    private var fileStart: Date?
    private var bytesSinceCheck = 0
    private var clips: [Clip] = []
    private var indexWritable = true
    private var indexRecovered = false

    init(directory: URL? = nil, minimumFreeBytes: Int64 = Recorder.minFreeBytes,
         availableCapacity: (@Sendable () -> Int64?)? = nil, capacityCheckInterval: TimeInterval = 15,
         writeAudio: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
         removeAudio: @escaping @Sendable (URL) throws -> Void = {
             guard unlink($0.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
         }) {
        if let directory {
            // Expliziter Pfad ist fuer Headless-Tests/isolierte Werkzeuge; dabei
            // niemals reale Musikordner migrieren oder beruehren.
            dir = directory
        } else {
            migrateLegacyAppDir(in: .musicDirectory)   // alten „MacRadio"-Aufnahmeordner übernehmen
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            dir = music.appendingPathComponent("MuckeBaby/Aufnahmen", isDirectory: true)
        }
        self.writeAudio = writeAudio
        self.removeAudio = removeAudio
        self.capacityCheckInterval = max(0.01, capacityCheckInterval)
        self.minimumFreeBytes = minimumFreeBytes
        self.availableCapacity = availableCapacity
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("recordings-index.json")
        removalURL = dir.appendingPathComponent(".recording-removal.json")
        q.sync { loadIndex(); recoverPendingRemoval(); closeDangling() }
    }

    // Empfangsreihenfolge nutzt die monotone Uhr; Datum bleibt für Dateinamen und Verlauf.
    // Steuerung und Audio treffen auf derselben Datei-Queue ein. Alte Stream-IDs
    // dürfen eine neue Aufnahme weder beginnen noch schließen.
    func configureCapture(station: String, streamID: UUID, enabled: Bool, revision: UInt64, preserveFailure: Bool = false, at date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        q.async {
            self._close(at: date)
            let previousFailure = self.captureBlocked
            self.captureRequested = enabled; self.captureRevision = revision
            self.capture = Capture(station: station, streamID: streamID, enabledUptime: uptime)
            self.captureHasEnded = false
            self.captureBlocked = nil
            if preserveFailure, let previousFailure, [.lowDisk, .writeFailed, .indexUnavailable].contains(previousFailure) {
                self.captureBlocked = previousFailure
            }
            self.captureBytes = 0; self.publishedBytes = -1
            self.publishCapture()
        }
    }

    func setCaptureEnabled(_ enabled: Bool, revision: UInt64, at date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        q.async {
            self._close(at: date)
            self.captureRequested = enabled; self.captureRevision = revision
            self.captureBlocked = enabled && self.captureHasEnded ? .streamEnded : nil
            if enabled, let capture = self.capture, capture.receivedAudio, !capture.canStartMidstream {
                self.captureBlocked = .needsStreamHeader
            }
            self.captureBytes = 0; self.publishedBytes = -1
            self.capture?.enabledUptime = uptime; self.capture?.segmentID = UUID()
            self.publishCapture()
        }
    }

    func captureFormat(_ contentType: String?, streamID: UUID) {
        q.async { if self.capture?.streamID == streamID { self.capture?.contentType = contentType } }
    }

    func captureAudio(_ data: Data, at date: Date, receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime, streamID: UUID) {
        q.async {
            guard !data.isEmpty, let capture = self.capture, capture.streamID == streamID else { return }
            self.capture?.receivedAudio = true
            if self.captureRequested, self.captureBlocked == nil, receivedUptime < capture.enabledUptime,
               !capture.canStartMidstream {
                self.captureBlocked = .needsStreamHeader; self.publishCapture()
                return
            }
            guard self.captureRequested, self.captureBlocked == nil,
                  receivedUptime >= capture.enabledUptime, !data.isEmpty else { return }
            if self.handle == nil {
                self._begin(station: capture.station, ext: Self.ext(for: capture.contentType), at: date, sessionID: capture.segmentID)
                guard self.handle != nil else { self.publishCapture(); return }
            }
            guard self._write(data, at: date) else { self.publishCapture(); return }
            self.captureBytes += Int64(data.count)
            if self.captureBlocked != nil || self.publishedBytes < 0 || self.captureBytes - self.publishedBytes >= 64 * 1024 {
                self.publishCapture()
            }
        }
    }

    func finishCapture(streamID: UUID, at date: Date) {
        q.async {
            guard self.capture?.streamID == streamID else { return }
            self._close(at: date); self.capture = nil; self.captureHasEnded = true
            if self.captureRequested && self.captureBlocked == nil { self.captureBlocked = .streamEnded }
            self.publishCapture()
        }
    }

    func clearCapture(enabled: Bool, revision: UInt64, at date: Date = Date()) {
        q.async {
            self._close(at: date); self.capture = nil; self.captureHasEnded = false
            self.captureRequested = enabled; self.captureRevision = revision
            self.captureBlocked = nil; self.captureBytes = 0; self.publishCapture()
        }
    }

    func captureState() -> RecordingState { q.sync { currentCaptureState() } }

    private func currentCaptureState() -> RecordingState {
        let phase: RecordingState.Phase = !captureRequested ? .off
            : captureBlocked ?? (handle != nil && captureBytes > 0 ? .recording : .waiting)
        return RecordingState(phase: phase, revision: captureRevision, streamID: capture?.streamID,
                              segmentID: capture?.segmentID, startedAt: fileStart, bytes: captureBytes)
    }

    private func publishCapture(rollover: RecordingState.Rollover? = nil) {
        var state = currentCaptureState(); publishedBytes = captureBytes
        state.rollover = rollover
        DispatchQueue.main.async { self.onCaptureState?(state) }
    }

    deinit { capacityTimer?.cancel() }

    // Aufnahme fuer einen Sender starten (Codec-Endung aus Content-Type).
    func begin(station: String, contentType: String?, at date: Date = Date(), sessionID: UUID = UUID()) {
        q.async { self._begin(station: station, ext: Self.ext(for: contentType), at: date, sessionID: sessionID) }
    }

    func write(_ data: Data) {
        q.async {
            _ = self._write(data, at: Date())
        }
    }

    // Songwechsel: Rollover, falls die laufende Datei aelter als 24 h ist.
    func songBoundary(title: String? = nil, at date: Date = Date()) {
        q.async {
            guard let start = self.fileStart, let last = self.clips.last, last.end == nil else { return }
            if date.timeIntervalSince(start) > 24 * 3600 {
                let station = last.station, ext = last.ext
                self._close(at: date)
                if let capture = self.capture, !capture.canStartMidstream {
                    self.captureBlocked = .needsStreamHeader
                } else {
                    self._begin(station: station, ext: ext, at: date, sessionID: last.sessionID)
                }
                if self.capture != nil {
                    self.publishCapture(rollover: title.map { RecordingState.Rollover(title: $0, receivedAt: date) })
                }
            }
        }
    }

    func end(at date: Date = Date()) { q.async { self._close(at: date) } }

    // Vor App-Beendigung aufrufen: wartet, bis alle anstehenden Datei-/Index-
    // Operationen (insbesondere ein per end() angestossenes _close) abgearbeitet
    // sind. Sonst koennte der Prozess vor dem async _close beenden -> der letzte
    // Clip bliebe end == nil und wuerde beim naechsten Start als 0 s verworfen.
    func flush() { q.sync {} }

    // Aufnahmen loeschen, deren Ende vor `cutoff` liegt (Retention zum Verlauf).
    func prune(olderThan cutoff: Date) {
        q.async {
            var kept: [Clip] = []
            for c in self.clips {
                guard let e = c.end, e < cutoff else { kept.append(c); continue }
                // Verteidigung in der Tiefe: loadIndex() verwirft unsichere Namen
                // schon beim Laden; unmittelbar vor removeItem trotzdem erneut
                // pruefen, damit nie ein Pfad ausserhalb von `dir` geloescht wird.
                guard Self.isSafeClipFileName(c.file) else { continue }
                let target = self.dir.appendingPathComponent(c.file)
                // Nur regulaere Dateien loeschen. Ein schlichter Name ohne "/" kann
                // im Aufnahmeordner auch ein UNTERORDNER sein, und removeItem loescht
                // Verzeichnisse mitsamt Inhalt — der Loeschvertrag umfasst aber nur
                // Aufnahme-Dateien. attributesOfItem folgt Symlinks nicht, meldet also
                // den Link selbst. Der abgewiesene Eintrag bleibt zur Diagnose im
                // Index. Fehlt der Pfad ganz, gibt es keine Attribute -> unten greift
                // der fileNoSuchFile-Zweig und der Eintrag darf raus.
                let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                if let type = attributes?[.type] as? FileAttributeType, type != .typeRegular {
                    log.error("prune: Eintrag \(c.file, privacy: .public) ist keine reguläre Datei (type=\(String(describing: type), privacy: .public)) — bleibt im Index")
                    kept.append(c)
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: target)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Datei ist schon weg -> Eintrag darf trotzdem aus dem Index.
                } catch {
                    // Loeschen fehlgeschlagen (z. B. gesperrt/Rechte): Eintrag
                    // BEHALTEN. Frueher verschwand er trotzdem aus dem Index —
                    // die Datei blieb dann verwaist auf der Platte und war ueber
                    // die App weder erneut loeschbar noch exportierbar.
                    log.error("prune: Löschen von \(c.file, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public) — bleibt im Index")
                    kept.append(c)
                    continue
                }
            }
            if kept.count != self.clips.count { self.clips = kept; self.saveIndex() }
        }
    }

    /// Entfernt alle abgeschlossenen Aufnahme-Dateien. Eine laufende Aufnahme
    /// (`end == nil`, offenes Handle) bleibt erhalten. Die UI ruft dies erst nach
    /// einem expliziten destruktiven Bestätigungsdialog auf.
    func deleteAllCompleted() {
        prune(olderThan: .distantFuture)
    }

    // Snapshot des Index (fuer Export-UI), synchron.
    func snapshot() -> [Clip] { q.sync { clips } }

    // Datei- und Indexzugriffe bleiben auf der Recorder-Queue, nie im SwiftUI-Renderpfad.
    func librarySnapshot() async -> RecordingLibrarySnapshot {
        await withCheckedContinuation { continuation in
            q.async { continuation.resume(returning: self.makeLibrarySnapshot()) }
        }
    }

    func previewURL(id: UUID) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            q.async {
                guard let item = self.makeLibrarySnapshot().items.first(where: { $0.id == id }) else {
                    continuation.resume(throwing: RecordingLibraryError.missing); return
                }
                guard !item.isActive else { continuation.resume(throwing: RecordingLibraryError.active); return }
                guard item.canPreview else { continuation.resume(throwing: RecordingLibraryError.unreadable); return }
                continuation.resume(returning: self.dir.appendingPathComponent(item.clip.file))
            }
        }
    }

    func removeCompleted(id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            q.async {
                do { try self.removeCompletedOnQueue(id: id); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func makeLibrarySnapshot() -> RecordingLibrarySnapshot {
        let items = clips.map { clip -> RecordingLibraryItem in
            let url = dir.appendingPathComponent(clip.file)
            guard Self.isSafeClipFileName(clip.file) else {
                return RecordingLibraryItem(clip: clip, status: .unreadable, bytes: 0)
            }
            let found: [FileAttributeKey: Any]?
            do { found = try recordingAttributes(url) }
            catch { return RecordingLibraryItem(clip: clip, status: .unreadable, bytes: 0) }
            guard let attributes = found else {
                return RecordingLibraryItem(clip: clip, status: .missing, bytes: 0)
            }
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                return RecordingLibraryItem(clip: clip, status: .unreadable, bytes: bytes)
            }
            return RecordingLibraryItem(clip: clip, status: bytes > 0 ? .available : .empty, bytes: bytes)
        }
        return RecordingLibrarySnapshot(items: items.sorted { $0.clip.start > $1.clip.start },
                                        indexWritable: indexWritable, indexRecovered: indexRecovered, directory: dir)
    }

    private func removeCompletedOnQueue(id: UUID) throws {
        guard indexWritable, !FileManager.default.fileExists(atPath: removalURL.path) else { throw RecordingLibraryError.indexUnavailable }
        guard let clip = clips.first(where: { $0.id == id }) else { throw RecordingLibraryError.missing }
        guard clip.end != nil else { throw RecordingLibraryError.active }
        let url = dir.appendingPathComponent(clip.file)
        guard Self.isSafeClipFileName(clip.file) else { throw RecordingLibraryError.unreadable }
        let attributes: [FileAttributeKey: Any]?
        do { attributes = try recordingAttributes(url) }
        catch { throw RecordingLibraryError.unreadable }
        if let attributes, attributes[.type] as? FileAttributeType != .typeRegular { throw RecordingLibraryError.unreadable }
        let next = clips.filter { $0.id != id }
        // Ein Index-Schreibfehler muss vor der unwiderruflichen Dateientfernung auffallen.
        // Das Journal bewahrt die Zuordnung, falls die App zwischen Index und unlink endet.
        do {
            try JSONEncoder.isoPretty.encode(clip).write(to: removalURL, options: .atomic)
            try JSONEncoder.isoPretty.encode(next).write(to: indexURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: removalURL)
            throw RecordingLibraryError.indexUnavailable
        }
        do {
            if attributes != nil { try removeAudio(url) }
        } catch {
            // unlink entfernt niemals Verzeichnisse rekursiv, auch bei einem externen Pfadtausch.
            if !saveIndex() { indexWritable = false; throw RecordingLibraryError.indexRestoreFailed }
            try? FileManager.default.removeItem(at: removalURL)
            throw RecordingLibraryError.removalFailed
        }
        clips = next
        try? FileManager.default.removeItem(at: removalURL)
    }

    private func recoverPendingRemoval() {
        guard FileManager.default.fileExists(atPath: removalURL.path), indexWritable else { return }
        do {
            let clip = try JSONDecoder.iso.decode(Clip.self, from: Data(contentsOf: removalURL))
            guard Self.isSafeClipFileName(clip.file), clip.end != nil else { throw RecordingLibraryError.unreadable }
            let attributes = try recordingAttributes(dir.appendingPathComponent(clip.file))
            if attributes != nil, !clips.contains(where: { $0.id == clip.id }) {
                guard attributes?[.type] as? FileAttributeType == .typeRegular,
                      !clips.contains(where: { $0.file == clip.file }) else { throw RecordingLibraryError.unreadable }
                clips.append(clip)
                guard saveIndex() else { throw RecordingLibraryError.indexUnavailable }
            }
            try FileManager.default.removeItem(at: removalURL)
        } catch { indexWritable = false }
    }

    private func recordingAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }

    // Die Medienlänge darf keinen späteren Empfangszeitpunkt einer anderen
    // Wiedergabe abdecken. Alte Indexeinträge haben nur die bisherige Endzeit.
    func clip(covering date: Date) -> Clip? {
        q.sync { clips.last { $0.start <= date && (($0.receivedEnd ?? $0.end ?? Date.distantFuture) > date) } }
    }

    // Verlauf kann nach Aufnahmeabbruch oder Crash länger als die Datei laufen.
    // Dateiexport und Drag verwenden deshalb dieselbe begrenzte Zeitspanne.
    func exportSource(for entry: SongEntry, now: Date = Date()) -> (url: URL, offset: Double, duration: Double)? {
        guard let source = audioAvailability(for: entry, now: now).source else { return nil }
        return (source.url, source.offset, source.duration)
    }

    func audioAvailability(for entry: SongEntry, now: Date = Date()) -> RecordedAudioAvailability {
        q.sync { makeLibrarySnapshot().audio(for: entry, now: now) }
    }

    // MARK: - intern (immer auf q)

    private func _begin(station: String, ext: String, at date: Date, sessionID: UUID?) {
        guard indexWritable else { captureBlocked = .indexUnavailable; return }
        _close(at: date)
        guard hasSpace() else {
            captureBlocked = .lowDisk
            DispatchQueue.main.async { self.onLowDisk?() }
            return
        }
        let name = fileName(station: station, date: date, ext: ext)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else {
            // Schlaegt das Oeffnen fehl, bleibt sonst die eben per createFile erzeugte
            // leere 0-Byte-Datei als Muell im Aufnahmeordner liegen (kein Clip/Index
            // kennt sie) — deshalb hier wieder entfernen.
            try? FileManager.default.removeItem(at: url)
            captureBlocked = .writeFailed
            return
        }
        fileStart = date
        captureBytes = 0; publishedBytes = -1
        clips.append(Clip(file: name, station: station, start: date, end: nil, ext: ext, sessionID: sessionID))
        guard saveIndex() else {
            // Ohne gespeicherten Index wäre diese neue Datei nach Neustart verwaist.
            // Noch sind keine Audiobytes geschrieben; nur die eigene leere Datei entfernen.
            try? handle?.close()
            handle = nil; fileStart = nil
            clips.removeLast()
            try? FileManager.default.removeItem(at: url)
            captureBlocked = .writeFailed
            return
        }
        startCapacityTimer()
    }

    private func _write(_ data: Data, at date: Date) -> Bool {
        guard let handle else { return false }
        do { try writeAudio(handle, data) }
        catch { _close(at: date); captureBlocked = .writeFailed; publishCapture(); return false }
        bytesSinceCheck += data.count
        if bytesSinceCheck > 8 * 1024 * 1024 {
            bytesSinceCheck = 0
            _ = checkCapacity(at: date)
        }
        return true
    }

    private func startCapacityTimer() {
        capacityTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + capacityCheckInterval, repeating: capacityCheckInterval)
        timer.setEventHandler { [weak self] in _ = self?.checkCapacity(at: Date()) }
        capacityTimer = timer; timer.resume()
    }

    private func checkCapacity(at date: Date) -> Bool {
        guard handle != nil else { return false }
        guard hasSpace() else {
            _close(at: date); captureBlocked = .lowDisk; publishCapture()
            DispatchQueue.main.async { self.onLowDisk?() }
            return false
        }
        return true
    }

    private func _close(at date: Date) {
        capacityTimer?.cancel(); capacityTimer = nil
        guard handle != nil else { return }
        try? handle?.close()
        handle = nil; fileStart = nil; bytesSinceCheck = 0
        if let i = clips.indices.last, clips[i].end == nil {
            clips[i].receivedEnd = max(clips[i].start, date)
            clips[i].end = recordingEnd(for: clips[i], receivedEnd: date)
            if !saveIndex() { captureBlocked = .writeFailed }
        }
    }

    // Beim Start: offene Eintraege aus einem Absturz schliessen. Medienlänge
    // bevorzugen; sonst Datei-Aenderungszeit verwenden, nie vor dem Start
    // (Clock-Skew); ohne lesbare Datei auf Start zurueckfallen. Frueher wurde stur end = start gesetzt -> 0 s-Intervall,
    // wodurch clip(covering:) fuer alle spaeter notierten Songs der Session
    // fehlschlug und der Mitschnitt nicht mehr exportierbar war.
    private func closeDangling() {
        var changed = false
        for i in clips.indices where clips[i].end == nil {
            let url = dir.appendingPathComponent(clips[i].file)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            clips[i].receivedEnd = max(clips[i].start, mtime ?? clips[i].start)
            clips[i].end = recordingEnd(for: clips[i], receivedEnd: mtime ?? clips[i].start)
            changed = true
        }
        if changed { saveIndex() }
    }

    // Ein Callback kann Sekunden Audio auf einmal enthalten. Für lesbare
    // Aufnahmen liefert die Datei ihre Medienlänge; Empfangszeit ist nur der
    // Fallback für vom System nicht unterstützte oder unvollständige Codecs.
    private func recordingEnd(for clip: Clip, receivedEnd: Date) -> Date {
        let url = dir.appendingPathComponent(clip.file)
        if let attributes = try? recordingAttributes(url), attributes[.type] as? FileAttributeType == .typeRegular,
           let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 {
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            if duration.isFinite, duration > 0 { return clip.start.addingTimeInterval(duration) }
        }
        return max(clip.start, receivedEnd)
    }

    private func hasSpace() -> Bool {
        if let availableCapacity, let free = availableCapacity() { return free > minimumFreeBytes }
        guard let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage else { return true }
        return free > minimumFreeBytes
    }

    private func fileName(station: String, date: Date, ext: String) -> String {
        let safe = station.replacingOccurrences(of: #"[^A-Za-z0-9 _.-]"#, with: "_",
                                                options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Feste Locale + gregorianischer Kalender: ein blankes DateFormatter erbt
        // sonst System-Locale/-Kalender, und auf nicht-gregorianischen Kalendern
        // (japanisch/buddhistisch) liefert `yyyy` ein anderes Jahr (z. B. 2569) —
        // der Dateiname widerspraeche dann den ISO-Daten im Index.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "\(f.string(from: date)) \(safe)"
        var name = "\(base).\(ext)"
        // Kollision vermeiden: existiert die Zieldatei schon (z. B. 24h-Rollover mit
        // identischem Sekunden-Zeitstempel), eindeutigen Suffix anhaengen — sonst
        // wuerde createFile die vorige Aufnahme auf 0 Bytes kuerzen.
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
        }
        return name
    }

    // Nur ein schlichter Dateiname (ein einzelnes Pfadsegment, kein "..") darf
    // im Index stehen: recordings-index.json ist von aussen editier-/restaurier-
    // bar, und prune() haengt den Wert direkt an `dir` an — "../"-Segmente
    // wuerden removeItem sonst auf Pfade ausserhalb des Aufnahmeordners richten.
    static func isSafeClipFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    private func loadIndex() {
        do {
            let existed = FileManager.default.fileExists(atPath: indexURL.path)
            let loaded = try JSONFileRecovery.load([Clip].self, from: indexURL, decoder: .iso)
            indexRecovered = existed && loaded == nil
            let list = loaded ?? []
            // Unsichere Dateinamen sofort verwerfen (siehe isSafeClipFileName).
            clips = list.filter { Self.isSafeClipFileName($0.file) }
        } catch {
            indexWritable = false
            log.error("loadIndex: Indexdatei \(self.indexURL.path, privacy: .public) unlesbar oder beschädigt: \(error.localizedDescription, privacy: .public)")
        }
    }
    @discardableResult
    private func saveIndex() -> Bool {
        guard indexWritable else { return false }
        do {
            try JSONEncoder.isoPretty.encode(clips).write(to: indexURL, options: .atomic)
            return true
        } catch {
            log.error("saveIndex: Aufnahmeindex konnte nicht gespeichert werden: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // Content-Type -> Datei-Endung.
    static func ext(for contentType: String?) -> String {
        let c = (contentType ?? "").lowercased()
        if c.contains("mpeg") || c.contains("mp3") { return "mp3" }
        if c.contains("aac") { return "aac" }
        if c.contains("opus") { return "opus" }
        if c.contains("ogg") || c.contains("vorbis") { return "ogg" }
        if c.contains("flac") { return "flac" }
        return "mp3"   // haeufigster Fall als Default
    }
}

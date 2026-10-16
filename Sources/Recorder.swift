import Foundation
import AVFAudio
import os

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
    struct Clip: Codable, Identifiable {
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
        var segmentID = UUID()
        var enabledAt: Date
    }
    private var capture: Capture?
    private var captureRequested = false
    private var captureRevision: UInt64 = 0
    private var captureBlocked: RecordingState.Phase?
    private var captureBytes: Int64 = 0
    private var publishedBytes: Int64 = -1
    private var capacityTimer: DispatchSourceTimer?
    private let capacityCheckInterval: TimeInterval
    private let writeAudio: @Sendable (FileHandle, Data) throws -> Void

    private let indexURL: URL
    private let minimumFreeBytes: Int64
    private let availableCapacity: (@Sendable () -> Int64?)?
    private let q = DispatchQueue(label: "de.danielmuller.macradio.recorder")
    private var handle: FileHandle?
    private var fileStart: Date?
    private var bytesSinceCheck = 0
    private var clips: [Clip] = []
    private var indexWritable = true

    init(directory: URL? = nil, minimumFreeBytes: Int64 = Recorder.minFreeBytes,
         availableCapacity: (@Sendable () -> Int64?)? = nil, capacityCheckInterval: TimeInterval = 15,
         writeAudio: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
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
        self.capacityCheckInterval = max(0.01, capacityCheckInterval)
        self.minimumFreeBytes = minimumFreeBytes
        self.availableCapacity = availableCapacity
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("recordings-index.json")
        q.sync { loadIndex(); closeDangling() }
    }

    // Steuerung und Audio treffen auf derselben Datei-Queue ein. Alte Stream-IDs
    // dürfen eine neue Aufnahme weder beginnen noch schließen.
    func configureCapture(station: String, streamID: UUID, enabled: Bool, revision: UInt64, at date: Date = Date()) {
        q.async {
            self._close(at: date)
            self.captureRequested = enabled; self.captureRevision = revision
            self.capture = Capture(station: station, streamID: streamID, enabledAt: date)
            self.captureBlocked = nil; self.captureBytes = 0; self.publishedBytes = -1
            self.publishCapture()
        }
    }

    func setCaptureEnabled(_ enabled: Bool, revision: UInt64, at date: Date = Date()) {
        q.async {
            self._close(at: date)
            self.captureRequested = enabled; self.captureRevision = revision
            if !enabled || self.capture != nil { self.captureBlocked = nil }
            self.captureBytes = 0; self.publishedBytes = -1
            self.capture?.enabledAt = date; self.capture?.segmentID = UUID()
            self.publishCapture()
        }
    }

    func captureFormat(_ contentType: String?, streamID: UUID) {
        q.async { if self.capture?.streamID == streamID { self.capture?.contentType = contentType } }
    }

    func captureAudio(_ data: Data, at date: Date, streamID: UUID) {
        q.async {
            guard let capture = self.capture, capture.streamID == streamID,
                  self.captureRequested, self.captureBlocked == nil,
                  date >= capture.enabledAt, !data.isEmpty else { return }
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
            self._close(at: date); self.capture = nil
            if self.captureRequested && self.captureBlocked == nil { self.captureBlocked = .streamEnded }
            self.publishCapture()
        }
    }

    func clearCapture(enabled: Bool, revision: UInt64, at date: Date = Date()) {
        q.async {
            self._close(at: date); self.capture = nil
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

    private func publishCapture() {
        let state = currentCaptureState(); publishedBytes = captureBytes
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
    func songBoundary(at date: Date = Date()) {
        q.async {
            guard let start = self.fileStart, let last = self.clips.last, last.end == nil else { return }
            if date.timeIntervalSince(start) > 24 * 3600 {
                let station = last.station, ext = last.ext
                self._close(at: date)
                self._begin(station: station, ext: ext, at: date, sessionID: last.sessionID)
                if self.capture != nil { self.publishCapture() }
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

    // Die Medienlänge darf keinen späteren Empfangszeitpunkt einer anderen
    // Wiedergabe abdecken. Alte Indexeinträge haben nur die bisherige Endzeit.
    func clip(covering date: Date) -> Clip? {
        q.sync { clips.last { $0.start <= date && (($0.receivedEnd ?? $0.end ?? Date.distantFuture) > date) } }
    }

    // Verlauf kann nach Aufnahmeabbruch oder Crash länger als die Datei laufen.
    // Dateiexport und Drag verwenden deshalb dieselbe begrenzte Zeitspanne.
    func exportSource(for entry: SongEntry, now: Date = Date()) -> (url: URL, offset: Double, duration: Double)? {
        let clip = q.sync {
            clips.last {
                guard $0.station == entry.station, $0.start <= entry.start else { return false }
                if let sessionID = entry.sessionID { return $0.sessionID == sessionID }
                return ($0.receivedEnd ?? $0.end ?? Date.distantFuture) > entry.start
            }
        }
        guard let clip else { return nil }
        let end = min(entry.end ?? now, clip.end ?? now)
        let duration = end.timeIntervalSince(entry.start)
        guard duration > 0.5 else { return nil }
        return (dir.appendingPathComponent(clip.file), entry.start.timeIntervalSince(clip.start), duration)
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
        if let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 {
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
            let list = try JSONFileRecovery.load([Clip].self, from: indexURL, decoder: .iso) ?? []
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

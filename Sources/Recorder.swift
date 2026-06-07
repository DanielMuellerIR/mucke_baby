import Foundation

// Schreibt den laufenden Stream als Roh-Audio-Dump in Dateien unter
// ~/Music/MuckeBaby/Aufnahmen/. Eine Datei pro Sender-Session; Rollover am
// naechsten Songwechsel nach 24 h. Stoppt bei < 10 GB frei. Thread-sicher
// ueber eine serielle Queue (alle Datei-/Index-Operationen laufen dort).
//
// Achtung: Mitschnitt ist Default AN — README warnt davor.
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
        var end: Date?
        var ext: String
    }

    static let minFreeBytes: Int64 = 10 * 1024 * 1024 * 1024   // 10 GB

    let dir: URL
    var onLowDisk: (() -> Void)?           // Main-Thread

    private let indexURL: URL
    private let q = DispatchQueue(label: "de.danielmuller.macradio.recorder")
    private var handle: FileHandle?
    private var fileStart: Date?
    private var bytesSinceCheck = 0
    private var clips: [Clip] = []

    init() {
        migrateLegacyAppDir(in: .musicDirectory)   // alten „MacRadio"-Aufnahmeordner übernehmen
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        dir = music.appendingPathComponent("MuckeBaby/Aufnahmen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("recordings-index.json")
        q.sync { loadIndex(); closeDangling() }
    }

    // Aufnahme fuer einen Sender starten (Codec-Endung aus Content-Type).
    func begin(station: String, contentType: String?, at date: Date = Date()) {
        q.async { self._begin(station: station, ext: Self.ext(for: contentType), at: date) }
    }

    func write(_ data: Data) {
        q.async {
            guard let h = self.handle else { return }
            do { try h.write(contentsOf: data) } catch { self._close(at: Date()) ; return }
            self.bytesSinceCheck += data.count
            if self.bytesSinceCheck > 8 * 1024 * 1024 {          // alle ~8 MB Platz pruefen
                self.bytesSinceCheck = 0
                if !self.hasSpace() {
                    self._close(at: Date())
                    DispatchQueue.main.async { self.onLowDisk?() }
                }
            }
        }
    }

    // Songwechsel: Rollover, falls die laufende Datei aelter als 24 h ist.
    func songBoundary(at date: Date = Date()) {
        q.async {
            guard let start = self.fileStart, var last = self.clips.last, last.end == nil else { return }
            if date.timeIntervalSince(start) > 24 * 3600 {
                let station = last.station, ext = last.ext
                self._close(at: date)
                self._begin(station: station, ext: ext, at: date)
                _ = last   // (nur zur Klarheit)
            }
        }
    }

    func end(at date: Date = Date()) { q.async { self._close(at: date) } }

    // Aufnahmen loeschen, deren Ende vor `cutoff` liegt (Retention zum Verlauf).
    func prune(olderThan cutoff: Date) {
        q.async {
            var kept: [Clip] = []
            for c in self.clips {
                if let e = c.end, e < cutoff {
                    try? FileManager.default.removeItem(at: self.dir.appendingPathComponent(c.file))
                } else { kept.append(c) }
            }
            if kept.count != self.clips.count { self.clips = kept; self.saveIndex() }
        }
    }

    // Snapshot des Index (fuer Export-UI), synchron.
    func snapshot() -> [Clip] { q.sync { clips } }

    // Clip, der einen Zeitpunkt abdeckt (fuer Song-Export).
    func clip(covering date: Date) -> Clip? {
        q.sync { clips.first { $0.start <= date && (($0.end ?? Date.distantFuture) >= date) } }
    }

    // MARK: - intern (immer auf q)

    private func _begin(station: String, ext: String, at date: Date) {
        _close(at: date)
        guard hasSpace() else { DispatchQueue.main.async { self.onLowDisk?() }; return }
        let name = fileName(station: station, date: date, ext: ext)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else { return }
        fileStart = date
        clips.append(Clip(file: name, station: station, start: date, end: nil, ext: ext))
        saveIndex()
    }

    private func _close(at date: Date) {
        guard handle != nil else { return }
        try? handle?.close()
        handle = nil; fileStart = nil; bytesSinceCheck = 0
        if let i = clips.indices.last, clips[i].end == nil { clips[i].end = date; saveIndex() }
    }

    // Beim Start: offene Eintraege aus einem Absturz schliessen (Dateigroesse-Zeit).
    private func closeDangling() {
        var changed = false
        for i in clips.indices where clips[i].end == nil {
            clips[i].end = clips[i].start   // unbekannt -> auf Start setzen
            changed = true
        }
        if changed { saveIndex() }
    }

    private func hasSpace() -> Bool {
        guard let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage else { return true }
        return free > Self.minFreeBytes
    }

    private func fileName(station: String, date: Date, ext: String) -> String {
        let safe = station.replacingOccurrences(of: #"[^A-Za-z0-9 _.-]"#, with: "_",
                                                options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(f.string(from: date)) \(safe).\(ext)"
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder.iso.decode([Clip].self, from: data) else { return }
        clips = list
    }
    private func saveIndex() {
        if let data = try? JSONEncoder.isoPretty.encode(clips) {
            try? data.write(to: indexURL, options: .atomic)
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

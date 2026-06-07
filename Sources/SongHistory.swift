import Foundation

// Ein gehoerter Titel: Sender, Roh-Text (ICY), aufgeteilt in Interpret/Titel,
// plus Start/Ende. `end == nil` => laeuft gerade noch.
struct SongEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var station: String
    var raw: String
    var artist: String?
    var title: String?
    var start: Date
    var end: Date?
    // B1: true => Sammel-Platzhalter fuer den laufenden Mitschnitt (kein echter
    // ICY-Titel). Optional, damit eine alte verlauf.json ohne dieses Feld weiter laedt.
    var placeholder: Bool? = nil

    var isPlaceholder: Bool { placeholder == true }

    // ICY liefert meist "Interpret - Titel". Sauber auftrennen, sonst alles als Titel.
    static func split(_ s: String) -> (artist: String?, title: String?) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: " - ") {
            let a = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (a.isEmpty ? nil : a, b.isEmpty ? nil : b)
        }
        return (nil, t.isEmpty ? nil : t)
    }
}

// Fuehrt den Wiedergabe-Verlauf: pro gehoertem Titel ein Eintrag mit Zeitspanne.
// Beim Songwechsel/Senderwechsel/Stop wird der laufende Eintrag mit Endzeit
// geschlossen. Persistiert nach Application Support, ueberlebt Neustarts.
@MainActor
final class SongHistory: ObservableObject {
    @Published private(set) var entries: [SongEntry] = []

    private let fileURL: URL
    private let maxEntries = 2000
    // Aufraeum-Schwellen fuer kurze Eintraege (ICY-Glitches, Jingles, kurz
    // angespielte Sender / Mitschnitte). Stand 2026-06-07.
    private let shortImmediate: TimeInterval = 5    // < 5 s: sofort beim Schliessen weg
    private let shortLaunchQuit: TimeInterval = 20  // < 20 s: bei Start und Beenden weg

    init() {
        migrateLegacyAppDir(in: .applicationSupportDirectory)   // alten „MacRadio"-Ordner übernehmen
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("verlauf.json")
        load()
    }

    // Neue Now-Playing-Info verarbeiten. Gleicher Titel/Sender wie der offene
    // Eintrag -> ignorieren. Sonst alten schliessen + neuen oeffnen.
    func note(station: String, raw: String, at date: Date = Date()) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = entries.last, last.end == nil,
           last.station == station, last.raw == text {
            return  // selber Song laeuft weiter
        }
        // Offenen Eintrag schliessen. closeCurrent() raeumt dabei alle Fragmente
        // < 5 s weg — auch einen Mitschnitt-Platzhalter, dessen erster echter Titel
        // quasi sofort kam (bei Titel-Sendern keine 0-Sekunden-"Mitschnitt"-Zeile).
        // Deckte der Platzhalter eine echte titel-lose Luecke (>= 5 s) ab, bleibt er.
        closeCurrent(at: date)
        let (artist, title) = SongEntry.split(text)
        entries.append(SongEntry(station: station, raw: text,
                                 artist: artist, title: title, start: date))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        save()
    }

    // B1: Platzhalter-Eintrag fuer eine Mitschnitt-Session oeffnen. Deckt die Zeit
    // vom Senderstart bis zum ersten echten ICY-Titel ab. Ohne ihn waere der
    // Mitschnitt von Sendern OHNE Songtitel (z.B. Hirschmilch/opus) nicht ueber den
    // Verlauf erreichbar (Export haengt am Verlauf-Eintrag). `at` deckt sich mit dem
    // Recorder-Clip-Start, damit der Export-Offset stimmt. Kommt spaeter ein echter
    // Titel, schliesst `note()` den Platzhalter und legt normale Eintraege zusaetzlich an.
    func beginSession(station: String, at date: Date = Date()) {
        closeCurrent(at: date)
        entries.append(SongEntry(station: station, raw: "Mitschnitt", start: date, placeholder: true))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        save()
    }

    // Laufenden Eintrag mit Endzeit versehen (Stop/Senderwechsel/Songwechsel) und
    // anschliessend alle geschlossenen Fragmente < 5 s entfernen ("sofort nach Ende
    // des Mitschnitts"). Laufende (offene) Eintraege bleiben unangetastet.
    func closeCurrent(at date: Date = Date()) {
        var changed = false
        if let i = entries.indices.last, entries[i].end == nil {
            entries[i].end = date; changed = true
        }
        if removeShort(shortImmediate) { changed = true }
        if changed { save() }
    }

    // Bei Start UND Beenden aufrufen: alle geschlossenen Eintraege < 20 s entfernen
    // (raeumt auch Altbestand kurzer Mitschnitte nachtraeglich weg).
    func pruneOnLaunchOrQuit() {
        if removeShort(shortLaunchQuit) { save() }
    }

    // Geschlossene Eintraege kuerzer als `maxSeconds` aus der Liste werfen.
    // Offene (laufende) Eintraege nie. Gibt zurueck, ob etwas entfernt wurde.
    @discardableResult
    private func removeShort(_ maxSeconds: TimeInterval) -> Bool {
        let before = entries.count
        entries.removeAll { e in
            guard let end = e.end else { return false }   // laufenden Eintrag behalten
            return end.timeIntervalSince(e.start) < maxSeconds
        }
        return entries.count != before
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // Eintraege entfernen, deren Ende (bzw. Start) vor `cutoff` liegt.
    func remove(olderThan cutoff: Date) {
        let before = entries.count
        entries.removeAll { ($0.end ?? $0.start) < cutoff }
        if entries.count != before { save() }
    }

    // MARK: - Persistenz

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso.decode([SongEntry].self, from: data)
        else { return }
        entries = decoded
        // Beim Start war evtl. ein Eintrag noch offen -> schliessen, damit kein
        // ueber Tage "laufender" Song stehen bleibt.
        closeCurrent()
        // Beim Start kurze Fragmente (< 20 s) wegputzen — inkl. Altbestand.
        pruneOnLaunchOrQuit()
    }

    private func save() {
        guard let data = try? JSONEncoder.isoPretty.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// ISO-8601-Datums-Coder (alphabetisch sortierbar, eindeutig).
extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
extension JSONEncoder {
    static var isoPretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

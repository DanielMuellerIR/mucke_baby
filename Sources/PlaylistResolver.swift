import Foundation

// Loest Playlist-URLs (.pls/.m3u/.asx/.xspf, radiotime Tune.ashx) zur
// eigentlichen Stream-URL auf. AVPlayer kann diese Container nicht direkt
// abspielen — er braucht die rohe mp3/aac/HLS-URL.
enum PlaylistResolver {

    // Liefert die abspielbare URL. Bei Fehlern wird die Eingabe-URL
    // unveraendert zurueckgegeben (AVPlayer meldet dann ggf. selbst Fehler).
    static func resolve(_ raw: String, depth: Int = 0) async -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        if depth > 3 { return url }                 // Schutz gegen Endlos-Verschachtelung
        guard needsResolution(url) else { return url }
        guard let text = await fetchHead(url) else { return url }
        guard let inner = firstMediaURL(in: text) else { return url }
        if inner.absoluteString == url.absoluteString { return url }
        // Playlist kann auf weitere Playlist zeigen -> rekursiv aufloesen.
        return await resolve(inner.absoluteString, depth: depth + 1)
    }

    // Heuristik: nur fetchen, wenn die URL nach Playlist aussieht.
    // Wichtig: .m3u8 ist HLS und geht direkt an AVPlayer (NICHT fetchen).
    static func needsResolution(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        if s.contains(".m3u8") { return false }
        // Nur echte Playlist-Endungen/-Pfade. Achtung: manche Direkt-Streams
        // haben "pls" im Namen (z. B. .../tunein-aac-hd-pls liefert rohes AAC) —
        // daher NICHT auf den blossen Teilstring "pls" matchen.
        return s.contains(".pls") || s.contains(".m3u") || s.contains(".asx")
            || s.contains(".xspf") || s.contains("tune.ashx") || s.contains("/pls")
    }

    // Nur die ersten ~64 KB laden, damit ein faelschlich als Playlist
    // erkannter Audio-Stream nicht komplett heruntergeladen wird.
    static func fetchHead(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        req.setValue("MuckeBaby/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        } catch {
            return nil
        }
    }

    // Findet die erste Media-URL in PLS/M3U/ASX/XSPF-Inhalten.
    static func firstMediaURL(in text: String) -> URL? {
        // PLS: Zeilen "FileN=http://..."
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("file"), let eq = l.firstIndex(of: "=") {
                let value = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if let u = URL(string: value), u.scheme?.hasPrefix("http") == true { return u }
            }
        }
        // M3U / Klartext: erste Zeile, die wie eine http-URL aussieht
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("[") { continue }
            if l.lowercased().hasPrefix("http"), let u = URL(string: l) { return u }
        }
        // ASX/XSPF: <location>URL</location> oder href="URL"
        if let m = firstMatch(text, pattern: "(?:<location>|href=\")\\s*(https?://[^<\"\\s]+)") {
            return URL(string: m)
        }
        return nil
    }

    static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

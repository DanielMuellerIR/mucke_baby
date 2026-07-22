import Foundation

// Loest Playlist-URLs (.pls/.m3u/.asx/.xspf, radiotime Tune.ashx) zur
// eigentlichen Stream-URL auf. AVPlayer kann diese Container nicht direkt
// abspielen — er braucht die rohe mp3/aac/HLS-URL.
enum PlaylistResolver {

    // Liefert ausschliesslich eine von StreamURLPolicy erlaubte Web-URL. Ein
    // erkannter Playlist-Container wird fail-closed behandelt: Kann sein Ziel
    // nicht sicher aufgeloest werden, bekommt VLC nicht den rohen Container und
    // kann dadurch auch kein file:/ oder anderes lokales Ziel selbst verfolgen.
    static func resolve(_ raw: String, depth: Int = 0) async -> URL? {
        guard let url = StreamURLPolicy.validatedURL(raw) else { return nil }
        if depth > 3 { return nil }                 // Schutz gegen Endlos-Verschachtelung
        guard needsResolution(url) else { return url }
        guard let text = await fetchHead(url) else { return nil }
        guard let inner = firstMediaURL(in: text) else { return nil }
        if inner.absoluteString == url.absoluteString { return nil }
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
            // Hart auf ~64 KB deckeln: Der Range-Header ist nur eine Bitte. Ignoriert
            // der Server ihn, lieferte data(for:) den GANZEN — bei einem als Playlist
            // fehlerkannten Live-Stream endlosen — Body in den RAM (OOM). Darum die
            // Bytes streamen und nach 64 KB abbrechen; die Verbindung wird dann beim
            // Verwerfen der Sequenz geschlossen.
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var data = Data(); data.reserveCapacity(65536)
            for try await b in bytes {
                data.append(b)
                if data.count >= 65536 { break }
            }
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
                // PLS-Schluessel sind exakt "FileN" (N = Ziffernfolge). Nur die als
                // Stream-URL deuten — sonst gaelte z. B. ein boesartiges
                // "Filename=http://angreifer/…" vor dem echten "File1=" als Ziel.
                let key = l[l.index(l.startIndex, offsetBy: 4)..<eq]
                guard !key.isEmpty, key.allSatisfy(\.isNumber) else { continue }
                let value = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if let url = StreamURLPolicy.validatedURL(value) { return url }
            }
        }
        // M3U / Klartext: erste Zeile, die wie eine http-URL aussieht
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("[") { continue }
            if let url = StreamURLPolicy.validatedURL(l) { return url }
        }
        // ASX/XSPF: <location>URL</location> oder href="URL"
        if let m = firstMatch(text, pattern: "(?:<location>|href=\")\\s*(https?://[^<\"\\s]+)") {
            return StreamURLPolicy.validatedURL(m)
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

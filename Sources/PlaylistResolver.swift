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

    // Heuristik: nur fetchen, wenn die URL nach Playlist aussieht. Entscheidend
    // ist ausschliesslich der URL-PFAD: Host und Query sind bei fremden
    // Katalog-/Playlist-URLs freie Texte. Frueher wurde die gesamte URL
    // durchsucht — ein Koeder wie "list.pls?hint=.m3u8" galt dadurch als HLS
    // und VLC bekam den rohen Playlist-Container samt darin verlinkter,
    // ungefilterter Ziele; umgekehrt stufte ".pls" im Hostnamen Direktstreams
    // faelschlich als Playlist ein.
    static func needsResolution(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        // .m3u8 ist HLS und geht direkt an VLC (NICHT fetchen) — aber nur als
        // echte Pfad-Endung.
        if path.hasSuffix(".m3u8") { return false }
        // Nur echte Playlist-Endungen als Pfad-Suffix. Achtung: manche
        // Direkt-Streams haben "pls" im Namen (z. B. .../tunein-aac-hd-pls
        // liefert rohes AAC) — daher NICHT auf den blossen Teilstring "pls"
        // matchen.
        if path.hasSuffix(".pls") || path.hasSuffix(".m3u")
            || path.hasSuffix(".asx") || path.hasSuffix(".xspf") { return true }
        // Bekannte Playlist-Endpunkte ohne Endung (radiotime bzw. /pls-Pfade).
        return path.contains("tune.ashx") || path.contains("/pls")
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
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("<") {
            // XML-Entities gehören zur Syntax, nicht zu den Query-Parametern.
            // DTDs sind für Playlists unnötig; keine fremden Entity-Inhalte laden.
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { return nil }
            let parser = XMLParser(data: Data(text.utf8))
            let delegate = PlaylistXMLReader()
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            return parser.parse() ? delegate.url : nil
        }
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
        return nil
    }
}

private final class PlaylistXMLReader: NSObject, XMLParserDelegate {
    private(set) var url: URL?
    private var location: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.lowercased() == "location" { location = "" }
        if elementName.lowercased() == "ref", url == nil,
           let href = attributeDict.first(where: { $0.key.lowercased() == "href" })?.value {
            url = StreamURLPolicy.validatedURL(href)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        location?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { location?.append(text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName.lowercased() == "location" {
            if url == nil, let location { url = StreamURLPolicy.validatedURL(location) }
            location = nil
        }
    }
}

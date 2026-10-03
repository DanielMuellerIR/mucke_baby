import Foundation

// Loest Playlist-URLs (.pls/.m3u/.asx/.xspf, radiotime Tune.ashx) zur
// eigentlichen Stream-URL auf. Ziele vor Übergabe an VLC prüfen, damit
// Playlist-Container keine ungeprüften lokalen Ressourcen öffnen.
enum PlaylistResolver {

    // Liefert ausschliesslich eine von StreamURLPolicy erlaubte Web-URL. Ein
    // erkannter Playlist-Container wird fail-closed behandelt: Kann sein Ziel
    // nicht sicher aufgeloest werden, bekommt VLC nicht den rohen Container und
    // kann dadurch auch kein file:/ oder anderes lokales Ziel selbst verfolgen.
    static func resolve(_ raw: String, depth: Int = 0, session: URLSession = .shared) async -> URL? {
        guard let url = StreamURLPolicy.validatedURL(raw) else { return nil }
        if depth > 3 { return nil }                 // Schutz gegen Endlos-Verschachtelung
        guard needsResolution(url) else { return url }
        guard let data = await fetchHead(url, session: session) else { return nil }
        guard let inner = firstMediaURL(in: data) else { return nil }
        if inner.absoluteString == url.absoluteString { return nil }
        // Playlist kann auf weitere Playlist zeigen -> rekursiv aufloesen.
        return await resolve(inner.absoluteString, depth: depth + 1, session: session)
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
    static func fetchHead(_ url: URL, session: URLSession = .shared) async -> Data? {
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
            let (bytes, _) = try await session.bytes(for: req)
            defer { bytes.task.cancel() }
            var data = Data(); data.reserveCapacity(65536)
            for try await b in bytes {
                data.append(b)
                if data.count >= 65536 { break }
            }
            return data
        } catch {
            return nil
        }
    }

    // Findet die erste Media-URL in PLS/M3U/ASX/XSPF-Inhalten.
    static func firstMediaURL(in text: String) -> URL? {
        // Der String wurde bereits dekodiert. Eine alte XML-Encoding-Angabe
        // darf die erneut erzeugten UTF-8-Bytes nicht ein zweites Mal dekodieren.
        var text = text
        if let declaration = text.range(of: "<?xml"),
           let end = text.range(of: "?>", range: declaration.lowerBound..<text.endIndex) {
            text.removeSubrange(declaration.lowerBound..<end.upperBound)
        }
        return firstMediaURL(in: Data(text.utf8))
    }

    static func firstMediaURL(in data: Data) -> URL? {
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("<") {
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { return nil }
            let parser = XMLParser(data: data)
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
    private var path: [String] = []
    private var namespaces: [String] = []
    private let xspfNamespace = "http://xspf.org/ns/0/"

    private var isTrackLocation: Bool {
        path == ["playlist", "tracklist", "track", "location"]
            && namespaces.allSatisfy { $0 == xspfNamespace || $0.isEmpty }
            && Set(namespaces).count == 1
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(elementName.lowercased())
        namespaces.append(namespaceURI ?? "")
        if isTrackLocation { location = "" }
        if path == ["asx", "entry", "ref"], namespaces.allSatisfy(\.isEmpty), url == nil,
           let href = attributeDict.first(where: { $0.key.lowercased() == "href" })?.value {
            url = StreamURLPolicy.validatedURL(href)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isTrackLocation { location?.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if isTrackLocation, let text = String(data: CDATABlock, encoding: .utf8) { location?.append(text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if isTrackLocation {
            if url == nil, let location { url = StreamURLPolicy.validatedURL(location) }
            location = nil
        }
        path.removeLast()
        namespaces.removeLast()
    }
}

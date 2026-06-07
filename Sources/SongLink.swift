import Foundation

// Findet zu einem gehoerten Titel den besten Link in Apple Music / Spotify.
// Strategie: ueber die iTunes-Such-API Kandidaten testen (zuerst OHNE Mix-/
// Versions-Zusaetze wie "Extended Mix", weil die exakte Version oft fehlt),
// und nur Treffer akzeptieren, deren Titel wirklich passt (Wortabgleich) —
// sonst landet man beim falschen Song desselben Interpreten.
enum SongLink {

    // Mix-/Versions-Zusaetze aus dem Titel entfernen.
    static func cleanedTitle(_ title: String) -> String {
        var t = title
        let bracket = #"\s*[\(\[][^\(\)\[\]]*\b(extended|original|radio|club|edit|remix|mix|version|bootleg|vip|instrumental|acoustic|live|remaster[a-z]*)\b[^\(\)\[\]]*[\)\]]"#
        t = t.replacingOccurrences(of: bracket, with: "", options: [.regularExpression, .caseInsensitive])
        let dash = #"\s[-–—]\s.*\b(mix|remix|edit|version)\b.*$"#
        t = t.replacingOccurrences(of: dash, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    // Suchbegriffe in Reihenfolge: bereinigt -> exakt -> nur Titel.
    static func candidateTerms(artist: String?, title: String?, raw: String) -> [String] {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = (title ?? raw).trimmingCharacters(in: .whitespaces)
        let ct = cleanedTitle(t)
        var out: [String] = []
        func add(_ s: String) {
            let q = s.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, !out.contains(q) { out.append(q) }
        }
        add("\(a) \(ct)")          // bereinigt zuerst
        if ct != t { add("\(a) \(t)") }
        add(ct.isEmpty ? t : ct)
        return out
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    // Interpret fuer Lyrics-Abfragen bereinigen: ab "feat./ft./with/x/vs/&/,/ /"
    // abschneiden -> primaerer Interpret (lyrics.ovh matcht exakt, Zusaetze killen Treffer).
    static func cleanedArtist(_ artist: String) -> String {
        let cut = #"\s*(\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b|\bvs\.?\b|\bx\b|&|,|/).*$"#
        return artist
            .replacingOccurrences(of: cut, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    // (Interpret, Titel)-Paare fuer eine Lyrics-Abfrage, bestes zuerst: voll/primaer
    // x bereinigt/roh. lyrics.ovh wird der Reihe nach probiert, erstes Ergebnis zaehlt.
    static func lyricsQueries(artist: String, title: String) -> [(artist: String, title: String)] {
        let aFull = artist.trimmingCharacters(in: .whitespaces)
        let aPrim = cleanedArtist(artist)
        let tClean = cleanedTitle(title)
        let tRaw = title.trimmingCharacters(in: .whitespaces)
        var out: [(String, String)] = []
        func add(_ a: String, _ t: String) {
            let a2 = a.trimmingCharacters(in: .whitespaces)
            let t2 = t.trimmingCharacters(in: .whitespaces)
            guard !a2.isEmpty, !t2.isEmpty,
                  !out.contains(where: { $0.0 == a2 && $0.1 == t2 }) else { return }
            out.append((a2, t2))
        }
        add(aFull, tClean); add(aPrim, tClean); add(aFull, tRaw); add(aPrim, tRaw)
        return out
    }

    // Pruefen, ob ein API-Treffer-Titel zum gewuenschten Titel passt (gemeinsame
    // bedeutungstragende Woerter), damit kein fremder Song akzeptiert wird.
    private static let stop: Set<String> = ["the","and","feat","with","mix","extended",
        "original","remix","edit","version","from","mind","your","what","when","this","that"]
    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) })
    }
    static func titleMatches(result: String, wanted: String) -> Bool {
        let w = words(wanted)
        if w.isEmpty { return true }
        return !w.isDisjoint(with: words(result))
    }

    // iTunes-Such-API (oeffentlich, ohne Auth).
    private struct ITunesResult: Decodable {
        let results: [Track]
        struct Track: Decodable { let trackName: String?; let trackViewUrl: String? }
    }
    private static func lookup(_ term: String) async -> (name: String, url: URL)? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
            .init(name: "country", value: "DE"),
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(ITunesResult.self, from: data),
              let track = r.results.first,
              let s = track.trackViewUrl, let u = URL(string: s) else { return nil }
        return (track.trackName ?? "", u)
    }

    // Beste Apple-Music-URL: erster passender Track, sonst Suche (bereinigt).
    static func appleMusic(artist: String?, title: String?, raw: String) async -> URL {
        let wanted = cleanedTitle((title ?? raw))
        for term in candidateTerms(artist: artist, title: title, raw: raw) {
            if let hit = await lookup(term), titleMatches(result: hit.name, wanted: wanted) {
                return hit.url
            }
        }
        // Kein sicherer Treffer -> Suche mit bereinigtem Begriff.
        let term = enc(candidateTerms(artist: artist, title: title, raw: raw).first ?? raw)
        return URL(string: "https://music.apple.com/search?term=\(term)")
            ?? URL(string: "https://music.apple.com/search")!
    }

    // Spotify-Suchbegriff (bereinigt) — Spotify-API braucht Auth, daher nur Suche.
    static func spotifyQuery(artist: String?, title: String?, raw: String) -> String {
        candidateTerms(artist: artist, title: title, raw: raw).first ?? raw
    }
}

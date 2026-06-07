import SwiftUI

// Zeigt den Songtext zu Interpret/Titel. Quelle: lyrics.ovh (frei, kein Key) —
// Apple bietet keine oeffentliche Lyrics-API. Mainstream wird gefunden,
// Nischen (Hardstyle) oft nicht -> dann freundlicher Hinweis.
struct LyricsView: View {
    let artist: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var text = ""
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if !artist.isEmpty { Text(artist).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Divider()
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !error.isEmpty {
                    // Nichts gefunden (lyrics.ovh deckt Nischen wie Hardstyle kaum ab)
                    // -> Web-Suche als Ausweg anbieten.
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(.secondary)
                        Button { openWebSearch() } label: {
                            Label("Im Web suchen", systemImage: "magnifyingglass")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 560)
        .task { await load() }
    }

    private func enc(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func load() async {
        loading = true; error = ""
        struct R: Decodable { let lyrics: String? }
        // Mehrere (Interpret, Titel)-Varianten der Reihe nach probieren — bereinigter
        // Interpret (ohne feat./&) und bereinigter Titel erhoehen die Trefferquote.
        let queries = SongLink.lyricsQueries(artist: artist, title: title)
        guard !queries.isEmpty else {
            loading = false; error = "Kein Songtext gefunden (Interpret/Titel unklar)."; return
        }
        for q in queries {
            guard let url = URL(string: "https://api.lyrics.ovh/v1/\(enc(q.artist))/\(enc(q.title))")
            else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let lyr = ((try? JSONDecoder().decode(R.self, from: data))?.lyrics ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !lyr.isEmpty { text = lyr; loading = false; return }
        }
        error = "Kein Songtext gefunden."
        loading = false
    }

    // Fallback: Songtext im Browser suchen (Genres wie Hardstyle fehlen bei lyrics.ovh).
    private func openWebSearch() {
        let term = SongLink.enc("\(artist) \(title) lyrics".trimmingCharacters(in: .whitespaces))
        if let url = URL(string: "https://www.google.com/search?q=\(term)") { openURL(url) }
    }
}

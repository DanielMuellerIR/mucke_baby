import AppKit

@MainActor
enum SongActions {
    // Einen gespeicherten Kataloglink bevorzugen; sonst den Titel mit der bestehenden Suche finden.
    static func openInMusic(_ song: SongEntry) {
        if let url = SongRecognition.safeAppleMusicURL(song.recognition?.appleMusicURL) {
            openURL(url, inApp: "com.apple.Music"); return
        }
        Task {
            let url = await SongLink.appleMusic(artist: song.artist, title: song.title, raw: song.raw)
            openURL(url, inApp: "com.apple.Music")
        }
    }

    // Spotify: per App-URI suchen (bereinigter Begriff); ohne Spotify-App im Web.
    static func openInSpotify(_ song: SongEntry) {
        let term = SongLink.enc(SongLink.spotifyQuery(artist: song.artist, title: song.title, raw: song.raw))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client"),
           let uri = URL(string: "spotify:search:\(term)") {
            NSWorkspace.shared.open([uri], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://open.spotify.com/search/\(term)") {
            NSWorkspace.shared.open(web)
        }
    }

    // URL bevorzugt in der angegebenen App öffnen, sonst im Standardbrowser.
    private static func openURL(_ url: URL, inApp bundleID: String) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }
}

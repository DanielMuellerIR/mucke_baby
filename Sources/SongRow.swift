import SwiftUI

// Eine Verlaufszeile: Zeitspanne, Titel, Sender.
struct SongRow: View {
    let entry: SongEntry
    var showsInterval = true
    var audioLabel: String? = nil

    // Theme + Schriftfaktor wie im Panel. SongRow liest beide selbst aus dem
    // Environment (kein Durchreichen noetig).
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let dayFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter
    }()
    private var isLive: Bool { showsInterval && entry.end == nil }

    // Zeitstempel: midi-Terminal hebt sie in Neon-Akzent (accent2/Cyan) hervor.
    private var timeColor: Color { theme.id == .midi ? theme.palette.accent2 : theme.palette.songListSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Platzhalter (Mitschnitt-Session) bekommt ein Aufnahme-Symbol,
                // ein laufender echter Titel das Funkwellen-Symbol. Farben aus
                // dem Theme: Aufnahme = alert (rot), Live = liveBadge.
                if entry.isPlaceholder {
                    Image(systemName: "record.circle")
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.alert)
                } else if isLive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .themedFont(theme, .label, size: 10 * uiFontScale)
                        .foregroundColor(theme.palette.liveBadge)
                }
                Text(timeRange)
                    .themedFont(theme, .body, size: 11 * uiFontScale)
                    .foregroundColor(timeColor)
            }
            Text(songText)
                .themedFont(theme, .body, size: 12 * uiFontScale, weight: isLive ? .semibold : .regular)
                .foregroundColor(entry.isPlaceholder ? theme.palette.songListSecondary : theme.palette.songListText)
                .lineLimit(2)
            Text(entry.station)
                .themedFont(theme, .body, size: 10 * uiFontScale)
                .foregroundColor(theme.palette.songListSecondary)
            if let audioLabel {
                Text(audioLabel)
                    .themedFont(theme, .label, size: 10 * uiFontScale)
                    .foregroundStyle(theme.palette.songListSecondary)
                    .accessibilityIdentifier("history-audio-" + entry.id.uuidString)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var songText: String {
        if entry.isPlaceholder { return isLive ? "Mitschnitt (läuft …)" : "Mitschnitt" }
        if let a = entry.artist, let t = entry.title { return "\(a) – \(t)" }
        return entry.title ?? entry.raw
    }
    private var timeRange: String {
        let s = Self.dayFmt.string(from: entry.start) + " · " + Self.timeFmt.string(from: entry.start)
        if !showsInterval { return s }
        if let e = entry.end { return "\(s) – \(Self.timeFmt.string(from: e))" }
        return "\(s) – …"
    }
}

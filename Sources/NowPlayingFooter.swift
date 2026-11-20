import SwiftUI

struct NowPlayingFooter: View {
    @EnvironmentObject private var player: RadioPlayer
    @EnvironmentObject private var recognition: MusicRecognitionService
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var uiFontScale

    @Binding var volume: Double
    let onOpenRecognition: () -> Void
    let onOpenBookmarks: () -> Void

    // Startwert der Lautstaerke beim Beginn eines Knopf-Drags (knob-Themes). nil = kein Drag aktiv.
    @State private var knobDragStart: Double? = nil

    /// Fuß: kopierbarer Titel mit horizontalem Scrollen oder vollständig umbrechender
    /// Status — plus Merkliste, Laufzeit und Lautstärke.
    var body: some View {
        HStack(spacing: 12) {
            if player.nowPlayingTitle.isEmpty && recognition.currentAdoption == nil {
                nowPlayingFooterText
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    nowPlayingFooterText
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            MusicRecognitionButton(identifier: "recognition-open") { onOpenRecognition() }
            if let song = currentDisplaySong { BookmarkButton(song: song) }
            Button { onOpenBookmarks() } label: {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 16)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.palette.textSecondary)
            .help("Merkliste öffnen").accessibilityLabel("Merkliste öffnen")
            .accessibilityIdentifier("bookmarks-open")

            RecordingControl()
            SleepTimerButton()

            if let started = player.playStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(PlaybackClock.runtime(since: started, now: ctx.date))
                        .font(theme.font(.label, size: 12 * uiFontScale))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.textDim)
                }
                .fixedSize()
                .help("Laufzeit")
            }

            // Lautstaerke-Regler — neben der Laufzeit (außerhalb der Titelregion bedienbar).
            volumeControl
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background { ThemedSurface(.panel) }
    }

    private var nowPlayingFooterText: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                if recognition.currentAdoption != nil {
                    Text("Shazam").accessibilityIdentifier("current-recognition-source")
                }
                Text(player.currentStation?.name ?? String(localized: "Kein Sender"))
            }
            .font(theme.font(.label, size: 11 * uiFontScale))
            .foregroundStyle(theme.palette.textSecondary).lineLimit(1)
            nowPlayingFooterTitle
            if recognition.currentAdoption != nil {
                Text("Sendertext: \(player.nowPlayingTitle.isEmpty ? String(localized: "Kein Sendertext") : player.nowPlayingTitle)")
                    .font(theme.font(.label, size: 11 * uiFontScale)).foregroundStyle(theme.palette.textSecondary)
                    .accessibilityIdentifier("current-original-radio-title")
            }
        }
        .textSelection(.enabled)
    }

    /// Aktueller Titel (Interpret fett + Titel) oder Status als ein kopierbarer Text.
    @ViewBuilder
    private var nowPlayingFooterTitle: some View {
        if !player.nowPlayingTitle.isEmpty || recognition.currentAdoption != nil {
            let metadata: (artist: String?, title: String?) = recognition.currentAdoption.map {
                ($0.track.artist.isEmpty ? nil : $0.track.artist, $0.track.title)
            } ?? SongEntry.split(player.nowPlayingTitle)
            let (artist, title) = metadata
            if let a = artist, let t = title {
                (Text(a).font(theme.font(.body, size: 16 * uiFontScale, weight: .bold))
                 + Text("   ").font(theme.font(.body, size: 15 * uiFontScale))
                 + Text(t).font(theme.font(.body, size: 15 * uiFontScale)))
                    .foregroundStyle(theme.palette.textPrimary)
            } else {
                Text(title ?? player.nowPlayingTitle)
                    .font(theme.font(.body, size: 16 * uiFontScale, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        } else {
            Text(player.isLoading ? player.statusText
                 : (player.isPlaying ? (player.metadataStatus ?? "♪") : player.statusText))
                .font(theme.font(.body, size: 15 * uiFontScale))
                .foregroundStyle(theme.palette.textPrimary)
        }
    }

    private var currentDisplaySong: SongEntry? {
        if let result = recognition.currentAdoption, let station = player.currentStation {
            return result.song(station: station.name)
        }
        return player.currentSong
    }

    /// Lautstaerke-Regler im Fuß (neben der Laufzeit). knob-Themes (retro/stack): drehbarer
    /// Goldknopf (ziehen = drehen), sonst Slider mit Speaker-Icons.
    ///
    /// Warum jetzt im Fuß: In der Kopfleiste lag der Regler über der (wegen `.fullSizeContentView`)
    /// transparenten macOS-Titelregion. Dort fängt der native Fenster-Drag den Mouse-Down ab,
    /// BEVOR eine SwiftUI-Geste (oder eine NSView mit `mouseDownCanMoveWindow=false`) ihn sieht —
    /// der Knopf zog also das Fenster statt zu drehen. Der Fuß liegt außerhalb der Titelregion,
    /// dort genügt eine schlichte SwiftUI-DragGesture.
    @ViewBuilder
    private var volumeControl: some View {
        if theme.control == .knob {
            KnobView(value: volume, label: "VOL", tint: theme.palette.accent, diameter: 30)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let start = knobDragStart ?? volume
                            if knobDragStart == nil { knobDragStart = volume }
                            // hoch ODER rechts ziehen = lauter (Drehgefühl)
                            let delta = Double((-g.translation.height + g.translation.width) / 120)
                            volume = min(1, max(0, start + delta))
                        }
                        .onEnded { _ in knobDragStart = nil }
                )
                .help("Lautstärke: \(Int(volume * 100)) % — ziehen zum Drehen")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10)).foregroundStyle(theme.palette.textDim)
                Slider(value: $volume, in: 0...1)
                    // Darf bei Platzmangel schmaler werden, aber nicht unter ~60 pt (noch bedienbar).
                    .frame(minWidth: 60, idealWidth: 96, maxWidth: 96)
                    .tint(theme.palette.accent)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10)).foregroundStyle(theme.palette.textDim)
            }
            .help("Lautstärke: \(Int(volume * 100)) %")
        }
    }
}

// Laufzeit als mm:ss, ab einer Stunde als h:mm:ss.
private enum PlaybackClock {
    static func runtime(since start: Date, now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%02d:%02d", minutes, seconds)
    }
}

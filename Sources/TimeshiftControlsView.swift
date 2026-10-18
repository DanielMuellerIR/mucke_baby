import SwiftUI

// Hauptfenster und Miniplayer bedienen dieselbe Hörposition.
struct TimeshiftControlsView: View {
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    var compact = false
    @State private var scrubbing: Double?
    @State private var editing = false
    private var transport: TimeshiftTransport { player.timeshiftTransport }
    private var timeline: MetadataTimeline { transport.timeline }
    private var available: Bool { timeline.canStart && player.hasPlaybackIntent }

    var body: some View {
        if player.timeshiftRequested {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { player.togglePause() } label: {
                        Label(player.isPaused ? String(localized: "Fortsetzen") : String(localized: "Pause"),
                              systemImage: player.isPaused ? "play.fill" : "pause.fill")
                    }
                    .disabled(!player.isPaused && !player.canPause).accessibilityIdentifier("timeshift-pause")
                    .opacity(player.isPaused || player.canPause ? 1 : 0.4)
                    Button { player.skipTimeshift(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .help("15 Sekunden zurück").accessibilityLabel("15 Sekunden zurück")
                        .disabled(!available).accessibilityIdentifier("timeshift-back")
                        .opacity(available ? 1 : 0.4)
                    Button { player.skipTimeshift(by: 15) } label: { Image(systemName: "goforward.15") }
                        .help("15 Sekunden vor").accessibilityLabel("15 Sekunden vor")
                        .disabled(!available).accessibilityIdentifier("timeshift-forward")
                        .opacity(available ? 1 : 0.4)
                    Spacer(minLength: 0)
                    Button("Live") { player.returnToLive() }
                        .disabled(!player.hasPlaybackIntent).accessibilityIdentifier("timeshift-live")
                    Text("−\(Self.time(transport.delay))")
                        .monospacedDigit().accessibilityLabel("Verzögerung")
                        .accessibilityIdentifier("timeshift-delay")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                Slider(value: Binding(get: {
                    scrubbing ?? min(timeline.latestStart, max(timeline.oldest, transport.position))
                }, set: { if editing { scrubbing = $0 } else { player.seekTimeshift(to: $0) } }), in: timeline.oldest...max(timeline.oldest + 0.001, timeline.latestStart), onEditingChanged: { active in
                    editing = active
                    if !active, let position = scrubbing {
                        player.seekTimeshift(to: position); scrubbing = nil
                    }
                }) { Text("Hörposition im Puffer") }
                    .labelsHidden().disabled(!available)
                    .accessibilityLabel("Hörposition im Puffer")
                    .accessibilityValue("\(Self.time(transport.position - timeline.oldest)) / \(Self.time(timeline.live - timeline.oldest))")
                    .accessibilityIdentifier("timeshift-position")
                HStack {
                    Text("Puffer: −\(Self.time(timeline.live - timeline.oldest))")
                    Spacer()
                    Text("Live: mindestens 3 s Reserve")
                }.monospacedDigit().foregroundStyle(theme.palette.textSecondary)
                Canvas { context, size in
                    let duration = max(0.001, timeline.live - timeline.oldest)
                    for anchor in timeline.titles {
                        let x = size.width * (anchor.position - timeline.oldest) / duration
                        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(theme.palette.textSecondary), lineWidth: 1)
                    }
                }.frame(height: 5).accessibilityHidden(true)
                if available {
                    Menu {
                        ForEach(timeline.titles) { anchor in
                            Button("−\(Self.time(timeline.live - anchor.position)) · \(anchor.title.isEmpty ? String(localized: "Kein Sendertext") : anchor.title)") {
                                player.seekTimeshift(to: anchor.position)
                            }.disabled(anchor.position > timeline.latestStart)
                        }
                    } label: {
                        Label("Titelzeitleiste", systemImage: "list.bullet")
                    }.menuStyle(.borderlessButton).accessibilityIdentifier("timeshift-titles")
                } else {
                    Text(player.timeshiftStatus).foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if transport.phase == .expired && !compact {
                    Text("Pufferposition nicht mehr verfügbar. Mit Live fortsetzen.")
                        .foregroundStyle(theme.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timeshift-expired")
                }
            }
            .font(theme.font(.label, size: (compact ? 10 : 11) * scale))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(compact ? 10 : 12)
            .background(theme.palette.panelBackground)
            .accessibilityElement(children: .contain)
        }
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

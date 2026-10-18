import SwiftUI

struct SleepTimerButton: View {
    @EnvironmentObject private var player: RadioPlayer
    var identifier = "sleep-timer"
    var body: some View {
        SleepTimerControl(timer: player.sleepTimer, canStart: player.isPlaying || player.isLoading, identifier: identifier)
    }
}

private struct SleepTimerControl: View {
    @ObservedObject var timer: SleepTimerController
    let canStart: Bool
    let identifier: String
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: timer.remaining == nil ? "moon.zzz" : "moon.zzz.fill")
                if let remaining = timer.remaining {
                    Text(timerTime(remaining)).monospacedDigit()
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier(identifier + "-remaining")
                }
            }
            .font(theme.font(.label, size: 12 * scale))
            .foregroundStyle(timer.remaining == nil ? theme.palette.textSecondary : theme.palette.accent)
            .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Einschlaftimer")
        .accessibilityLabel("Einschlaftimer")
        .accessibilityValue(timer.remaining.map(timerTime) ?? String(localized: "Aus"))
        .accessibilityIdentifier(identifier + "-open")
        .popover(isPresented: $showing, arrowEdge: .top) {
            SleepTimerPanel(timer: timer, canStart: canStart) { showing = false }
                .environment(\.theme, theme).environment(\.uiFontScale, scale)
        }
    }
}

private struct SleepTimerPanel: View {
    @ObservedObject var timer: SleepTimerController
    let canStart: Bool
    let close: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @State private var minutes = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Einschlaftimer").font(theme.font(.title, size: 18 * scale, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Schließen").accessibilityLabel("Schließen").accessibilityIdentifier("sleep-timer-close")
            }
            Text("Blendet die Wiedergabe am Ende sanft aus und stoppt sie. Deine persönliche Lautstärke bleibt erhalten.")
                .font(theme.font(.body, size: 12 * scale)).foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let remaining = timer.remaining {
                Text("Restzeit: \(timerTime(remaining))")
                    .font(theme.font(.body, size: 16 * scale, weight: .semibold)).monospacedDigit()
                    .accessibilityIdentifier("sleep-timer-panel-remaining")
                Button("Um 15 Minuten verlängern") { timer.extend(minutes: 15) }
                    .accessibilityIdentifier("sleep-timer-extend")
                Button("Timer abbrechen") { timer.cancel() }
                    .accessibilityIdentifier("sleep-timer-cancel")
                Divider()
            }
            Picker("Dauer", selection: $minutes) {
                ForEach([15, 30, 45, 60, 90], id: \.self) { value in
                    Text("\(value) Minuten").tag(value)
                }
                Text("Eigene Dauer").tag(0)
            }
            .accessibilityIdentifier("sleep-timer-duration")
            if minutes == 0 { customDuration }
            Button {
                if let selectedMinutes, timer.start(duration: Double(selectedMinutes) * 60) { close() }
            } label: {
                Text(timer.remaining == nil ? LocalizedStringKey("Timer starten") : LocalizedStringKey("Timer neu setzen"))
            }
            .disabled(!canStart || selectedMinutes == nil).accessibilityIdentifier("sleep-timer-start")
            if !canStart {
                Text("Starte zuerst einen Sender.").font(theme.font(.body, size: 12 * scale))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .foregroundStyle(theme.palette.textPrimary)
        .padding(16).frame(width: 340 * min(scale, 1.3))
        .background { ThemedSurface(.panel) }
    }

    @State private var customMinutes = "30"
    private var selectedMinutes: Int? {
        if minutes != 0 { return minutes }
        guard let value = Int(customMinutes.trimmingCharacters(in: .whitespaces)), (1...1440).contains(value) else { return nil }
        return value
    }
    private var customDuration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Minuten", text: $customMinutes).textFieldStyle(.roundedBorder)
                    .frame(width: 100).accessibilityIdentifier("sleep-timer-custom")
                Text("Minuten")
            }
            Text("1 bis 1440 Minuten").font(theme.font(.body, size: 12 * scale))
                .foregroundStyle(selectedMinutes == nil ? Color.red : theme.palette.textSecondary)
        }
    }
}

private func timerTime(_ remaining: TimeInterval) -> String {
    let seconds = max(0, Int(ceil(remaining)))
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

import SwiftUI
import AppKit

struct AudioSettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "audio-settings") } label: {
            Image(systemName: "slider.vertical.3").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Audioeinstellungen").accessibilityLabel("Audioeinstellungen")
        .accessibilityIdentifier("audio-settings-open")
    }
}

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: AudioSettingsStore
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: RadioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.uiFontScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("volume") private var volume = 0.77
    @State private var message: String?
    private let frequencies = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private var config: AudioConfiguration { settings.configuration }
    private var station: Station? { store.stations.first { $0.id == player.currentStation?.id } }
    private var ink: Color { theme.id == .retro ? Color(hex: "#2A2018") : theme.palette.textPrimary }
    private var dim: Color { theme.id == .retro ? Color(hex: "#5C4A38") : theme.palette.textSecondary }
    private var presetTitle: String {
        EqualizerPreset.allCases.first { $0.bands == config.bands }?.title ?? String(localized: "Eigene Einstellung")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Audioeinstellungen", systemImage: "slider.vertical.3")
                    .font(theme.font(.title, size: 18 * scale, weight: .semibold))
                Spacer()
                Button("Schließen") { dismissWindow(id: "audio-settings") }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("audio-settings-close")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    stationCorrection
                    equalizer
                    if let notice = message ?? settings.notice ?? player.audioNotice {
                        Text(notice).font(theme.font(.body, size: 12 * scale)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audio-settings-error")
                    }
                    Text("Korrektur und Equalizer verändern nur die Wiedergabe. Aufnahme und Export bleiben unbearbeitet. Kein automatischer Lautheitsabgleich.")
                        .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.trailing, 3)
            }
        }
        .padding(20).foregroundStyle(ink)
        .frame(minWidth: 580, idealWidth: 620, minHeight: 500, idealHeight: 650)
        .background { SongListSurface() }
        .environment(\.colorScheme, theme.id == .retro ? .light : colorScheme)
    }

    private var stationCorrection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Senderkorrektur").font(theme.font(.body, size: 14 * scale, weight: .semibold))
            if let station {
                Text(station.name).font(theme.font(.body, size: 12 * scale)).lineLimit(2).help(station.name)
                HStack {
                    Slider(value: Binding(get: { config.gain(for: station.id) },
                                          set: { value in change { try settings.setStationGain(value, for: station.id) } }),
                           in: -12...12, step: 0.5) { Text("Senderkorrektur") }
                        .labelsHidden()
                        .accessibilityIdentifier("audio-station-gain")
                    Text(db(config.gain(for: station.id))).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Button("Neutral") { change { try settings.setStationGain(0, for: station.id) } }
                        .accessibilityIdentifier("audio-station-reset")
                }.font(theme.font(.label, size: 12 * scale)).disabled(settings.isReadOnly)
                Text("Diese Korrektur gehört zur lokalen Senderidentität und bleibt beim Senderwechsel gespeichert.")
                    .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                    .fixedSize(horizontal: false, vertical: true)
                if config.isVolumeLimited(Float(volume), stationID: station.id) {
                    Text("Die verstärkte Lautstärke ist auf 100 % begrenzt. Für mehr Spielraum die globale Lautstärke senken.")
                        .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audio-volume-limited")
                }
            } else {
                Text("Starte einen Sender, um seine Korrektur einzustellen.")
                    .font(theme.font(.body, size: 12 * scale)).foregroundStyle(dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Equalizer", isOn: Binding(get: { config.equalizerEnabled },
                                                set: { value in change { try settings.update { $0.equalizerEnabled = value } } }))
                    .font(theme.font(.body, size: 14 * scale, weight: .semibold))
                    .accessibilityIdentifier("audio-equalizer-enabled")
                Spacer()
                Menu(presetTitle) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Button(preset.title) { change { try settings.update { $0.bands = preset.bands; $0.preampDB = 0 } } }
                    }
                }.fixedSize().disabled(!config.equalizerEnabled).accessibilityLabel("Equalizer-Vorgabe")
                    .accessibilityIdentifier("audio-equalizer-preset")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<10) { index in
                        VStack(spacing: 8) {
                            Text(frequency(frequencies[index])).font(theme.font(.label, size: 10 * scale)).monospacedDigit()
                            VerticalAudioBandSlider(value: Binding(get: { config.bands[index] },
                                                                   set: { value in change { try settings.update { $0.bands[index] = value } } }),
                                                    label: frequency(frequencies[index]), identifier: "audio-band-\(index)")
                                .frame(width: 28, height: 110)
                            Text(db(config.bands[index])).font(theme.font(.label, size: 10 * scale)).monospacedDigit()
                        }.frame(width: 44 * scale)
                    }
                }.padding(.vertical, 4)
            }.disabled(!config.equalizerEnabled)
            HStack {
                Text("Vorverstärkung")
                Slider(value: Binding(get: { config.preampDB },
                                      set: { value in change { try settings.update { $0.preampDB = value } } }),
                       in: -12...0, step: 0.5) { Text("Vorverstärkung") }
                    .labelsHidden()
                    .accessibilityIdentifier("audio-preamp")
                Text(db(config.preampDB)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }.font(theme.font(.label, size: 12 * scale)).disabled(!config.equalizerEnabled)
            Text(config.equalizerEnabled
                 ? String(localized: "Effektive Vorverstärkung: \(db(config.effectivePreampDB))")
                 : String(localized: "Equalizer ausgeschaltet; neutraler Audiopfad."))
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                .accessibilityIdentifier("audio-effective-preamp")
            Text("Headroom senkt die Vorverstärkung um mindestens die stärkste Bandanhebung. Das schafft Pegelreserve; es ersetzt keinen Limiter.")
                .font(theme.font(.label, size: 11 * scale)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true)
        }.disabled(settings.isReadOnly).padding(14)
            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func change(_ action: () throws -> Void) {
        do { try action(); message = nil }
        catch { message = settings.notice ?? error.localizedDescription }
    }
    private func db(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " dB" }
    private func frequency(_ value: Double) -> String {
        value >= 1000 ? (value / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz"
            : value.formatted(.number.precision(.fractionLength(0...1))) + " Hz"
    }
}

private struct VerticalAudioBandSlider: NSViewRepresentable {
    @Binding var value: Double
    @Environment(\.isEnabled) private var enabled
    let label: String
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 28, height: 110))
        slider.minValue = -12; slider.maxValue = 12; slider.isVertical = true
        slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = false
        slider.altIncrementValue = 0.5
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label); slider.setAccessibilityIdentifier(identifier)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = value; slider.isEnabled = enabled
    }
    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = (sender.doubleValue * 2).rounded() / 2 }
    }
}

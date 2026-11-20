import Foundation
import Combine
import VLCKit

/// Kleiner, eigenständiger VLC-Player NUR fürs Probehören im Katalog.
/// Bewusst getrennt vom Haupt-RadioPlayer: kein Verlauf, keine Aufnahme,
/// kein ICY-Reader — beim Schließen des Sheets ist alles wieder weg.
@MainActor
final class PreviewPlayer: ObservableObject {
    /// stationuuid des gerade spielenden/ladenden Senders (nil = still).
    /// Abgeleitet aus dem PreviewSwitchCoordinator als einzige Wahrheitsquelle.
    var currentID: String? { switches.currentID }
    @Published private(set) var isLoading = false
    @Published private(set) var failedID: String?   // letzter Sender, der nicht spielte

    private var player = VLCMediaPlayer()
    private var shim: PlayerDelegateShim?
    private var resolveTask: Task<Void, Never>?
    private var switches = PreviewSwitchCoordinator()
    private let deliverEvent: PlayerEventDelivery

    init(deliverEvent: @escaping PlayerEventDelivery = deliverPlayerEventOnMain) {
        self.deliverEvent = deliverEvent
    }

    /// Probehören starten/stoppen (Klick auf denselben Sender = Stopp).
    func toggle(_ station: RBStation, volume: Float) {
        objectWillChange.send()
        let action = switches.toggle(stationID: station.stationuuid)
        if case .stop = action {
            stop(invalidateGeneration: false)
            return
        }
        guard case let .replace(generation) = action else { return }

        // A bleibt waehrend der Aufloesung aktiv; B erhaelt anschliessend eine
        // eigene VLC-Instanz, damit spaete Ereignisse eindeutig A gehoeren.
        resolveTask?.cancel()
        resolveTask = nil
        failedID = nil
        isLoading = true
        let stationID = station.stationuuid
        guard let rawURL = StreamURLPolicy.validatedURL(station.streamURL) else {
            markFailed(generation: generation, stationID: stationID)
            return
        }
        resolveTask = Task { [weak self] in
            // Auch Katalog-URLs können Playlist-Container sein -> auflösen.
            let resolved = await PlaylistResolver.resolve(rawURL.absoluteString)
            guard let self, !Task.isCancelled else { return }
            guard self.switches.accepts(generation, stationID: stationID) else { return }
            guard let url = resolved else {
                self.markFailed(generation: generation, stationID: stationID)
                return
            }
            RadioBrowserAPI.countClick(stationUUID: stationID)
            let previous = self.player
            previous.delegate = nil
            self.player = VLCMediaPlayer()
            let nextShim = PlayerDelegateShim(
                deliverEvent: self.deliverEvent,
                onState: { [weak self] state in
                    guard let self, self.switches.accepts(generation, stationID: stationID),
                          self.switches.hasInstalledMedia else { return }
                    self.handleState(state)
                },
                onTime: { [weak self] in
                    guard let self, self.switches.accepts(generation, stationID: stationID),
                          self.switches.hasInstalledMedia else { return }
                    self.isLoading = false
                })
            self.shim = nextShim
            self.player.delegate = nextShim
            previous.stop()  // ein spaeter Stop erreicht niemals die neue Instanz
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=1500")
            self.player.media = media
            self.player.audio?.volume = Int32(max(0, min(1, volume)) * 100)
            // Ab hier gehoeren Player-Ereignisse zu DIESER Vorschau (siehe
            // hasInstalledMedia im Koordinator).
            self.switches.mediaInstalled(generation: generation, stationID: stationID)
            self.player.play()
        }
    }

    func setVolume(_ v: Float) {
        player.audio?.volume = Int32(max(0, min(1, v)) * 100)
    }

    func stop() {
        stop(invalidateGeneration: true)
    }

    private func stop(invalidateGeneration: Bool) {
        objectWillChange.send()
        if invalidateGeneration { switches.stop() }
        resolveTask?.cancel()
        resolveTask = nil
        if player.isPlaying || player.media != nil { player.stop() }
        isLoading = false
    }

    private func handleState(_ state: VLCMediaPlayerState) {
        switch state {
        case .error:
            // Nur ein Fehler des eigenen installierten Mediums zaehlt. Instanz
            // und Generation wurden bereits in der Delegate-Closure geprueft.
            guard switches.hasInstalledMedia else { return }
            markFailed()
        case .ended, .stopped:
            // Stream selbst zu Ende/abgerissen -> Zustand aufräumen. Ein manueller
            // stop() hat currentID schon genullt, dann ist das hier ein No-Op.
            // Den Übergang entscheidet der Koordinator (VLC-frei und im Harness
            // getestet), damit der Neustart desselben Senders funktioniert.
            if switches.finishTerminal() {
                objectWillChange.send()
                isLoading = false
            }
        default:
            break
        }
    }

    private func markFailed(generation: UInt64? = nil, stationID: String? = nil) {
        if let generation, let stationID,
           !switches.accepts(generation, stationID: stationID) { return }
        objectWillChange.send()
        failedID = switches.currentID
        switches.stop()
        isLoading = false
        player.stop()
    }
}

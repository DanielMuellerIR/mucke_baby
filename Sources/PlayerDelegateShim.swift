import Foundation
import VLCKit

typealias PlayerEventDelivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

let deliverPlayerEventOnMain: PlayerEventDelivery = { event in
    DispatchQueue.main.async { event() }
}

// Delegate-Bruecke: VLCKit ruft ObjC-Delegate-Methoden auf. Diese kleine
// NSObject-Klasse faengt sie ab und leitet sie als Closures auf den Main-Thread.
final class PlayerDelegateShim: NSObject, VLCMediaPlayerDelegate {
    // Jede Bruecke gehoert genau einer VLC-Instanz und einer Wiedergabe.
    // Die Closures bleiben unveraendert, auch wenn ein Ereignis auf Main wartet.
    private let deliverEvent: PlayerEventDelivery
    private let onState: @MainActor @Sendable (VLCMediaPlayerState) -> Void
    private let onTime: @MainActor @Sendable () -> Void

    init(deliverEvent: @escaping PlayerEventDelivery = deliverPlayerEventOnMain,
         onState: @escaping @MainActor @Sendable (VLCMediaPlayerState) -> Void,
         onTime: @escaping @MainActor @Sendable () -> Void) {
        self.deliverEvent = deliverEvent
        self.onState = onState
        self.onTime = onTime
        super.init()
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // VLCKit liefert die betroffene Instanz als Notification-Objekt. Den
        // Zustand jetzt sichern: bis zur Main-Queue kann .error bereits von
        // .stopped abgeloest sein, wodurch der Fehlerhinweis verloren ginge.
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        let state = player.state
        deliverEvent { [onState] in onState(state) }
    }
    // Zeit laeuft -> zuverlaessiges "spielt jetzt"-Signal (state bleibt bei
    // Live-Streams oft auf .buffering haengen).
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        deliverEvent(onTime)
    }
}

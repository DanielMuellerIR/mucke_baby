import AppKit
import Network

@MainActor
final class PlaybackObservations {
    let center = NSWorkspace.shared.notificationCenter
    var timer: Timer?
    var tokens: [NSObjectProtocol] = []

    private let networkQueue = DispatchQueue(label: "MuckeBaby.network")
    private var monitor: NWPathMonitor?
    private var networkToken = UUID()

    func startNetwork(deliverEvent: @escaping PlayerEventDelivery,
                      onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        stopNetwork()
        let token = networkToken
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status != .unsatisfied
            deliverEvent { [weak self] in
                guard self?.networkToken == token else { return }
                onChange(available)
            }
        }
        self.monitor = monitor
        monitor.start(queue: networkQueue)
    }

    func stopNetwork() {
        networkToken = UUID()
        monitor?.cancel()
        monitor = nil
    }

    func cancel() {
        stopNetwork()
        timer?.invalidate()
        timer = nil
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}

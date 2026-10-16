import Foundation

// Betriebssystem-Befehle und ihre Gültigkeit bleiben unabhängig vom MediaPlayer-SDK testbar.
enum SystemMediaAction: Sendable { case play, pause, stop, toggle, previous, next }
enum SystemMediaPlaybackState: Equatable { case playing, loading }
struct SystemMediaInfo: Equatable {
    var title: String
    var artist: String?
    var station: String
    var playing: Bool
}
struct SystemMediaSnapshot {
    var station: Station?
    var playing = false
    var loading = false
    var title = ""
    var status = ""
    var stations: [Station] = []
}

@MainActor
protocol SystemMediaBackend: AnyObject {
    func setHandler(_ handler: (@Sendable (SystemMediaAction) -> Bool)?)
    func publish(_ info: SystemMediaInfo)
    func setPlaybackState(_ state: SystemMediaPlaybackState)
    func setNavigationEnabled(_ enabled: Bool)
    func clear()
}

// SDK-Handler dürfen auf fremden Threads eintreffen; jede Registrierung besitzt eine eigene Identität.
private final class SystemMediaGate: @unchecked Sendable {
    struct Lease: Sendable { let gateID: UUID; let revision: UInt64; let stationID: UUID }
    private let lock = NSLock()
    private let identity = UUID()
    private var revision: UInt64 = 0
    private var stationID: UUID?
    func invalidate() { lock.lock(); revision &+= 1; stationID = nil; lock.unlock() }
    func enable(_ id: UUID) { lock.lock(); revision &+= 1; stationID = id; lock.unlock() }
    func current() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        return stationID.map { Lease(gateID: identity, revision: revision, stationID: $0) }
    }
    func accepts(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identity == lease.gateID && revision == lease.revision && stationID == lease.stationID
    }
}

@MainActor
final class SystemMediaCoordinator {
    private let backend: any SystemMediaBackend
    private var gate = SystemMediaGate()
    private let perform: (SystemMediaAction, Station?) -> Void
    private var snapshot = SystemMediaSnapshot()
    private var active = false
    private var lastInfo: SystemMediaInfo?
    private var lastState: SystemMediaPlaybackState?

    init(backend: any SystemMediaBackend, perform: @escaping (SystemMediaAction, Station?) -> Void) {
        self.backend = backend; self.perform = perform
    }
    func invalidatePendingCommands() { gate.invalidate() }
    func apply(_ snapshot: SystemMediaSnapshot) {
        self.snapshot = snapshot
        guard let station = snapshot.station, snapshot.playing || snapshot.loading else { deactivate(); return }
        if !active {
            active = true
            gate = SystemMediaGate()
            let gate = self.gate
            backend.setHandler { [weak self, gate] action in
                guard let lease = gate.current() else { return false }
                Task { @MainActor [weak self] in self?.handle(action, lease: lease) }
                return true
            }
        }
        let split = SongEntry.split(snapshot.title)
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (snapshot.playing ? station.name : snapshot.status) : (split.title ?? snapshot.title)
        let info = SystemMediaInfo(title: title, artist: split.artist, station: station.name, playing: snapshot.playing)
        if lastInfo != info { backend.publish(info); lastInfo = info }
        let state: SystemMediaPlaybackState = snapshot.playing ? .playing : .loading
        // Titeländerungen senden keine erneute Play-Anforderung an die Systemsteuerung.
        if lastState != state { backend.setPlaybackState(state); lastState = state }
        backend.setNavigationEnabled(eligibleStations.count > 1)
        gate.enable(station.id)
    }
    func deactivate() {
        gate.invalidate()
        guard active else { return }
        active = false; backend.setHandler(nil); backend.clear()
        lastInfo = nil; lastState = nil
    }
    private var eligibleStations: [Station] {
        snapshot.stations.filter { $0.enabled && StreamURLPolicy.validatedURL($0.url) != nil }
    }
    private func handle(_ action: SystemMediaAction, lease: SystemMediaGate.Lease) {
        guard gate.accepts(lease), active, snapshot.station?.id == lease.stationID else { return }
        switch action {
        case .pause, .stop, .toggle:
            deactivate(); perform(action, nil)
        case .play:
            if !snapshot.playing { perform(.play, snapshot.station) }
        case .previous, .next:
            let stations = eligibleStations
            guard stations.count > 1 else { return }
            let index = stations.firstIndex { $0.id == lease.stationID }
            let target: Int
            if let index { target = (index + (action == .next ? 1 : stations.count - 1)) % stations.count }
            else { target = action == .next ? 0 : stations.count - 1 }
            perform(action, stations[target])
        }
    }
}

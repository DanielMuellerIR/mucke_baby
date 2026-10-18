import Foundation

@MainActor
final class MediaBackendFixture: SystemMediaBackend {
    var handler: (@Sendable (SystemMediaAction) -> Bool)?
    var info: [SystemMediaInfo] = []
    var states: [SystemMediaPlaybackState] = []
    var navigation = false
    var registrations = 0
    var clears = 0
    func setHandler(_ handler: (@Sendable (SystemMediaAction) -> Bool)?) { self.handler = handler; if handler != nil { registrations += 1 } }
    func publish(_ info: SystemMediaInfo) { self.info.append(info) }
    func setPlaybackState(_ state: SystemMediaPlaybackState) { states.append(state) }
    func setNavigationEnabled(_ enabled: Bool) { navigation = enabled }
    func clear() { clears += 1 }
}

@main
enum SystemMediaHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Medienbefehl wurde nicht verarbeitet")
    }
    @MainActor static func main() async {
        let a = Station(name: "Alpha", url: "https://fixture.invalid/a")
        let b = Station(name: "Björk 東京", url: "https://fixture.invalid/b")
        let hidden = Station(name: "Hidden", url: "https://fixture.invalid/hidden", enabled: false)
        let unsafe = Station(name: "Unsafe", url: "file:///tmp/untrusted.mp3")
        let backend = MediaBackendFixture()
        var actions: [(SystemMediaAction, Station?)] = []
        let media = SystemMediaCoordinator(backend: backend) { actions.append(($0, $1)) }
        media.apply(SystemMediaSnapshot())
        check(backend.registrations == 0 && backend.clears == 0, "Inaktive App verändert fremde Mediensteuerung")
        var snapshot = SystemMediaSnapshot(station: a, playing: true, title: "Björk - Hyperballad", stations: [a,hidden,unsafe,b])
        media.apply(snapshot)
        check(backend.info.last == SystemMediaInfo(title: "Hyperballad", artist: "Björk", station: "Alpha", playing: true) && backend.navigation,
              "Titel, Sender oder globale Sendernavigation falsch")
        let states = backend.states.count, publications = backend.info.count
        media.apply(snapshot)
        check(backend.info.count == publications && backend.states.count == states, "Unveränderte Daten werden wiederholt publiziert")
        snapshot.title = "New artist - New song"; media.invalidatePendingCommands(); media.apply(snapshot)
        check(backend.states.count == states, "Metadatenänderung beansprucht den Wiedergabezustand erneut")
        check(backend.handler?(.next) == true, "Nächster Sender fehlt"); await wait { actions.count == 1 }
        check(actions[0].1?.id == b.id, "Nächster Sender verwendet versteckte/ungültige Sender")
        check(backend.handler?(.previous) == true, "Voriger Sender fehlt"); await wait { actions.count == 2 }
        check(actions[1].1?.id == b.id, "Voriger Sender rollt nicht in gespeicherter Reihenfolge")
        let oldHandler = backend.handler!
        check(oldHandler(.next), "Spätbefehlsfixture fehlt")
        media.invalidatePendingCommands(); media.apply(SystemMediaSnapshot(station: a))
        media.apply(snapshot)
        try? await Task.sleep(for: .milliseconds(10))
        check(actions.count == 2 && !oldHandler(.next), "Alter Befehl/Handler erreicht neue Wiedergabe desselben Senders")
        snapshot.playing = false; snapshot.loading = true; snapshot.title = ""; snapshot.status = "Warte auf Netzwerk"
        media.invalidatePendingCommands(); media.apply(snapshot)
        check(backend.info.last?.title == snapshot.status && backend.states.last == .loading, "Wartezustand zeigt alten Titel oder aktive Ausgabe")
        check(backend.handler?(.play) == true, "Expliziter Start im Wartezustand fehlt"); await wait { actions.count == 3 }
        check(actions.last?.0 == .play && actions.last?.1?.id == a.id, "Start wählt fremden Sender")
        check(backend.handler?(.pause) == true, "Pause-Befehl fehlt"); await wait { actions.count == 4 }
        check(actions.last?.0 == .pause && backend.handler == nil && backend.clears == 2, "Live-Pause gibt Befehle/Titel nicht frei")
        media.deactivate(); check(backend.clears == 2, "Wiederholtes Freigeben greift unnötig in Medienzustand ein")
        snapshot.station = b; snapshot.stations = [a]; snapshot.playing = true; snapshot.loading = false
        media.apply(snapshot); check(!backend.navigation, "Navigation mit nur einem gültigen Sender aktiv")
        snapshot.stations = [a, Station(name: "Gamma", url: "https://fixture.invalid/c")]
        media.invalidatePendingCommands(); media.apply(snapshot)
        check(backend.handler?(.next) == true, "Navigation nach gelöschtem Sender fehlt"); await wait { actions.count == 5 }
        check(actions.last?.1?.id == a.id, "Entfernter aktueller Sender findet keinen gültigen Nachfolger")
        media.deactivate()
        snapshot.station = a; snapshot.playing = true; snapshot.canPause = true
        media.apply(snapshot)
        let pausedHandler = backend.handler!
        let beforePause = actions.count
        check(pausedHandler(.pause), "Zeitversatz-Pause fehlt")
        await wait { actions.count == beforePause + 1 }
        check(backend.handler != nil, "Zeitversatz-Pause entfernt Fortsetzen-Handler")
        snapshot.playing = false; snapshot.paused = true; snapshot.title = "Heard - Earlier"
        media.invalidatePendingCommands(); media.apply(snapshot)
        check(backend.states.last == .paused && backend.info.last?.title == "Earlier", "Gehörter Titel/Pausenzustand fehlt")
        check(backend.handler?(.play) == true, "Fortsetzen fehlt")
        await wait { actions.count == beforePause + 2 }
        check(actions.last?.0 == .play && actions.last?.1?.id == a.id, "Fortsetzen wählt anderen Sender")
        media.deactivate()
        print("SystemMediaHarness: Metadaten, globale Reihenfolge, Live-Stopp, Registrierungen, alte Befehle und Zustandsfreigabe OK")
    }
}

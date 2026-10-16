import Foundation

@main
struct ReconnectHarness {
    @MainActor
    static func main() async {
        let a = UUID(), b = UUID()
        let clock = ReconnectClock()
        let reconnect = PlaybackReconnect(schedule: clock.schedule)
        var retries: [UUID] = []
        reconnect.onRetry = { id in retries.append(id); reconnect.attemptStarted() }
        reconnect.onTimeout = { reconnect.failed() }
        reconnect.beginIntent(stationID: a); reconnect.attemptStarted(); reconnect.failed()
        let staleRetry = clock.events.last!
        reconnect.failed()
        clock.advance(1.99)
        check(retries.isEmpty, "Erster Versuch startet vor Ablauf der Wartezeit")
        clock.advance(0.01)
        check(retries == [a] && reconnect.retryCount == 1, "Erste Wiederholung fehlt")
        reconnect.failed(); clock.advance(5)
        check(retries.count == 2, "Zweite Wiederholung fehlt")
        reconnect.failed(); clock.advance(15)
        check(retries.count == 3, "Dritte Wiederholung fehlt")
        reconnect.failed(); clock.advance(1000)
        reconnect.setNetworkAvailable(false); reconnect.setNetworkAvailable(true)
        check(retries.count == 3 && reconnect.phase == .exhausted && reconnect.desiredStationID == nil,
              "Dauerfehler oder Netzwechsel hebt Versuchslimit auf")
        staleRetry.action()
        check(retries.count == 3, "Verspäteter Timer startet erschöpften Auftrag")

        reconnect.beginIntent(stationID: a); reconnect.attemptStarted(); reconnect.failed()
        let cancelled = clock.events.last!
        reconnect.cancel(); cancelled.action(); clock.advance(100)
        check(retries.count == 3 && reconnect.phase == .idle, "Stop verhindert späten Neustart nicht")
        reconnect.beginIntent(stationID: a); reconnect.attemptStarted(); reconnect.failed()
        let oldStation = clock.events.last!
        reconnect.beginIntent(stationID: b); reconnect.attemptStarted(); oldStation.action()
        check(retries.count == 3, "Alter Sender startet nach Wechsel erneut")
        reconnect.failed(); clock.advance(2)
        check(retries.last == b && retries.count == 4, "Neuer Sender übernimmt nicht den Auftrag")

        reconnect.failed(); reconnect.setNetworkAvailable(false)
        check(reconnect.phase == .waitingForNetwork(attempt: 2), "Offline-Zustand fehlt")
        clock.advance(3600)
        check(retries.count == 4, "Offline wird weiter verbunden")
        reconnect.setNetworkAvailable(true)
        check(retries.count == 5 && reconnect.retryCount == 2, "Netzrückkehr setzt gewünschten Auftrag nicht genau einmal fort")
        reconnect.setNetworkAvailable(false); reconnect.setNetworkAvailable(true)
        check(retries.count == 5, "Netzflattern startet parallele Verbindungen")
        reconnect.playing()
        for _ in 0..<3 { clock.advance(20); reconnect.activity() }
        check(reconnect.retryCount == 0, "Stabile Wiedergabe setzt Budget nicht zurück")
        reconnect.failed()
        check(reconnect.phase == .waiting(attempt: 1, delay: 2), "Neue Störung erhält kein neues begrenztes Budget")

        reconnect.beginIntent(stationID: a); reconnect.attemptStarted()
        let staleActivity = clock.events.last!
        clock.advance(25); reconnect.activity(); staleActivity.action()
        check(reconnect.phase == .connecting, "Alter Stillstands-Timer beendet aktive Wiedergabe")
        clock.advance(29)
        check(reconnect.phase == .connecting, "Frischer Stillstands-Timer endet zu früh")
        clock.advance(1)
        check(reconnect.phase == .waiting(attempt: 1, delay: 2), "Lade-/Stillstandsgrenze fehlt")
        reconnect.cancel()
        reconnect.beginIntent(stationID: a); reconnect.attemptStarted(); reconnect.playing()
        let staleStable = clock.events.last!
        reconnect.failed(); clock.advance(2); staleStable.action()
        check(reconnect.retryCount == 1, "Alter Stabilitäts-Timer setzt neues Versuchslimit zurück")
        reconnect.cancel()

        let flappingClock = ReconnectClock()
        let flapping = PlaybackReconnect(schedule: flappingClock.schedule)
        var flapRetries = 0
        flapping.onRetry = { _ in flapRetries += 1; flapping.attemptStarted() }
        flapping.beginIntent(stationID: a); flapping.attemptStarted()
        for index in 0..<4 {
            flapping.playing(); flappingClock.advance(5); flapping.failed()
            if index < 3 { flappingClock.advance([2, 5, 15][index]) }
        }
        check(flapRetries == 3 && flapping.phase == .exhausted, "Kurze Erfolgsmeldungen erzeugen Endlosschleife")
        flapping.cancel()

        let realTimer = PlaybackReconnect(delays: [0.01], inactivityTimeout: 1)
        var actualRetries = 0
        realTimer.onRetry = { _ in actualRetries += 1 }
        realTimer.beginIntent(stationID: a); realTimer.attemptStarted(); realTimer.failed()
        for _ in 0..<200 where actualRetries == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        check(actualRetries == 1, "Produktiver Task-Zeitgeber löst nicht aus")
        realTimer.beginIntent(stationID: a); realTimer.attemptStarted(); realTimer.failed(); realTimer.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        check(actualRetries == 1, "Produktiver Task-Zeitgeber ignoriert Abbruch")
        print("ReconnectHarness: Begrenzung, Netzrückkehr, stabile Wiedergabe, Stillstand und Abbruch OK")
    }
    private static func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) } }
}

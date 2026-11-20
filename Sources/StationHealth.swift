import Foundation
import os

// Prueft Sender im Hintergrund auf Erreichbarkeit (beim Start + bei Listenaenderung).
// Laeuft nebenlaeufig (max 8 gleichzeitig) und blockiert die GUI nicht. Ergebnis
// pro Sender als @Published -> ⚠️-Anzeige in der Liste, Klick zeigt den Fehler.
@MainActor
final class StationHealth: ObservableObject {
    enum Status: Equatable, Sendable { case unknown, checking, ok, bad(String) }

    @Published var states: [UUID: Status] = [:]
    private var running = false
    private var pending: [Station]?   // waehrend eines Laufs zuletzt angeforderte Liste
    private var requestedURLs: [UUID: String] = [:]
    private let probeURL: @Sendable (String) async -> Status

    init(probe: @escaping @Sendable (String) async -> Status = { await StationHealth.probe($0) }) {
        probeURL = probe
    }

    func checkAll(_ stations: [Station]) {
        let nextURLs = Dictionary(stations.map { ($0.id, $0.url) }, uniquingKeysWith: { _, last in last })
        states = states.filter { nextURLs[$0.key] != nil }
        for s in stations where requestedURLs[s.id] != s.url || states[s.id] != .ok {
            states[s.id] = .checking
        }
        requestedURLs = nextURLs
        // Laeuft schon eine Pruefung? Dann nur die neueste Liste vormerken und nach
        // Abschluss genau einmal nachholen — sonst wuerden waehrend des Laufs (bis zu
        // 8 s pro Sender) hinzugefuegte Sender nie geprueft (Guard verwarf den Aufruf).
        if running { pending = stations; return }
        running = true
        Task {
            await run(stations)
            running = false
            if let next = pending { pending = nil; checkAll(next) }
        }
    }

    private func run(_ stations: [Station]) async {
        let probe = probeURL
        await withTaskGroup(of: (UUID, String, Status).self) { group in
            var it = stations.makeIterator()
            var active = 0
            let maxConcurrent = 8
            func fill() {
                while active < maxConcurrent, let s = it.next() {
                    active += 1
                    group.addTask { (s.id, s.url, await probe(s.url)) }
                }
            }
            fill()
            for await (id, url, st) in group {
                if requestedURLs[id] == url { states[id] = st }
                active -= 1
                fill()
            }
        }
    }

    // Erst Playlist aufloesen (tote Streams hinter .pls/.m3u erkennen), dann
    // nur die Antwort-Header pruefen (Body nicht laden — Streams enden nie).
    nonisolated static func probe(_ urlStr: String) async -> Status {
        // Kein Fallback auf die rohe Eingabe: Sonst wuerde die zentrale
        // HTTP(S)-Policy fuer file:/ und andere URLSession-Protokolle umgangen.
        guard let url = await PlaylistResolver.resolve(urlStr) else {
            return .bad("Ungültige URL")
        }
        return await withCheckedContinuation { cont in
            HealthProbe(cont).start(url: url)
        }
    }
}

// Einzel-Probe: cancelt nach den Headern (kein Body-Download bei Endlos-Streams).
private final class HealthProbe: NSObject, URLSessionDataDelegate {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<StationHealth.Status, Never>?>

    init(_ continuation: CheckedContinuation<StationHealth.Status, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func start(url: URL) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue(AppInfo.streamUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        s.dataTask(with: req).resume()
    }

    private func finish(_ status: StationHealth.Status, session: URLSession) {
        let callback = continuation.withLock { pending in
            let callback = pending
            pending = nil
            return callback
        }
        guard let callback else { return }
        session.invalidateAndCancel()
        callback.resume(returning: status)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let http = response as? HTTPURLResponse {
            let c = http.statusCode
            if (200..<400).contains(c) { finish(.ok, session: s) } else { finish(.bad("HTTP \(c)"), session: s) }
        } else {
            finish(.ok, session: s)   // ICY-Server ohne HTTP-Statuszeile -> als ok werten
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            finish(.bad(e.localizedDescription), session: s)
        } else {
            // codereview-ok: else meldet bei ausbleibender Antwort korrekt 'Keine Antwort'; Cancelled-Pfad ist by design (2026-07-01)
            finish(.bad("Keine Antwort"), session: s)
        }
    }
}

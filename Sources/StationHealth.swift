import Foundation

// Prueft Sender im Hintergrund auf Erreichbarkeit (beim Start + bei Listenaenderung).
// Laeuft nebenlaeufig (max 8 gleichzeitig) und blockiert die GUI nicht. Ergebnis
// pro Sender als @Published -> ⚠️-Anzeige in der Liste, Klick zeigt den Fehler.
@MainActor
final class StationHealth: ObservableObject {
    enum Status: Equatable { case unknown, checking, ok, bad(String) }

    @Published var states: [UUID: Status] = [:]
    private var running = false

    func checkAll(_ stations: [Station]) {
        guard !running else { return }
        running = true
        for s in stations where !s.url.isEmpty {
            if states[s.id] != .ok { states[s.id] = .checking }
        }
        Task { await run(stations); running = false }
    }

    private func run(_ stations: [Station]) async {
        await withTaskGroup(of: (UUID, Status).self) { group in
            var it = stations.makeIterator()
            var active = 0
            let maxConcurrent = 8
            func fill() {
                while active < maxConcurrent, let s = it.next() {
                    active += 1
                    group.addTask { (s.id, await Self.probe(s.url)) }
                }
            }
            fill()
            for await (id, st) in group {
                states[id] = st
                active -= 1
                fill()
            }
        }
    }

    // Erst Playlist aufloesen (tote Streams hinter .pls/.m3u erkennen), dann
    // nur die Antwort-Header pruefen (Body nicht laden — Streams enden nie).
    nonisolated static func probe(_ urlStr: String) async -> Status {
        let resolved = await PlaylistResolver.resolve(urlStr) ?? URL(string: urlStr)
        guard let url = resolved else { return .bad("Ungültige URL") }
        return await withCheckedContinuation { cont in
            HealthProbe(cont).start(url: url)
        }
    }
}

// Einzel-Probe: cancelt nach den Headern (kein Body-Download bei Endlos-Streams).
private final class HealthProbe: NSObject, URLSessionDataDelegate {
    private var cont: CheckedContinuation<StationHealth.Status, Never>?
    private var session: URLSession?

    init(_ c: CheckedContinuation<StationHealth.Status, Never>) { cont = c }

    func start(url: URL) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: url)
        req.setValue("MuckeBaby/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        s.dataTask(with: req).resume()
    }

    private func finish(_ st: StationHealth.Status) {
        cont?.resume(returning: st); cont = nil
        session?.invalidateAndCancel(); session = nil
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let http = response as? HTTPURLResponse {
            let c = http.statusCode
            if (200..<400).contains(c) { finish(.ok) } else { finish(.bad("HTTP \(c)")) }
        } else {
            finish(.ok)   // ICY-Server ohne HTTP-Statuszeile -> als ok werten
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard cont != nil else { return }
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            finish(.bad(e.localizedDescription))
        } else {
            finish(.bad("Keine Antwort"))
        }
    }
}

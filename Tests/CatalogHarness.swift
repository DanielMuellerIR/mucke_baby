import Foundation

final class CatalogHTTPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var mode = "normal"
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let mode = Self.mode; Self.lock.unlock()
        let host = request.url!.host!
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let delay = mode == "cancel" ? 0.3 : 0.0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            Self.lock.lock(); let stopped = self.stopped; Self.lock.unlock()
            guard !stopped else { return }
            let status = host == "broken.invalid" || mode == "offline" ? 503 : 200
            let body: Data
            if mode == "oversized" { body = Data(repeating: 32, count: 4 * 1024 * 1024 + 1) }
            else if self.request.url!.path.contains("stations") {
                let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
                let count = offset == 0 ? 51 : 2
                body = try! JSONSerialization.data(withJSONObject: (0..<count).map { index in
                    ["stationuuid": String(format: "00000000-0000-4000-8000-%012d", offset + index),
                     "name": "Fixture \(offset + index)", "url": "https://example.com/\(offset + index)",
                     "bitrate": index == 0 ? 0 : 128, "codec": "MP3"] as [String: Any]
                })
            } else { body = Data("[{\"name\":\"german\",\"stationcount\":\"12\",\"iso_639\":\"de\",\"iso_3166_1\":\"DE\"}]".utf8) }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    static func reset(_ mode: String = "normal") { lock.lock(); requests = []; Self.mode = mode; lock.unlock() }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

actor ControlledCatalog: CatalogFetching {
    private var pending: [String: CheckedContinuation<CatalogPage, Error>] = [:]
    func search(_ selection: CatalogSelection, at date: Date) async throws -> CatalogPage {
        try await withCheckedThrowingContinuation { pending[selection.query.name] = $0 }
    }
    func facets() async throws -> CatalogFacets { CatalogFacets() }
    func has(_ name: String) -> Bool { pending[name] != nil }
    func respond(_ page: CatalogPage) { pending.removeValue(forKey: page.selection.query.name)!.resume(returning: page) }
}

@main
struct CatalogHarness {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeBaby-Catalog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RadioBrowserClient(mirrors: ["https://broken.invalid", "https://working.invalid"], session: session)
        var query = CatalogQuery()
        query.name = "  Björk & 東京?  "; query.countryCode = "de"; query.language = "german"
        query.tag = "drum/bass & jazz"; query.codec = "MP3"; query.minimumBitrate = 128
        CatalogHTTPFixture.reset()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await client.search(CatalogSelection(query: query), at: date)
        check(first.stations.count == 50 && first.hasNext, "Seitengröße oder Vorschau auf Folgeseite falsch")
        let request = CatalogHTTPFixture.recorded().last!
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        check(items["name"] == "Björk & 東京?" && items["tag"] == "drum/bass & jazz" && items["countrycode"] == "DE"
              && items["languageExact"] == "true" && items["tagExact"] == "true" && items["bitrateMin"] == "128",
              "Kombinierte Filter oder URL-Encoding falsch")
        check(items["limit"] == "51" && items["offset"] == "0" && CatalogHTTPFixture.recorded().count == 2, "Mirror-Failover oder Seitenparameter falsch")
        check(first.stations[0].detail.contains("Bitrate unbekannt"), "Unbekannte Bitrate wird verborgen oder falsch angegeben")
        let second = try await client.search(CatalogSelection(query: query, page: 1), at: date)
        check(second.stations.count == 2 && !second.hasNext && second.stations[0].name == "Fixture 50", "Seitenwechsel überschneidet oder verliert Sender")
        let facets = try await client.facets()
        check(facets.tags.first?.stationcount == 12 && facets.languages.first?.iso_639 == "de", "Flexible Facetten-Daten werden nicht dekodiert")

        let cache = CatalogCache(directory: root)
        cache.save(page: first); cache.save(page: second, facets: facets)
        let restarted = CatalogCache(directory: root)
        check(restarted.pages.count == 2 && restarted.selection == second.selection && restarted.facets == facets,
              "Cache oder Suchauswahl übersteht Neustart nicht")
        check(first.isStale(at: date.addingTimeInterval(86_401)) && !first.isStale(at: date.addingTimeInterval(3600)), "Cachealter falsch")
        for index in 2..<25 {
            cache.save(page: CatalogPage(selection: CatalogSelection(query: query.normalized, page: index), stations: second.stations, hasNext: false, fetchedAt: date))
        }
        check(cache.pages.count == 20 && cache.pages.first!.selection.page == 5, "Cache hat keine feste Seitengrenze")
        check(try Data(contentsOf: root.appendingPathComponent("catalog-cache.json")).count <= CatalogCache.maximumBytes, "Cache überschreitet Bytegrenze")
        let bigRows = try JSONDecoder().decode([RBStation].self, from: JSONSerialization.data(withJSONObject: (0..<50).map { index in
            ["stationuuid": String(format: "00000000-0000-4000-8000-%012d", index),
             "name": String(repeating: "n", count: 4000), "url": "https://example.com/" + String(repeating: "p", count: 7000) + String(index)]
        }))
        let bigRoot = root.appendingPathComponent("big")
        let bigCache = CatalogCache(directory: bigRoot)
        for index in 0..<6 {
            bigCache.save(page: CatalogPage(selection: CatalogSelection(page: index), stations: bigRows, hasNext: true, fetchedAt: date))
        }
        let bigData = try Data(contentsOf: bigRoot.appendingPathComponent("catalog-cache.json"))
        check(bigCache.pages.count < 6 && bigCache.pages.last?.selection.page == 5 && bigData.count <= CatalogCache.maximumBytes,
              "Bytegrenze verwirft keine alten Seiten oder verliert die aktuelle Auswahl")
        let oversizedRoot = root.appendingPathComponent("oversized-cache")
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        let oversizedBytes = Data(repeating: 32, count: CatalogCache.maximumBytes + 1)
        try oversizedBytes.write(to: oversizedRoot.appendingPathComponent("catalog-cache.json"))
        let oversizedCache = CatalogCache(directory: oversizedRoot)
        oversizedCache.save(page: first)
        let untouched = try Data(contentsOf: oversizedRoot.appendingPathComponent("catalog-cache.json"))
        check(oversizedCache.notice != nil && untouched == oversizedBytes, "Übergroßer Cache wird gelesen oder überschrieben")

        let before = cache.pages
        let saved = root.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: root.appendingPathComponent("catalog-cache.json"), to: saved)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("catalog-cache.json"), withIntermediateDirectories: true)
        cache.save(page: first)
        check(cache.pages == before && cache.notice != nil, "Schreibfehler veröffentlicht ungesicherten Cache")
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-cache.json"))
        let future = Data("{\"formatVersion\":9,\"future\":true}".utf8)
        try future.write(to: root.appendingPathComponent("catalog-cache.json"))
        let unknown = CatalogCache(directory: root); unknown.save(page: first)
        let retainedFuture = try Data(contentsOf: root.appendingPathComponent("catalog-cache.json"))
        check(unknown.notice != nil && retainedFuture == future, "Neuere Cacheversion wird überschrieben")

        let modelRoot = root.appendingPathComponent("model")
        let modelCache = CatalogCache(directory: modelRoot)
        modelCache.save(page: first)
        CatalogHTTPFixture.reset("offline")
        let offline = CatalogModel(cache: modelCache, client: client)
        offline.load(first.selection)
        await wait { !offline.loading }
        check(offline.cached && offline.page == first && offline.errorMessage != nil, "Offline-Fallback verliert gespeicherte Treffer oder Kennzeichnung")
        offline.showSaved(first)
        check(offline.unavailable && offline.errorMessage != nil, "Gespeicherte Seitenauswahl verliert bekannte Offline-Kennzeichnung")
        let controlled = ControlledCatalog()
        let model = CatalogModel(cache: CatalogCache(directory: root.appendingPathComponent("controlled")), client: controlled)
        var a = CatalogQuery(); a.name = "A"
        var b = CatalogQuery(); b.name = "B"
        model.load(CatalogSelection(query: a))
        for _ in 0..<100 where !(await controlled.has("A")) { try? await Task.sleep(for: .milliseconds(5)) }
        model.load(CatalogSelection(query: b))
        for _ in 0..<100 where !(await controlled.has("B")) { try? await Task.sleep(for: .milliseconds(5)) }
        let pageB = CatalogPage(selection: CatalogSelection(query: b), stations: second.stations, hasNext: false, fetchedAt: date)
        await controlled.respond(pageB); await wait { model.page == pageB && !model.loading }
        await controlled.respond(CatalogPage(selection: CatalogSelection(query: a), stations: first.stations, hasNext: true, fetchedAt: date))
        try? await Task.sleep(for: .milliseconds(20))
        check(model.page == pageB && model.cache.pages.count == 1, "Verspätete Antwort überschreibt neue Auswahl oder Cache")
        model.cancel()

        CatalogHTTPFixture.reset("cancel")
        let cancelled = Task { try await client.search(CatalogSelection()) }
        try? await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Abbruch wurde ignoriert") } catch is CancellationError { }
        check(CatalogHTTPFixture.recorded().count == 1, "Abbruch versucht einen weiteren Mirror")
        CatalogHTTPFixture.reset("oversized")
        do { _ = try await client.search(CatalogSelection()); fatalError("Überlange Antwort akzeptiert") }
        catch { check((error as? URLError)?.code == .dataLengthExceedsMaximum, "Falscher Größenlimit-Fehler") }
        print("CatalogHarness: Filter, Encoding, Seiten, Failover, Cachegrenzen, Offline, Abbruch und alte Antworten OK")
    }
    @MainActor
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        fatalError("Katalogzustand nicht erreicht")
    }
    static func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) } }
}

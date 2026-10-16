import Foundation

final class OriginHTTPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var body = Data()
    static var requests: [URLRequest] = []
    static var cancelled = 0
    static var delay = 0.0
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.cancelled += 1; Self.lock.unlock() }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let data = Self.body; let delay = Self.delay; Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            Self.lock.lock(); let stopped = self.stopped; Self.lock.unlock()
            guard !stopped else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: self.request.url!.host == "broken.invalid" ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    static func set(_ rows: [RBStation], delay: Double = 0) throws {
        lock.lock(); defer { lock.unlock() }
        body = try JSONEncoder().encode(rows); requests = []; cancelled = 0; Self.delay = delay
    }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

actor ControlledOrigin: StationOriginFetching {
    private var pending: [UUID: CheckedContinuation<RBStation?, Error>] = [:]
    func station(id: UUID) async throws -> RBStation? {
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func has(_ id: UUID) -> Bool { pending[id] != nil }
    func respond(_ id: UUID, row: RBStation?) { pending.removeValue(forKey: id)!.resume(returning: row) }
}

actor ControlledHealth {
    private var pending: [String: CheckedContinuation<StationHealth.Status, Never>] = [:]
    func probe(_ url: String) async -> StationHealth.Status { await withCheckedContinuation { pending[url] = $0 } }
    func has(_ url: String) -> Bool { pending[url] != nil }
    func respond(_ url: String, status: StationHealth.Status) { pending.removeValue(forKey: url)!.resume(returning: status) }
}

@main
struct StationRepairHarness {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeBaby-Repair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = UUID(), otherOrigin = UUID()
        let old = Station(name: "Mein eigener Name", url: "https://example.com/old", enabled: false, favorite: true, radioBrowserID: origin)
        let row = makeRow(stationuuid: origin.uuidString.lowercased(), name: "Katalogname", url: "https://example.com/new?Case=Value")
        let proposal = try StationURLRepairProposal(station: old, catalog: row)
        let store = Store(directory: root, seedURL: nil)
        try store.add(old)
        try store.saveGroup(name: "Eigene Gruppe")
        let group = store.groups[0].id
        try store.update(old, groupIDs: [group]); try store.setQuickSlot(1, stationID: old.id)
        let bytesBefore = try Data(contentsOf: store.stationsURL)
        let before = store.stations
        let model = StationRepairModel(client: FixedOrigin(row: row))
        model.load(old); await wait { if case .proposal = model.state { return true }; return false }
        model.cancel()
        let bytesAfterCancel = try Data(contentsOf: store.stationsURL)
        check(store.stations == before && bytesAfterCancel == bytesBefore, "Vorschau oder Abbruch schreibt Sender")
        var renamed = old; renamed.name = "Neuer eigener Name"; renamed.favorite = false
        try store.update(renamed)
        try store.applyURLRepair(proposal)
        let repaired = store.stations.first { $0.id == old.id }!
        renamed.url = proposal.newURL
        check(repaired == renamed && store.groups[0].stationIDs == [old.id] && store.quickSlots[1] == old.id,
              "Reparatur überschreibt lokale Identität, Namen, Sichtbarkeit, Favoriten, Gruppen oder Schnellplatz")
        let restarted = Store(directory: root, seedURL: nil)
        check(restarted.stations == store.stations && restarted.groups == store.groups && restarted.quickSlots == store.quickSlots, "Reparatur übersteht Neustart nicht")
        do { try store.applyURLRepair(proposal); fatalError("Alte Vorschau überschreibt neue URL") }
        catch StationSaveError.stationChanged { }
        let exported = try JSONDecoder().decode([SeedStation].self, from: store.exportData()!)
        check(exported.first { $0.radioBrowserID == origin }?.name == renamed.name, "Export verliert Herkunft")
        let imported = Store(directory: root.appendingPathComponent("import"), seedURL: nil)
        check(imported.importData(store.exportData()!) >= 1 && imported.stations.contains { $0.radioBrowserID == origin }, "Import verliert Herkunft")
        let legacyData = Data("[{\"name\":\"Alt\",\"url\":\"https://example.com/alt\",\"radioBrowserID\":\"ungueltig\"}]".utf8)
        let legacy = try JSONDecoder().decode([Station].self, from: legacyData)[0]
        let legacySeeds = try JSONDecoder().decode([SeedStation].self, from: legacyData)
        check(legacy.radioBrowserID == nil && legacySeeds[0].radioBrowserID == nil, "Altdaten/ungültige Herkunft werden nicht tolerant geladen")
        let noOrigin = StationRepairModel(client: FixedOrigin(row: row)); noOrigin.load(legacy)
        check(noOrigin.state == .noOrigin, "Altdaten werden anhand des Namens zugeordnet")
        let legacyRoot = root.appendingPathComponent("legacy"); try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try legacyData.write(to: legacyRoot.appendingPathComponent("stations.json"))
        let legacyStore = Store(directory: legacyRoot, seedURL: nil)
        check(legacyStore.stations[0].name == "Alt" && legacyStore.stations[0].radioBrowserID == nil, "Migration der alten Senderliste scheitert")
        check(store.addIfNew(name: "Katalogimport", url: "https://example.com/import", radioBrowserID: otherOrigin), "Katalogimport scheitert")
        check(store.stations.last?.radioBrowserID == otherOrigin, "Katalogimport verliert UUID")
        let previousCount = store.stations.count
        check(!store.addIfNew(name: "Gleiche URL", url: renamed.url, radioBrowserID: otherOrigin) && store.stations.count == previousCount && store.stations.first { $0.id == old.id }?.radioBrowserID == origin, "Dublette verändert vorhandene Herkunft")
        let currentProposal = try StationURLRepairProposal(station: repaired, catalog: makeRow(stationuuid: origin.uuidString, name: "Katalog", url: "https://example.com/latest"))
        let held = root.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: store.stationsURL, to: held)
        try FileManager.default.createDirectory(at: store.stationsURL, withIntermediateDirectories: true)
        let stateBeforeFailure = store.stations
        do { try store.applyURLRepair(currentProposal); fatalError("Schreibfehler ignoriert") } catch StationSaveError.persistenceFailed { }
        let expectedBytes = try JSONEncoder.sorted.encode(StationCollection(stations: stateBeforeFailure, groups: store.groups, quickSlots: store.quickSlots))
        let heldBytes = try Data(contentsOf: held)
        check(store.stations == stateBeforeFailure && heldBytes == expectedBytes, "Fehlgeschlagene Speicherung verändert Bestand")
        try FileManager.default.removeItem(at: store.stationsURL); try FileManager.default.moveItem(at: held, to: store.stationsURL)
        var detached = repaired; detached.radioBrowserID = otherOrigin; try store.update(detached)
        do { try store.applyURLRepair(currentProposal); fatalError("Geänderte Herkunft ignoriert") } catch StationSaveError.stationChanged { }
        _ = store.delete(detached)
        do { try store.applyURLRepair(currentProposal); fatalError("Gelöschter Sender wiederhergestellt") } catch StationSaveError.stationNotFound { }
        for unsafe in ["file:///tmp/audio", "ftp://example.com/a", "https://user:password@example.com/a", "https://example.com:70000/a", "https://example.com/a\n", "https://", String(repeating: "a", count: 8193)] {
            do { _ = try StationURLRepairProposal(station: old, catalog: makeRow(stationuuid: origin.uuidString, name: "Katalog", url: unsafe)); fatalError("Unsichere URL akzeptiert") }
            catch StationRepairError.unsafeURL { }
        }
        do { _ = try StationURLRepairProposal(station: old, catalog: makeRow(stationuuid: otherOrigin.uuidString, name: old.name, url: row.url)); fatalError("Ähnlicher Name ersetzt Identität") }
        catch StationRepairError.invalidResponse { }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OriginHTTPFixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = RadioBrowserClient(mirrors: ["https://broken.invalid", "https://working.invalid"], session: session)
        try OriginHTTPFixture.set([row])
        let fetched = try await client.station(id: origin)
        check(fetched == row && OriginHTTPFixture.recorded().count == 2, "UUID-Abfrage oder Failover scheitert")
        let request = OriginHTTPFixture.recorded().last!
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        check(parts.path == "/json/stations/byuuid" && parts.queryItems == [.init(name: "uuids", value: origin.uuidString.lowercased())], "Abfrage verwendet Namen oder falschen UUID-Endpunkt")
        for rows in [[RBStation](), [makeRow(stationuuid: otherOrigin.uuidString, name: old.name, url: row.url)], [row, row]] {
            try OriginHTTPFixture.set(rows)
            if rows.isEmpty { check(try await client.station(id: origin) == nil, "Fehlender Eintrag wird ersetzt") }
            else { do { _ = try await client.station(id: origin); fatalError("Fremde/mehrdeutige Antwort akzeptiert") } catch StationRepairError.invalidResponse { } }
        }
        try OriginHTTPFixture.set([row], delay: 0.3)
        let cancelling = Task { try await client.station(id: origin) }
        try? await Task.sleep(for: .milliseconds(25)); cancelling.cancel()
        do { _ = try await cancelling.value; fatalError("Abbruch ignoriert") } catch is CancellationError { }
        check(OriginHTTPFixture.recorded().count == 1, "Abbruch versucht zweiten Mirror")
        let controlled = ControlledOrigin(); let late = StationRepairModel(client: controlled)
        late.load(old); await waitAsync { await controlled.has(origin) }
        var second = old; second.radioBrowserID = otherOrigin
        late.load(second); await waitAsync { await controlled.has(otherOrigin) }
        await controlled.respond(otherOrigin, row: nil); await wait { late.state == .missing }
        await controlled.respond(origin, row: row); try? await Task.sleep(for: .milliseconds(30))
        check(late.state == .missing, "Alte Antwort ersetzt neue Auswahl")
        late.load(old); await waitAsync { await controlled.has(origin) }; late.cancel()
        await controlled.respond(origin, row: row); try? await Task.sleep(for: .milliseconds(30))
        check(late.state == .idle, "Antwort nach Schließen öffnet Vorschau wieder")
        let healthControl = ControlledHealth(); let health = StationHealth(probe: { await healthControl.probe($0) })
        health.checkAll([old]); await waitAsync { await healthControl.has(old.url) }
        health.checkAll([repaired]); await healthControl.respond(old.url, status: .ok)
        await waitAsync { await healthControl.has(repaired.url) }
        check(health.states[old.id] == .checking, "Alte URL-Prüfung erklärt reparierte Adresse für erreichbar")
        await healthControl.respond(repaired.url, status: .bad("HTTP 404")); await wait { health.states[old.id] == .bad("HTTP 404") }
        print("StationRepairHarness: Migration, Herkunft, Vorschau/Abbruch, UUID-Identität, Persistenzfehler, persönliche Daten, URL-Policy und verspätete Antworten OK")
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }; fatalError("Zustand nicht erreicht")
    }
    static func waitAsync(_ condition: () async -> Bool) async {
        for _ in 0..<400 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }; fatalError("Asynchroner Zustand nicht erreicht")
    }
    static func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) } }
}
struct FixedOrigin: StationOriginFetching {
    let row: RBStation?
    func station(id: UUID) async throws -> RBStation? { row }
}
extension JSONEncoder {
    static var sorted: JSONEncoder { let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; return enc }
}

func makeRow(stationuuid: String, name: String, url: String) -> RBStation {
    RBStation(stationuuid: stationuuid, name: name, url: url, url_resolved: nil, codec: nil, bitrate: nil, country: nil, votes: nil, language: nil, countrycode: nil)
}

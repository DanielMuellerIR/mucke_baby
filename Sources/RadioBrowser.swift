import Foundation

struct RBTag: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let stationcount: Int
    enum CodingKeys: CodingKey { case name, stationcount }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        stationcount = (try? c.decode(Int.self, forKey: .stationcount))
            ?? Int((try? c.decode(String.self, forKey: .stationcount)) ?? "") ?? 0
    }
}

struct RBFacet: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let stationcount: Int
    let iso_3166_1: String?
    let iso_639: String?
    enum CodingKeys: CodingKey { case name, stationcount, iso_3166_1, iso_639 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        stationcount = (try? c.decode(Int.self, forKey: .stationcount))
            ?? Int((try? c.decode(String.self, forKey: .stationcount)) ?? "") ?? 0
        iso_3166_1 = try c.decodeIfPresent(String.self, forKey: .iso_3166_1)
        iso_639 = try c.decodeIfPresent(String.self, forKey: .iso_639)
    }
}

struct RBStation: Codable, Identifiable, Equatable, Sendable {
    var id: String { stationuuid }
    let stationuuid: String
    let name: String
    let url: String
    let url_resolved: String?
    let codec: String?
    let bitrate: Int?
    let country: String?
    let votes: Int?
    let language: String?
    let countrycode: String?
    var streamURL: String { url_resolved.flatMap { $0.isEmpty ? nil : $0 } ?? url }
    var isUsable: Bool {
        UUID(uuidString: stationuuid) != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 4096 && streamURL.utf8.count <= 8192 && StreamURLPolicy.validatedURL(streamURL) != nil
    }
    var detail: String {
        [codec, bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil } ?? String(localized: "Bitrate unbekannt"),
         country, language, votes.map { "▲ \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CatalogQuery: Codable, Hashable, Sendable {
    var name = ""
    var countryCode = ""
    var language = ""
    var tag = ""
    var codec = ""
    var minimumBitrate = 0
    var sort = CatalogSort.votes
    var normalized: CatalogQuery {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.countryCode = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        result.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        result.codec = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
    var isValid: Bool {
        [name, language, tag, codec].allSatisfy { $0.count <= 400 }
            && (countryCode.isEmpty || (countryCode.count == 2 && countryCode.allSatisfy { $0.isASCII && $0.isLetter }))
            && (0...1_000_000).contains(minimumBitrate)
    }
    var summary: String {
        let fields = [name, countryCode, language, tag, codec, minimumBitrate > 0 ? "≥ \(minimumBitrate) kbps" : ""]
            .filter { !$0.isEmpty }
        return fields.isEmpty ? String(localized: "Alle Sender") : fields.joined(separator: " · ")
    }
}

enum CatalogSort: String, Codable, CaseIterable, Sendable { case votes, name }
struct CatalogSelection: Codable, Hashable, Sendable {
    var query = CatalogQuery()
    var page = 0
    var isValid: Bool { query.isValid && (0...10_000).contains(page) }
}
struct CatalogPage: Codable, Equatable, Sendable {
    let selection: CatalogSelection
    let stations: [RBStation]
    let hasNext: Bool
    let fetchedAt: Date
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > 86_400 || fetchedAt > now.addingTimeInterval(300) }
}
struct CatalogFacets: Codable, Equatable, Sendable {
    var tags: [RBTag] = []
    var countries: [RBFacet] = []
    var languages: [RBFacet] = []
    var codecs: [RBFacet] = []
}

protocol CatalogFetching: Sendable {
    func search(_ selection: CatalogSelection, at date: Date) async throws -> CatalogPage
    func facets() async throws -> CatalogFacets
}

struct RadioBrowserClient: CatalogFetching {
    var mirrors: [String]
    var session: URLSession
    static var standard: RadioBrowserClient {
        if let fixture = ProcessInfo.processInfo.environment["MUCKE_CATALOG_FIXTURE_URL"] {
            // Lokale HTTP-Fixtures dürfen den Katalog nur auf Loopback umleiten.
            let url = StreamURLPolicy.validatedURL(fixture)
            let allowed = url.map { ["127.0.0.1", "localhost", "::1"].contains($0.host ?? "") && $0.user == nil && $0.password == nil && $0.query == nil && ($0.path.isEmpty || $0.path == "/") } ?? false
            return RadioBrowserClient(mirrors: allowed ? [fixture.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] : [])
        }
        return RadioBrowserClient(mirrors: RadioBrowserAPI.mirrors)
    }
    init(mirrors: [String], session: URLSession = .shared) { self.mirrors = mirrors; self.session = session }

    func search(_ selection: CatalogSelection, at date: Date = Date()) async throws -> CatalogPage {
        guard selection.isValid else { throw URLError(.badURL) }
        let query = selection.query.normalized
        var items = [URLQueryItem(name: "order", value: query.sort.rawValue),
                     .init(name: "reverse", value: query.sort == .votes ? "true" : "false"),
                     .init(name: "hidebroken", value: "true"), .init(name: "limit", value: "51"),
                     .init(name: "offset", value: String(selection.page * 50))]
        for (key, value) in [("name", query.name), ("countrycode", query.countryCode),
                             ("language", query.language), ("tag", query.tag), ("codec", query.codec)] where !value.isEmpty {
            items.append(.init(name: key, value: value))
        }
        if !query.language.isEmpty { items.append(.init(name: "languageExact", value: "true")) }
        if !query.tag.isEmpty { items.append(.init(name: "tagExact", value: "true")) }
        if query.minimumBitrate > 0 { items.append(.init(name: "bitrateMin", value: String(query.minimumBitrate))) }
        let stations: [RBStation] = try await get("/json/stations/search", items)
        var seen = Set<String>()
        let accepted = stations.prefix(50).filter {
            $0.isUsable && seen.insert($0.stationuuid).inserted
        }
        return CatalogPage(selection: CatalogSelection(query: query, page: selection.page), stations: accepted,
                           hasNext: stations.count > 50, fetchedAt: date)
    }

    private func unique<T: Identifiable>(_ rows: [T], limit: Int) -> [T] where T.ID == String {
        var seen = Set<String>()
        return Array(rows.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.id.count <= 400 && seen.insert($0.id).inserted }.prefix(limit))
    }

    func facets() async throws -> CatalogFacets {
        let common = [URLQueryItem(name: "order", value: "stationcount"), .init(name: "reverse", value: "true"), .init(name: "hidebroken", value: "true")]
        async let tags: [RBTag]? = try? get("/json/tags", common + [.init(name: "limit", value: "200")])
        async let countries: [RBFacet]? = try? get("/json/countries", common + [.init(name: "limit", value: "300")])
        async let languages: [RBFacet]? = try? get("/json/languages", common + [.init(name: "limit", value: "200")])
        async let codecs: [RBFacet]? = try? get("/json/codecs", common + [.init(name: "limit", value: "50")])
        let values = await (tags, countries, languages, codecs)
        try Task.checkCancellation()
        guard values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil else { throw URLError(.cannotConnectToHost) }
        return CatalogFacets(tags: unique(values.0 ?? [], limit: 200), countries: unique(values.1 ?? [], limit: 300),
                             languages: unique(values.2 ?? [], limit: 200), codecs: unique(values.3 ?? [], limit: 50))
    }

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var lastError: Error = URLError(.cannotConnectToHost)
        for mirror in mirrors {
            try Task.checkCancellation()
            guard var components = URLComponents(string: mirror + path) else { continue }
            components.queryItems = query
            guard let url = components.url, StreamURLPolicy.validatedURL(url.absoluteString) != nil else { continue }
            var request = URLRequest(url: url)
            request.setValue(RadioBrowserAPI.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 4 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                    if data.count % 4096 == 0 { try Task.checkCancellation() }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
}

enum RadioBrowserAPI {
    static let mirrors = ["https://de2.api.radio-browser.info", "https://de1.api.radio-browser.info", "https://fi1.api.radio-browser.info"]
    static var userAgent: String { "MuckeBaby/\(AppInfo.version)" }
    static func countClick(stationUUID: String) {
        guard let encoded = stationUUID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedStrict),
              let mirror = RadioBrowserClient.standard.mirrors.first,
              let url = URL(string: mirror + "/json/url/" + encoded) else { return }
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

extension CharacterSet {
    static let urlPathAllowedStrict: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()
}

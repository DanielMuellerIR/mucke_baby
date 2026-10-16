import Foundation
import Combine

@MainActor
final class CatalogCache: ObservableObject {
    static let maximumBytes = 2 * 1024 * 1024
    @Published private(set) var pages: [CatalogPage] = []
    @Published private(set) var selection = CatalogSelection()
    @Published private(set) var facets = CatalogFacets()
    @Published private(set) var notice: String?
    private let fileURL: URL
    private var readOnly = false
    private enum CacheError: Error { case incompatible, invalidDocument, tooLarge }
    private struct Header: Decodable { let formatVersion: Int }
    private struct Document: Codable {
        var formatVersion = 1
        var selection: CatalogSelection
        var pages: [CatalogPage]
        var facets: CatalogFacets
    }
    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MuckeBaby", isDirectory: true)
        fileURL = directory.appendingPathComponent("catalog-cache.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maximumBytes { throw CacheError.tooLarge }
            if let header = try JSONFileRecovery.load(Header.self, from: fileURL) {
                guard header.formatVersion == 1 else { throw CacheError.incompatible }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let document = try JSONFileRecovery.load(Document.self, from: fileURL, decoder: decoder) {
                    guard document.selection.isValid, document.pages.count <= 20,
                          document.pages.allSatisfy({ $0.selection.isValid && $0.stations.count <= 50 && $0.stations.allSatisfy(\.isUsable) && Set($0.stations.map(\.id)).count == $0.stations.count }),
                          document.facets.tags.count <= 200, document.facets.countries.count <= 300,
                          document.facets.languages.count <= 200, document.facets.codecs.count <= 50 else { throw CacheError.incompatible }
                    pages = document.pages; selection = document.selection; facets = document.facets
                }
            }
        } catch {
            readOnly = true
            notice = String(localized: "Gespeicherte Katalogdaten sind nicht verfügbar. Neue Ergebnisse können weiter online gesucht werden.")
        }
    }
    func page(for selection: CatalogSelection) -> CatalogPage? { pages.last { $0.selection == selection } }
    func save(page: CatalogPage? = nil, selection: CatalogSelection? = nil, facets: CatalogFacets? = nil) {
        guard !readOnly else { return }
        var next = pages
        if let page { next.removeAll { $0.selection == page.selection }; next.append(page) }
        next = Array(next.suffix(20))
        let selected = selection ?? page?.selection ?? self.selection
        var facets = facets ?? self.facets
        facets.tags = Array(facets.tags.prefix(200)); facets.countries = Array(facets.countries.prefix(300))
        facets.languages = Array(facets.languages.prefix(200)); facets.codecs = Array(facets.codecs.prefix(50))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        do {
            guard selected.isValid, next.allSatisfy({ $0.selection.isValid && $0.stations.count <= 50 && $0.stations.allSatisfy(\.isUsable) && Set($0.stations.map(\.id)).count == $0.stations.count }) else { throw CacheError.invalidDocument }
            var data = try encoder.encode(Document(selection: selected, pages: next, facets: facets))
            while data.count > Self.maximumBytes && next.count > 1 {
                next.removeFirst(); data = try encoder.encode(Document(selection: selected, pages: next, facets: facets))
            }
            guard data.count <= Self.maximumBytes else { throw CacheError.tooLarge }
            try data.write(to: fileURL, options: .atomic)
            self.pages = next; self.selection = selected; self.facets = facets; notice = nil
        } catch {
            notice = String(localized: "Die Katalogauswahl konnte nicht lokal gespeichert werden. Angezeigte Online-Ergebnisse bleiben nutzbar.")
        }
    }
}

@MainActor
final class CatalogModel: ObservableObject {
    @Published var draft = CatalogQuery()
    @Published private(set) var page: CatalogPage?
    @Published private(set) var selection = CatalogSelection()
    @Published private(set) var loading = false
    @Published private(set) var cached = false
    @Published private(set) var unavailable = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var facets = CatalogFacets()
    @Published private(set) var facetsLoading = false
    @Published private(set) var facetsUnavailable = false
    let cache: CatalogCache
    private let client: any CatalogFetching
    private var task: Task<Void, Never>?
    private var requests = LatestRequestGeneration()
    private var cacheSubscription: AnyCancellable?
    init(cache: CatalogCache? = nil, client: any CatalogFetching = RadioBrowserClient.standard) {
        self.cache = cache ?? CatalogCache(); self.client = client
        selection = self.cache.selection; draft = selection.query
        page = self.cache.page(for: selection); cached = page != nil; facets = self.cache.facets
        cacheSubscription = self.cache.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func loadFacets() async {
        facetsLoading = true
        defer { facetsLoading = false }
        do {
            let loaded = try await client.facets()
            guard !Task.isCancelled else { return }
            facetsUnavailable = loaded.tags.isEmpty || loaded.countries.isEmpty || loaded.languages.isEmpty || loaded.codecs.isEmpty
            if !loaded.tags.isEmpty { facets.tags = loaded.tags }
            if !loaded.countries.isEmpty { facets.countries = loaded.countries }
            if !loaded.languages.isEmpty { facets.languages = loaded.languages }
            if !loaded.codecs.isEmpty { facets.codecs = loaded.codecs }
            cache.save(facets: facets)
        } catch { if !Task.isCancelled { facetsUnavailable = true } }
    }
    func search() { load(CatalogSelection(query: draft.normalized)) }
    func showSaved(_ saved: CatalogPage) {
        cancel(); selection = saved.selection; draft = selection.query; page = saved; cached = true
        errorMessage = unavailable ? String(localized: "Katalog nicht erreichbar. Gespeicherte Ergebnisse werden angezeigt; Erreichbarkeit nicht geprüft.") : nil
        cache.save(selection: selection)
    }
    func load(_ target: CatalogSelection) {
        guard target.isValid else {
            errorMessage = String(localized: "Suchtexte dürfen höchstens 400 Zeichen enthalten. Bitte die Auswahl prüfen.")
            return
        }
        task?.cancel()
        let generation = requests.begin()
        selection = target; draft = target.query
        page = cache.page(for: target); cached = page != nil
        errorMessage = nil; loading = true
        task = Task {
            do {
                let loaded = try await client.search(target, at: Date())
                guard !Task.isCancelled, requests.accepts(generation) else { return }
                page = loaded; cached = false; unavailable = false; cache.save(page: loaded)
            } catch {
                guard !Task.isCancelled, requests.accepts(generation) else { return }
                cached = page != nil; unavailable = true
                errorMessage = page != nil ? String(localized: "Katalog nicht erreichbar. Gespeicherte Ergebnisse werden angezeigt; Erreichbarkeit nicht geprüft.")
                    : String(localized: "Katalog nicht erreichbar und keine gespeicherten Ergebnisse für diese Auswahl.")
                cache.save(selection: target)
            }
            guard requests.accepts(generation) else { return }
            loading = false; task = nil
        }
    }
    func cancel() { task?.cancel(); task = nil; requests.invalidate(); loading = false }
}

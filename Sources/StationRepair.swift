import Foundation
import Combine

protocol StationOriginFetching: Sendable {
    func station(id: UUID) async throws -> RBStation?
}

enum StationRepairError: Error {
    case invalidResponse
    case unsafeURL

    var message: String {
        switch self {
        case .invalidResponse:
            return String(localized: "Die Katalogantwort gehört nicht eindeutig zu diesem Sender. Es wurde nichts geändert.")
        case .unsafeURL:
            return String(localized: "Der Katalog enthält keine sichere HTTP- oder HTTPS-Adresse ohne Zugangsdaten. Es wurde nichts geändert.")
        }
    }
}

struct StationURLRepairProposal: Equatable {
    let stationID: UUID
    let radioBrowserID: UUID
    let oldURL: String
    let newURL: String
    let catalogName: String

    init(station: Station, catalog: RBStation) throws {
        guard let origin = station.radioBrowserID, UUID(uuidString: catalog.stationuuid) == origin,
              !catalog.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              catalog.name.utf8.count <= 4096 else { throw StationRepairError.invalidResponse }
        let raw = catalog.streamURL
        guard raw.utf8.count <= 8192, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = StreamURLPolicy.validatedURL(raw), url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw StationRepairError.unsafeURL }
        stationID = station.id
        radioBrowserID = origin
        oldURL = station.url
        newURL = url.absoluteString
        catalogName = catalog.name
    }

    var isChanged: Bool { StationURLIdentity(oldURL) != StationURLIdentity(newURL) }
}

@MainActor
final class StationRepairModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, noOrigin, missing, unchanged
        case proposal(StationURLRepairProposal)
        case failed(String)
    }
    @Published private(set) var state = State.idle
    private let client: any StationOriginFetching
    private var task: Task<Void, Never>?
    private var requests = LatestRequestGeneration()

    init(client: any StationOriginFetching = RadioBrowserClient.standard) { self.client = client }

    func load(_ station: Station) {
        cancel()
        guard let origin = station.radioBrowserID else { state = .noOrigin; return }
        let generation = requests.begin()
        let client = client
        state = .loading
        task = Task { [weak self] in
            do {
                let row = try await client.station(id: origin)
                try Task.checkCancellation()
                guard let self, self.requests.accepts(generation) else { return }
                guard let row else { self.state = .missing; return }
                let proposal = try StationURLRepairProposal(station: station, catalog: row)
                self.state = proposal.isChanged ? .proposal(proposal) : .unchanged
            } catch {
                guard !Task.isCancelled, let self, self.requests.accepts(generation) else { return }
                self.state = .failed((error as? StationRepairError)?.message
                    ?? String(localized: "Der Katalog ist gerade nicht erreichbar oder liefert keine lesbare Antwort. Bitte erneut versuchen."))
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        requests.invalidate()
        state = .idle
    }
}

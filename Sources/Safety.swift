import Foundation

/// Zentrale Vertrauensgrenze fuer Stream- und Playlist-URLs.
///
/// VLC versteht neben Webstreams auch lokale und weitere Protokolle. Externe
/// Katalog-/Playlist-Daten duerfen deshalb ausschliesslich syntaktisch gueltige
/// HTTP(S)-URLs mit einem Host bis zum Player durchreichen.
enum StreamURLPolicy {
    static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.url
    }
}

/// Vergleichsschluessel fuer Sender-Dubletten.
///
/// Nur die laut URL-Standard case-insensitiven Teile (Schema und Host) werden
/// casefolded. Pfad und Query bleiben byte-/case-sensitiv. Der leere Root-Pfad
/// und `/` gelten bewusst als gleich; HTTP(S)-Defaultports ebenso.
struct StationURLIdentity: Hashable {
    let scheme: String
    let host: String
    let port: Int?
    let user: String?
    let password: String?
    let path: String
    let query: String?
    let fragment: String?

    init?(_ raw: String) {
        guard let url = StreamURLPolicy.validatedURL(raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host
        else { return nil }

        self.scheme = scheme
        self.host = host
        self.port = components.port
        self.user = components.percentEncodedUser
        self.password = components.percentEncodedPassword
        self.path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        self.query = components.percentEncodedQuery
        self.fragment = components.percentEncodedFragment
    }
}

/// Monotone Generation fuer asynchrone Requests. Nur die zuletzt begonnene
/// Operation darf gemeinsam genutzten UI-Zustand publizieren.
struct LatestRequestGeneration {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}

enum PreviewToggleAction: Equatable {
    case replace(generation: UInt64)
    case stop(generation: UInt64)
}

/// Testbarer Zustandskern des Preview-Wechsels. Ein Wechsel A -> B liefert
/// ausdruecklich `.replace`, nie `.stop`; spaete Resolver-Antworten von A werden
/// durch die Generation verworfen.
struct PreviewSwitchCoordinator {
    private(set) var currentID: String?
    private var requests = LatestRequestGeneration()

    mutating func toggle(stationID: String) -> PreviewToggleAction {
        let generation = requests.begin()
        if currentID == stationID {
            currentID = nil
            return .stop(generation: generation)
        }
        currentID = stationID
        return .replace(generation: generation)
    }

    @discardableResult
    mutating func stop() -> UInt64 {
        requests.invalidate()
        currentID = nil
        return requests.current
    }

    func accepts(_ generation: UInt64, stationID: String) -> Bool {
        requests.accepts(generation) && currentID == stationID
    }
}

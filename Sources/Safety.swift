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

    /// Log-sichere Darstellung einer Stream-URL: nur Schema, Host und Port.
    /// Benutzerinfo (user:passwort@), Query und Fragment koennen Passwoerter,
    /// Tokens oder signierte Streamparameter tragen — und manche Anbieter legen
    /// den Zugangstoken mitten in den PFAD (…/token/GEHEIM/stream). Nichts davon
    /// gehoert ins Unified Log, erst recht nicht mit `privacy: .public`. Ein
    /// weggelassener Pfad wird als "/…" angedeutet, damit im Log sichtbar bleibt,
    /// dass die URL mehr als nur den Host hatte. Fuer die Diagnose steht der
    /// Sendername ohnehin in derselben Logzeile.
    static func redactedForLog(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<url>"
        }
        let path = components.percentEncodedPath
        let hadPath = !path.isEmpty && path != "/"
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        guard let base = components.string else { return "<url>" }
        return hadPath ? base + "/…" : base
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
    // Bewusst ohne Generation: Der Stop-Pfad wertet sie nirgends aus — ein
    // mitgefuehrter, nie gelesener Wert wuerde einen Schutz nur vortaeuschen.
    case stop
}

/// Testbarer Zustandskern des Preview-Wechsels. Ein Wechsel A -> B liefert
/// ausdruecklich `.replace`, nie `.stop`; spaete Resolver-Antworten von A werden
/// durch die Generation verworfen.
struct PreviewSwitchCoordinator {
    private(set) var currentID: String?
    /// true, sobald fuer die aktuelle Auswahl wirklich ein Medium im Player haengt.
    /// Vorher gehoeren Player-Ereignisse noch zum vorherigen Sender: Beim Wechsel
    /// A -> B spielt A im gemeinsamen VLC-Player weiter, waehrend B erst aufgeloest
    /// wird. Ein spaeter Fehler von A darf B weder als gescheitert markieren noch
    /// dessen Start verhindern.
    private(set) var hasInstalledMedia = false
    private var requests = LatestRequestGeneration()

    mutating func toggle(stationID: String) -> PreviewToggleAction {
        let generation = requests.begin()
        hasInstalledMedia = false
        if currentID == stationID {
            currentID = nil
            return .stop
        }
        currentID = stationID
        return .replace(generation: generation)
    }

    /// Meldet, dass das Medium dieser Generation jetzt im Player laeuft. Eine
    /// ueberholte Generation bleibt wirkungslos.
    @discardableResult
    mutating func mediaInstalled(generation: UInt64, stationID: String) -> Bool {
        guard accepts(generation, stationID: stationID) else { return false }
        hasInstalledMedia = true
        return true
    }

    /// Terminaler Player-Zustand (.ended/.stopped): Der Stream ist von selbst zu
    /// Ende oder abgerissen. `isLoading` == true heisst, dass gerade ein Wechsel
    /// laeuft — dann stammt das Ereignis noch vom vorherigen Medium. Sonst wird der
    /// Koordinator zurueckgesetzt; er hielte den beendeten Sender sonst fest, und
    /// der naechste Klick auf denselben Sender lieferte .stop statt eines Neustarts
    /// (der Sender startete erst beim zweiten Klick wieder). Rueckgabe true: Die
    /// Oberflaeche muss den laufenden Sender jetzt loeschen.
    mutating func finishTerminal(isLoading: Bool) -> Bool {
        guard currentID != nil, !isLoading else { return false }
        stop()
        return true
    }

    @discardableResult
    mutating func stop() -> UInt64 {
        requests.invalidate()
        currentID = nil
        hasInstalledMedia = false
        return requests.current
    }

    func accepts(_ generation: UInt64, stationID: String) -> Bool {
        requests.accepts(generation) && currentID == stationID
    }
}

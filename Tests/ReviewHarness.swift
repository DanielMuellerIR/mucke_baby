import Foundation

@main
enum ReviewHarness {
    // async, damit der echte Produktionspfad PlaylistResolver.resolve gegen
    // lokale HTTP-Fixtures laufen kann (nicht nur der Parser firstMediaURL).
    static func main() async throws {
        try testRecordingDeletionInTemporaryDirectory()
        try testRecordingIndexSafety()
        try testRecordingDeletionSkipsDirectories()
        testURLPolicyAndIdentity()
        testLatestRequestWins()
        testPreviewSwitchDoesNotStopReplacement()
        testTerminalTransitionAllowsRestart()
        testPlayerEventsBelongToInstalledMedium()
        testNeedsResolutionClassifiesByPath()
        await testResolveAgainstLocalFixtures()
        print("ReviewHarness: OK")
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func testRecordingDeletionInTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuckeBaby-Review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // minimumFreeBytes -1 statt 0: hasSpace() verlangt strikt `free > minimum`,
        // und in eingeschraenkten (CI-/Agenten-)Umgebungen darf die gemeldete
        // Kapazitaet zulaessigerweise 0 sein — mit 0 waere der Test dort rot,
        // obwohl der Recorder korrekt arbeitet.
        let recorder = Recorder(directory: directory, minimumFreeBytes: -1)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.begin(station: "Test", contentType: "audio/mpeg", at: start)
        recorder.write(Data([0x01, 0x02, 0x03]))
        recorder.end(at: start.addingTimeInterval(10))
        recorder.flush()

        let completed = recorder.snapshot()
        check(completed.count == 1 && completed[0].end != nil,
              "abgeschlossene Testaufnahme fehlt")
        let completedURL = directory.appendingPathComponent(completed[0].file)
        check(FileManager.default.fileExists(atPath: completedURL.path),
              "Testaufnahme wurde nicht angelegt")

        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().isEmpty, "abgeschlossene Aufnahme blieb im Index")
        check(!FileManager.default.fileExists(atPath: completedURL.path),
              "abgeschlossene Aufnahme blieb auf dem Datentraeger")

        recorder.begin(station: "Laufend", contentType: "audio/aac", at: start)
        recorder.write(Data([0x04]))
        recorder.flush()
        let active = recorder.snapshot()
        check(active.count == 1 && active[0].end == nil,
              "laufende Testaufnahme fehlt")
        let activeURL = directory.appendingPathComponent(active[0].file)

        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().count == 1 && recorder.snapshot()[0].end == nil,
              "laufende Aufnahme wurde aus dem Index geloescht")
        check(FileManager.default.fileExists(atPath: activeURL.path),
              "laufende Aufnahme-Datei wurde geloescht")
        recorder.end(at: start.addingTimeInterval(10))
        recorder.flush()
    }

    // Regression zu zwei Review-Funden am Index (recordings-index.json ist von
    // aussen editier-/restaurierbar): 1. Ein "../"-Dateiname darf "Alle
    // Aufnahmen loeschen" nie aus dem Aufnahmeordner herausfuehren. 2. Ein
    // fehlgeschlagenes Loeschen darf den Eintrag nicht aus dem Index werfen
    // (die Datei waere sonst verwaist und ueber die App nicht mehr erreichbar).
    private static func testRecordingIndexSafety() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("MuckeBaby-Review-\(UUID().uuidString)", isDirectory: true)
        let recDir = sandbox.appendingPathComponent("Aufnahmen", isDirectory: true)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        // 1. Traversal: Opferdatei liegt AUSSERHALB des Aufnahmeordners (aber
        //    noch in unserer Test-Sandbox), der Index zeigt per "../" darauf.
        let victim = sandbox.appendingPathComponent("victim.txt")
        try Data("wichtig".utf8).write(to: victim)
        let indexJSON = """
        [{"id":"11111111-1111-1111-1111-111111111111","file":"../victim.txt",\
        "station":"Manipuliert","start":"2023-11-14T22:13:20Z",\
        "end":"2023-11-14T22:13:30Z","ext":"mp3"}]
        """
        try Data(indexJSON.utf8).write(to: recDir.appendingPathComponent("recordings-index.json"))

        let recorder = Recorder(directory: recDir, minimumFreeBytes: -1)
        check(recorder.snapshot().isEmpty,
              "Indexeintrag mit Pfad-Traversal wurde nicht beim Laden verworfen")
        recorder.deleteAllCompleted()
        recorder.flush()
        check(fm.fileExists(atPath: victim.path),
              "Loeschen folgte einem ../-Indexeintrag aus dem Aufnahmeordner hinaus")

        // 2. Fehlgeschlagenes Loeschen: Ordner voruebergehend schreibschuetzen.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.begin(station: "Gesperrt", contentType: "audio/mpeg", at: start)
        recorder.write(Data([0x0A]))
        recorder.end(at: start.addingTimeInterval(5))
        recorder.flush()
        let lockedClips = recorder.snapshot()
        check(lockedClips.count == 1 && lockedClips[0].end != nil, "Testaufnahme fehlt")
        let lockedURL = recDir.appendingPathComponent(lockedClips[0].file)

        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recDir.path)
        recorder.deleteAllCompleted()
        recorder.flush()
        // Rechte sofort zuruecksetzen, damit das Sandbox-Cleanup immer klappt.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recDir.path)
        check(recorder.snapshot().count == 1,
              "nicht loeschbare Aufnahme verschwand trotzdem aus dem Index")
        check(fm.fileExists(atPath: lockedURL.path),
              "Datei fehlt, obwohl das Loeschen scheitern sollte")

        // Nach Freigabe klappt das Loeschen und der Index wird leer.
        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().isEmpty, "Aufnahme blieb nach Freigabe im Index")
        check(!fm.fileExists(atPath: lockedURL.path), "Datei blieb nach Freigabe liegen")

        // 3. Bereits fehlende Datei zaehlt als geloescht: Eintrag darf raus.
        recorder.begin(station: "Weg", contentType: "audio/mpeg", at: start)
        recorder.write(Data([0x0B]))
        recorder.end(at: start.addingTimeInterval(5))
        recorder.flush()
        let goneClips = recorder.snapshot()
        check(goneClips.count == 1, "zweite Testaufnahme fehlt")
        try fm.removeItem(at: recDir.appendingPathComponent(goneClips[0].file))
        recorder.deleteAllCompleted()
        recorder.flush()
        check(recorder.snapshot().isEmpty,
              "Eintrag ohne Datei blieb nach dem Loeschen im Index")
    }

    // Regression zum Review-Fund "Unterordner statt Aufnahme": Ein schlichter Name
    // ohne "/" besteht die Namenspruefung, kann im Aufnahmeordner aber ein
    // Verzeichnis sein — removeItem loescht das mitsamt Inhalt. "Alle Aufnahmen
    // loeschen" darf nur regulaere Dateien anfassen.
    private static func testRecordingDeletionSkipsDirectories() throws {
        let fm = FileManager.default
        let recDir = fm.temporaryDirectory
            .appendingPathComponent("MuckeBaby-Review-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: recDir) }

        // Unterordner mit Nutzerdaten, auf den ein manipulierter Index zeigt.
        let folder = recDir.appendingPathComponent("Eigene Mitschnitte", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("wichtig.mp3")
        try Data("wichtig".utf8).write(to: inside)
        let indexJSON = """
        [{"id":"22222222-2222-2222-2222-222222222222","file":"Eigene Mitschnitte",\
        "station":"Manipuliert","start":"2023-11-14T22:13:20Z",\
        "end":"2023-11-14T22:13:30Z","ext":"mp3"}]
        """
        try Data(indexJSON.utf8).write(to: recDir.appendingPathComponent("recordings-index.json"))

        let recorder = Recorder(directory: recDir, minimumFreeBytes: -1)
        recorder.deleteAllCompleted()
        recorder.flush()
        check(fm.fileExists(atPath: inside.path),
              "Loeschen hat einen Unterordner samt Inhalt entfernt")
        check(recorder.snapshot().count == 1,
              "abgewiesener Verzeichnis-Eintrag verschwand aus dem Index statt zur Diagnose zu bleiben")
    }

    private static func testURLPolicyAndIdentity() {
        check(StreamURLPolicy.validatedURL("https://Example.COM/Stream?Token=AbC") != nil,
              "gueltige HTTPS-URL abgewiesen")
        check(StreamURLPolicy.validatedURL("http://example.com:80/")?.absoluteString
              == "http://example.com/", "HTTP-Defaultport nicht kanonisiert")
        for invalid in ["file:///etc/passwd", "ftp://example.com/a", "javascript:alert(1)",
                        "https:///ohne-host", "example.com/ohne-schema"] {
            check(StreamURLPolicy.validatedURL(invalid) == nil,
                  "unsichere URL akzeptiert: \(invalid)")
        }

        check(PlaylistResolver.firstMediaURL(in: "[playlist]\nFile1=file:///etc/passwd") == nil,
              "Playlist liess lokales Ziel durch")
        check(PlaylistResolver.firstMediaURL(
            in: "[playlist]\nFile1=https://Example.COM/Stream?Token=AbC"
        )?.absoluteString == "https://example.com/Stream?Token=AbC",
        "Playlist veraenderte case-sensitiven Pfad oder Query")

        // Log-Redaktion: Benutzerinfo, Query, Fragment UND Pfad muessen raus —
        // nur Schema/Host/Port bleiben. Ein ausgelassener Pfad wird angedeutet.
        if let secretURL = URL(string: "https://user:pass@example.com/stream?token=SECRET#frag") {
            let redacted = StreamURLPolicy.redactedForLog(secretURL)
            check(redacted == "https://example.com/…",
                  "Log-Redaktion liess Benutzerinfo/Query/Pfad durch: \(redacted)")
            check(!redacted.contains("SECRET") && !redacted.contains("pass"),
                  "Log-Redaktion enthaelt weiterhin Geheimnisse")
        } else {
            check(false, "Redaktions-Test-URL unparsebar")
        }
        // Manche Anbieter tragen den Zugangstoken IM PFAD. Auch der darf nicht ins
        // Unified Log (dort steht die Zeile dauerhaft und mit privacy: .public).
        if let pathTokenURL = URL(string: "https://example.com:8000/token/GEHEIM/stream.mp3") {
            let redacted = StreamURLPolicy.redactedForLog(pathTokenURL)
            check(redacted == "https://example.com:8000/…",
                  "Log-Redaktion liess den Pfad durch: \(redacted)")
            check(!redacted.contains("GEHEIM"), "Token im Pfad blieb im Log stehen")
        } else {
            check(false, "Pfad-Token-Test-URL unparsebar")
        }
        // Ohne Pfad kein irrefuehrendes "/…".
        if let bareURL = URL(string: "https://example.com/") {
            check(StreamURLPolicy.redactedForLog(bareURL) == "https://example.com",
                  "Root-URL erhielt einen Pfad-Hinweis, obwohl es keinen Pfad gibt")
        } else {
            check(false, "Root-Test-URL unparsebar")
        }

        check(StationURLIdentity("HTTPS://Example.COM/Stream?Token=AbC")
              == StationURLIdentity("https://example.com:443/Stream?Token=AbC"),
              "Schema-/Host-Case oder Defaultport erzeugt falsche Dublette")
        check(StationURLIdentity("https://example.com/Stream")
              != StationURLIdentity("https://example.com/stream"),
              "Pfad wurde faelschlich casefolded")
        check(StationURLIdentity("https://example.com/a?Token=AbC")
              != StationURLIdentity("https://example.com/a?token=AbC"),
              "Query wurde faelschlich casefolded")
        check(StationURLIdentity("http://example.com/a")
              != StationURLIdentity("https://example.com/a"),
              "verschiedene Schemas wurden zusammengelegt")
    }

    private static func testLatestRequestWins() {
        var requests = LatestRequestGeneration()
        let first = requests.begin()
        let second = requests.begin()
        check(!requests.accepts(first), "alter Request blieb schreibberechtigt")
        check(requests.accepts(second), "neuester Request wurde abgewiesen")
        requests.invalidate()
        check(!requests.accepts(second), "abgebrochener Request blieb schreibberechtigt")
    }

    // Regression zum Review-Fund "`.m3u8` irgendwo in der URL umgeht die
    // Playlist-Erkennung": Die Einstufung darf NUR auf dem URL-Pfad beruhen —
    // Query und Host sind bei fremden Katalog-URLs freie Texte.
    private static func testNeedsResolutionClassifiesByPath() {
        func needs(_ s: String) -> Bool {
            guard let url = URL(string: s) else {
                check(false, "Test-URL unparsebar: \(s)")
                return false
            }
            return PlaylistResolver.needsResolution(url)
        }
        // Echte HLS-Pfade gehen direkt an VLC (kein Fetch).
        check(!needs("https://host/master.m3u8"), "HLS-Pfad wurde faelschlich gefetcht")
        check(!needs("https://host/master.m3u8?fallback=.pls"),
              "HLS-Pfad mit .pls-Query wurde faelschlich als Playlist eingestuft")
        // Der Bypass aus dem Review: .pls-Pfad mit ".m3u8" im Query-Koeder.
        check(needs("https://host/list.pls?hint=.m3u8"),
              ".pls-Playlist mit .m3u8-Query umging die Aufloesung")
        check(needs("https://host/list.m3u?x=.m3u8"),
              ".m3u-Playlist mit .m3u8-Query umging die Aufloesung")
        // Playlist-Marker ausserhalb des Pfads duerfen NICHT als Playlist gelten.
        check(!needs("https://radio.pls.example.com/stream"),
              "'.pls' im Hostnamen wurde als Playlist eingestuft")
        check(!needs("https://host/stream?list=.pls"),
              "'.pls' im Query wurde als Playlist eingestuft")
        // Bestehende Faelle bleiben erhalten.
        check(!needs("https://host/tunein-aac-hd-pls"),
              "Direktstream mit 'pls' im Namen wurde als Playlist eingestuft")
        check(needs("https://host/Tune.ashx?id=1"), "Tune.ashx wurde nicht aufgeloest")
        check(needs("https://host/pls/station"), "/pls-Pfad wurde nicht aufgeloest")
        check(needs("https://host/radio.m3u"), ".m3u-Endung wurde nicht aufgeloest")
        check(needs("https://host/radio.asx"), ".asx-Endung wurde nicht aufgeloest")
        check(needs("https://host/radio.xspf"), ".xspf-Endung wurde nicht aufgeloest")
    }

    // Der asynchrone Produktionspfad resolve() gegen lokale HTTP-Fixtures:
    // Klassifikation, Rekursion, Redirect, fail-closed bei unsicheren Zielen,
    // Binaerinhalt, Schleifen und Fetch-Fehlern. Kein Kontakt nach aussen.
    private static func testResolveAgainstLocalFixtures() async {
        guard let server = FixtureServer() else {
            check(false, "Fixture-Server startete nicht")
            return
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let direct = "\(base)/direct.mp3"
        server.responses = [
            // Der Review-Bypass: .pls-Pfad, ".m3u8" nur im Query.
            "/list.pls?hint=.m3u8": .init(body: "[playlist]\nFile1=\(direct)\n"),
            "/plain.pls": .init(body: "[playlist]\nFile1=\(direct)\n"),
            "/nested.m3u": .init(body: "\(base)/plain.pls\n"),
            "/redirect.pls": .init(status: "302 Found",
                                   headers: ["Location: \(base)/plain.pls"], body: ""),
            "/evil.pls": .init(body: "[playlist]\nFile1=file:///etc/passwd\n"),
            "/binary.pls": .init(body: "\u{01}\u{02}\u{03}kein-playlist-inhalt"),
            "/loop.m3u": .init(body: "\(base)/loop.m3u\n"),
            // Verschachtelungskette a->b->c->d->e (Tiefenlimit 3 muss greifen).
            "/a.m3u": .init(body: "\(base)/b.m3u\n"),
            "/b.m3u": .init(body: "\(base)/c.m3u\n"),
            "/c.m3u": .init(body: "\(base)/d.m3u\n"),
            "/d.m3u": .init(body: "\(base)/e.m3u\n"),
            "/e.m3u": .init(body: "\(direct)\n"),
        ]

        // check() nimmt eine synchrone Autoclosure -> Ergebnisse zuerst awaiten.
        let bypass = await PlaylistResolver.resolve("\(base)/list.pls?hint=.m3u8")
        check(bypass?.absoluteString == direct,
              ".pls mit .m3u8-Query wurde nicht zur Stream-URL aufgeloest (Bypass)")
        let plain = await PlaylistResolver.resolve("\(base)/plain.pls")
        check(plain?.absoluteString == direct, "einfache PLS-Playlist wurde nicht aufgeloest")
        let nested = await PlaylistResolver.resolve("\(base)/nested.m3u")
        check(nested?.absoluteString == direct,
              "verschachtelte Playlist wurde nicht rekursiv aufgeloest")
        let redirected = await PlaylistResolver.resolve("\(base)/redirect.pls")
        check(redirected?.absoluteString == direct, "Redirect auf Playlist wurde nicht verfolgt")
        let directStream = await PlaylistResolver.resolve("\(base)/direct.mp3")
        check(directStream?.absoluteString == direct,
              "Direktstream ohne Playlist-Endung wurde nicht durchgereicht")
        let evil = await PlaylistResolver.resolve("\(base)/evil.pls")
        check(evil == nil, "Playlist mit lokalem file:-Ziel wurde nicht fail-closed verworfen")
        let binary = await PlaylistResolver.resolve("\(base)/binary.pls")
        check(binary == nil, "Binaerinhalt unter Playlist-Endung wurde nicht verworfen")
        let loop = await PlaylistResolver.resolve("\(base)/loop.m3u")
        check(loop == nil, "selbstreferenzielle Playlist wurde nicht verworfen")
        let tooDeep = await PlaylistResolver.resolve("\(base)/a.m3u")
        check(tooDeep == nil, "Verschachtelungstiefe > 3 wurde nicht verworfen")
        // Fetch-Fehler (Port 1 lehnt Verbindungen ab) => fail closed.
        let unreachable = await PlaylistResolver.resolve("http://127.0.0.1:1/x.pls")
        check(unreachable == nil, "Fetch-Fehler lieferte trotzdem eine URL")
    }

    private static func testPreviewSwitchDoesNotStopReplacement() {
        var preview = PreviewSwitchCoordinator()
        guard case let .replace(first) = preview.toggle(stationID: "A") else {
            check(false, "erste Vorschau war kein Replace")
            return
        }
        guard case let .replace(second) = preview.toggle(stationID: "B") else {
            check(false, "Wechsel A -> B loeste Stop statt Replace aus")
            return
        }
        check(!preview.accepts(first, stationID: "A"), "spaete A-Antwort blieb gueltig")
        check(preview.accepts(second, stationID: "B"), "aktuelle B-Antwort wurde abgewiesen")
        guard case .stop = preview.toggle(stationID: "B") else {
            check(false, "zweiter Klick auf B stoppte die Vorschau nicht")
            return
        }
    }

    // Ablauf "Start, Stream endet von selbst, erneuter Start desselben Senders":
    // Nach dem Terminaluebergang muss der naechste Klick auf denselben Sender
    // wieder .replace liefern (frueher blieb der Koordinator auf dem beendeten
    // Sender stehen und der erste Klick lieferte .stop). Geprueft wird genau die
    // Methode, die PreviewPlayer.handleState() bei .ended/.stopped aufruft —
    // ein direkter stop() im Test wuerde die Verdrahtung nicht absichern.
    private static func testTerminalTransitionAllowsRestart() {
        var preview = PreviewSwitchCoordinator()
        guard case let .replace(generation) = preview.toggle(stationID: "A") else {
            check(false, "Start der Vorschau war kein Replace")
            return
        }
        // Bevor das Medium installiert ist, gehoert ein Terminalereignis noch zum alten Medium.
        check(!preview.finishTerminal(),
              "Terminalereignis vor Medieninstallation raeumte die laufende Vorschau ab")
        preview.mediaInstalled(generation: generation, stationID: "A")
        check(preview.finishTerminal(),
              "Streamende raeumte die installierte Vorschau nicht ab")
        check(!preview.finishTerminal(),
              "zweites Terminalereignis meldete erneut einen Aufraeumbedarf")
        guard case .replace = preview.toggle(stationID: "A") else {
            check(false, "Neustart desselben Senders nach Streamende lieferte kein Replace")
            return
        }

        // Wechsel A -> B: Altes Terminalereignis waehrend B noch laedt darf B nicht invalidieren.
        preview.mediaInstalled(generation: generation, stationID: "A")
        guard case let .replace(secondGen) = preview.toggle(stationID: "B") else {
            check(false, "Wechsel A -> B war kein Replace")
            return
        }
        check(!preview.finishTerminal(),
              "spaetes Terminalereignis waehrend B laedt invalidierte B")
        check(preview.accepts(secondGen, stationID: "B"),
              "Generation von B wurde durch spaetes Terminalereignis zerstoert")
    }

    // Regression zum Review-Fund "spaeter Fehler von A trifft B": Beim Wechsel
    // A -> B haengt A bis zur fertigen Aufloesung von B im gemeinsamen Player.
    // Erst wenn das Medium von B wirklich installiert ist, gehoeren Player-
    // Ereignisse zu B — sonst wuerde ein Fehler von A den Nachfolger als
    // gescheitert markieren und dessen Start verhindern.
    private static func testPlayerEventsBelongToInstalledMedium() {
        var preview = PreviewSwitchCoordinator()
        guard case let .replace(first) = preview.toggle(stationID: "A") else {
            check(false, "Start der Vorschau war kein Replace")
            return
        }
        preview.mediaInstalled(generation: first, stationID: "A")
        check(preview.hasInstalledMedia, "installiertes Medium wurde nicht vermerkt")

        guard case let .replace(second) = preview.toggle(stationID: "B") else {
            check(false, "Wechsel A -> B war kein Replace")
            return
        }
        check(!preview.hasInstalledMedia,
              "waehrend der Aufloesung von B galten Player-Ereignisse schon als B")
        // Spaete Installationsmeldung der ueberholten Generation von A: wirkungslos.
        check(!preview.mediaInstalled(generation: first, stationID: "A"),
              "ueberholte Generation durfte das Medium installieren")
        check(!preview.hasInstalledMedia, "ueberholte Generation setzte hasInstalledMedia")

        preview.mediaInstalled(generation: second, stationID: "B")
        check(preview.hasInstalledMedia, "Medium von B wurde nicht vermerkt")
    }
}

// Mini-HTTP-Server fuer die Playlist-Aufloesungs-Tests: liefert vorbereitete
// Antworten ausschliesslich auf 127.0.0.1 (kein Netz nach aussen). Die Tests
// fragen seriell an — eine einfache accept-Schleife auf einer Hintergrund-Queue
// genuegt. `responses` wird VOR der ersten Anfrage einmalig gesetzt.
final class FixtureServer: @unchecked Sendable {
    struct Response {
        var status = "200 OK"
        var headers: [String] = []
        var body = ""
    }

    var responses: [String: Response] = [:]
    let port: UInt16

    private let fd: Int32
    private let queue = DispatchQueue(label: "review-harness.fixture-server")

    init?() {
        // Lokale Variable statt self.fd: In Closures darf self erst nach
        // vollstaendiger Initialisierung aller Member benutzt werden.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // Port 0 = System waehlt freien Port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else { close(sock); return nil }
        // Tatsaechlich zugewiesenen Port auslesen.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        guard got == 0 else { close(sock); return nil }
        fd = sock
        port = UInt16(bigEndian: actual.sin_port)
        queue.async { [self] in acceptLoop() }
    }

    func stop() { close(fd) }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }            // Socket geschlossen -> Server-Ende
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        // Timeout, damit eine Verbindung ohne (vollstaendige) Anfrage die serielle
        // accept-Schleife nicht dauerhaft blockiert.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Bis zum Ende der Request-Header lesen: TCP garantiert nicht, dass ein
        // einzelnes read() schon die ganze Request-Zeile liefert — ein Teil-Lesen
        // haette sonst sporadisch eine 404-Antwort erzeugt.
        let headerEnd = Data("\r\n\r\n".utf8)
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while raw.range(of: headerEnd) == nil && raw.count < 64 * 1024 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
        }
        guard !raw.isEmpty,
              let request = String(data: raw, encoding: .utf8),
              let line = request.split(separator: "\r\n").first else { return }
        // Request-Line: "GET /pfad?query HTTP/1.1" -> Ziel inkl. Query matchen.
        let parts = line.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : ""
        let resp = responses[target]
            ?? Response(status: "404 Not Found", headers: [], body: "not found")
        var out = "HTTP/1.1 \(resp.status)\r\n"
        out += "Content-Length: \(resp.body.utf8.count)\r\n"
        out += "Connection: close\r\n"
        for header in resp.headers { out += header + "\r\n" }
        out += "\r\n" + resp.body
        // Antwort in einer Schleife schreiben: write() darf weniger Bytes annehmen
        // als angeboten. Ein Teil-Schreiben haette die Playlist abgeschnitten
        // ausgeliefert und den Resolver-Test sporadisch rot gemacht.
        let bytes = Array(out.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBufferPointer {
                write(client, $0.baseAddress! + sent, bytes.count - sent)
            }
            if written <= 0 { break }
            sent += written
        }
    }
}

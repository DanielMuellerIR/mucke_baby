import Foundation

// Liest den ICY-Live-Titel (StreamTitle) direkt aus dem Shoutcast/Icecast-Stream
// (VLCKit gibt ihn nicht heraus) UND liefert die reinen Audio-Bytes fuer den
// Recorder. Eine Verbindung mit `Icy-MetaData: 1`:
//  - `icy-metaint: N` => N Audio-Bytes, dann 1 Laengenbyte L, dann L*16 Bytes
//    Metadaten "StreamTitle='Interpret - Titel';…". Audio-Bytes => onAudio.
//  - kein `icy-metaint` => reiner Audio-Stream; nur weiterlesen, wenn fuer die
//    Aufnahme gebraucht (allowAudioOnly), sonst abbrechen.
// Veränderlicher Zustand gehört der Parser-Queue. Senken können ihre Arbeit
// weiterreichen, dürfen den Reader jedoch nicht synchron erneut aufrufen.
final class ICYMetadataReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onTitle: (@Sendable (String, Date) -> Void)? {
        get { q.sync { titleHandler } }
        set { q.sync { titleHandler = newValue } }
    }
    private var titleHandler: (@Sendable (String, Date) -> Void)?

    // Pro-Session-Senken (Audiobeginn / Songgrenze / Audio-Bytes / Ende). Werden ueber start() gesetzt und
    // NUR auf `q` gelesen/geschrieben — frueher waren es offene `var`, die der Main-Thread
    // (RadioPlayer.start) beim Senderwechsel neu zuwies, waehrend eine noch auslaufende
    // Delegate-Callback der ALTEN Session sie las (Race auf der Closure-Referenz).
    private var onStart: (@Sendable (String?, Date) -> Void)?
    private var onBoundary: (@Sendable (String, Date) -> Void)?
    private var onAudio: (@Sendable (Data) -> Void)?
    private var onAudioAt: (@Sendable (Data, Date, TimeInterval) -> Void)?
    private var onCompletion: (@Sendable (Date) -> Void)?
    private var onUnsupportedFormat: (@Sendable (String) -> Void)?
    private var contentType: String?
    private var lastAudioAt: Date?

    private var session: URLSession?
    private var parserTask: URLSessionDataTask?
    private var generation = UUID()

    // Serielle Queue: serialisiert ALLEN veraenderlichen Parser-/Senken-Zustand. Die
    // URLSession-Delegate-Callbacks laufen auf einer eigenen Hintergrund-Queue; ihre
    // Rumpf-Arbeit wird auf `q` gehopst, stop() wartet den Reset auf derselben Queue ab. So koennen sich
    // weder Main-vs-Delegate noch alte-vs-neue Session in die Quere kommen.
    private let q = DispatchQueue(label: "de.danielmuller.macradio.icy")

    private var allowAudioOnly = false        // nur auf q

    // Parser-Zustand (nur auf `q` angefasst).
    private var metaint = 0
    private var audioOnly = false   // Stream ohne ICY-Metadaten
    private var skip = 0
    private var metaLeft = 0
    private var metadata = Data()
    private static let titleStartMarker = Data("StreamTitle='".utf8)
    private static let titleEndMarker = Data("';".utf8)
    private var lastTitle = ""
    private var checkedAudioPrefix = false
    private var rejectedAudio = false
    private var audioPrefix = Data()
    private var prefixReceipt: (Date, TimeInterval)?

    private let configuration: URLSessionConfiguration
    private let titleQueue: DispatchQueue

    init(configuration: URLSessionConfiguration = .ephemeral, titleQueue: DispatchQueue = .main) {
        let copy = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        copy.timeoutIntervalForRequest = 20
        self.configuration = copy
        self.titleQueue = titleQueue
        super.init()
    }

    func start(url: URL, allowAudioOnly: Bool = false,
               onStart: (@Sendable (String?, Date) -> Void)? = nil,
               onBoundary: (@Sendable (String, Date) -> Void)? = nil,
               onAudio: (@Sendable (Data) -> Void)? = nil,
               onAudioAt: (@Sendable (Data, Date, TimeInterval) -> Void)? = nil,
               onCompletion: (@Sendable (Date) -> Void)? = nil,
               onUnsupportedFormat: (@Sendable (String) -> Void)? = nil) {
        q.sync {
            stopOnQueue()
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            request.setValue(AppInfo.streamUserAgent, forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request)
            parserTask = task
            self.allowAudioOnly = allowAudioOnly
            self.onStart = onStart
            self.onBoundary = onBoundary
            self.onAudio = onAudio
            self.onAudioAt = onAudioAt
            self.onCompletion = onCompletion
            self.onUnsupportedFormat = onUnsupportedFormat
            task.resume()
        }
    }

    @discardableResult
    func stop() -> Date? {
        q.sync { stopOnQueue() }
    }

    @discardableResult
    private func stopOnQueue() -> Date? {
        generation = UUID()
        parserTask?.cancel()
        parserTask = nil
        session?.invalidateAndCancel()
        session = nil
        let endedAt = lastAudioAt
        onStart = nil
        onAudio = nil
        onAudioAt = nil
        onBoundary = nil
        onCompletion = nil
        onUnsupportedFormat = nil
        contentType = nil
        lastAudioAt = nil
        metaint = 0
        audioOnly = false
        skip = 0
        metaLeft = 0
        checkedAudioPrefix = false
        rejectedAudio = false
        audioPrefix.removeAll()
        prefixReceipt = nil
        // codereview-ok: removeAll-keepingCapacity-Nuance ist harmlos, kein Verhaltensunterschied im Fehlerfall (2026-07-01)
        metadata.removeAll(keepingCapacity: false)
        lastTitle = ""
        return endedAt
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // Header roh auf dem Aufrufer lesen, die Zustands-Auswertung + Senken-Aufruf auf `q`.
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        let metaintHeader = http?.value(forHTTPHeaderField: "icy-metaint") ?? http?.value(forHTTPHeaderField: "Icy-MetaInt")
        q.async {
            guard self.parserTask === dataTask else {
                completionHandler(.cancel)
                return
            }
            guard let http, (200..<300).contains(http.statusCode) else {
                completionHandler(.cancel)
                return
            }
            self.contentType = contentType
            // HLS-Playlists sind keine Audiobytes. VLC verfolgt ihre Segmente;
            // die ICY-/Dateisenken dürfen weder Manifest noch TS-Daten speichern.
            if StreamCapturePolicy.isHLS(contentType, url: response.url) {
                self.rejectHLS()
                completionHandler(.cancel)
                return
            }
            if let v = metaintHeader, let n = Int(v), n > 0 {
                self.metaint = n
                self.skip = n
                self.audioOnly = false
                completionHandler(.allow)
            } else if self.allowAudioOnly {
                self.audioOnly = true             // keine Metadaten, aber fuer Aufnahme behalten
                completionHandler(.allow)
            } else {
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let receivedAt = Date()
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        q.async {
            guard self.parserTask === dataTask else { return }
            guard !data.isEmpty, self.audioOnly || self.metaint > 0 else { return }
            if self.audioOnly { self.emitAudio(data, at: receivedAt, uptime: receivedUptime); return }
            self.consume(data, at: receivedAt, uptime: receivedUptime)
        }
    }

    private func consume(_ data: Data, at date: Date, uptime: TimeInterval) {
        var audio = Data()
        audio.reserveCapacity(data.count)
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if skip > 0 {
                let length = min(skip, data.endIndex - cursor)
                let end = cursor + length
                audio.append(data[cursor..<end])
                cursor = end
                skip -= length
            } else if metaLeft > 0 {
                let length = min(metaLeft, data.endIndex - cursor)
                let end = cursor + length
                metadata.append(data[cursor..<end])
                cursor = end
                metaLeft -= length
                if metaLeft == 0 {
                    // Die Audiosenken müssen vor dem Titel an der nächsten Framegrenze laufen.
                    emitAudio(audio, at: date, uptime: uptime)
                    audio.removeAll(keepingCapacity: true)
                    parse(metadata, at: date)
                    skip = metaint
                }
            } else {
                metaLeft = Int(data[cursor]) * 16
                cursor += 1
                if metaLeft == 0 { skip = metaint }
                else { metadata.removeAll(keepingCapacity: true) }
            }
        }
        emitAudio(audio, at: date, uptime: uptime)
    }

    private func emitAudio(_ data: Data, at date: Date, uptime: TimeInterval) {
        guard !data.isEmpty, !rejectedAudio else { return }
        if !checkedAudioPrefix {
            let receipt = prefixReceipt ?? (date, uptime)
            prefixReceipt = receipt
            audioPrefix.append(data)
            var candidate = Array(audioPrefix.prefix(48))
            if candidate.starts(with: [0xef, 0xbb, 0xbf]) { candidate.removeFirst(3) }
            while let first = candidate.first, [9, 10, 13, 32].contains(first) { candidate.removeFirst() }
            let marker = Array("#EXTM3U".utf8)
            if candidate.starts(with: marker) {
                rejectHLS()
                parserTask?.cancel()
                return
            }
            if (candidate.isEmpty || marker.starts(with: candidate) || [0xef, 0xbb, 0xbf].starts(with: candidate)),
               audioPrefix.count < 48 { return }
            checkedAudioPrefix = true
            let pending = audioPrefix
            audioPrefix = Data(); prefixReceipt = nil
            deliverAudio(pending, at: receipt.0, uptime: receipt.1)
            return
        }
        deliverAudio(data, at: date, uptime: uptime)
    }

    private func deliverAudio(_ data: Data, at date: Date, uptime: TimeInterval) {
        if lastAudioAt == nil { onStart?(contentType, date) }
        lastAudioAt = date
        onAudio?(data)
        onAudioAt?(data, date, uptime)
    }

    private func rejectHLS() {
        rejectedAudio = true; checkedAudioPrefix = true
        audioPrefix.removeAll(); prefixReceipt = nil
        onStart = nil; onAudio = nil; onAudioAt = nil; onBoundary = nil; onCompletion = nil
        onUnsupportedFormat?(StreamCapturePolicy.hlsContentType)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        q.async {
            guard self.parserTask === task else { return }
            // Hinter den letzten Audio-Bytes einreihen. Ein Timeout nach dem
            // letzten Byte darf keine zusätzliche aufgenommene Zeit erfinden.
            self.onCompletion?(self.lastAudioAt ?? Date())
            self.parserTask = nil
            self.onStart = nil; self.onAudio = nil; self.onAudioAt = nil; self.onBoundary = nil; self.onCompletion = nil
            self.onUnsupportedFormat = nil
        }
        // Stream zu Ende / Fehler / Timeout -> die GERADE beendete Session freigeben
        // (sonst bliebe sie mit ihrer starken Referenz auf self samt Socket offen, bis
        // zufaellig ein externes stop()/start() kommt). Nur die lokale `session` anfassen,
        // NICHT self.session, um eine inzwischen gestartete neue Session nicht zu treffen.
        session.finishTasksAndInvalidate()
    }

    private func parse(_ data: Data, at date: Date) {
        guard !rejectedAudio else { return }
        // Die Marker `StreamTitle='` und `';` sind reines ASCII => direkt in den
        // Roh-Bytes suchen. So gehen die eigentlichen Titel-Bytes unangetastet
        // an den encoding-toleranten Decoder (wichtig fuer Shift-JIS u.ae.).
        guard let start = data.range(of: Self.titleStartMarker)?.upperBound,
              let end = data.range(of: Self.titleEndMarker, in: start..<data.endIndex)?.lowerBound else { return }
        let titleBytes = Array(data[start..<end])
        let title = decodeICY(titleBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != lastTitle else { return }
        lastTitle = title
        // Vor den folgenden Audio-Bytes auf derselben Parser-Queue melden.
        // Ein verzögerter Main-Titel darf den Recorder-Rollover nicht verschieben.
        onBoundary?(title, date)
        let streamGeneration = generation
        titleQueue.async {
            // Ein letzter Titel darf auch nach regulärem Verbindungsende ankommen.
            // Nur ein Stop oder eine neue Verbindung entwertet seine Generation.
            let callback = self.q.sync { self.generation == streamGeneration ? self.titleHandler : nil }
            callback?(title, date)
        }
    }

    // Dekodiert die rohen Titel-Bytes mit einer Fallback-Kette. Viele Sender
    // schicken kein UTF-8: japanische oft Shift-JIS, europaeische gern Latin-1.
    private func decodeICY(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        // 1. UTF-8 — der Standard. Nur akzeptieren, wenn gueltig UND ohne
        //    Replacement-Char (U+FFFD), sonst ist es vermutlich ein anderes Encoding.
        if let u = String(data: data, encoding: .utf8), !u.contains("\u{FFFD}") {
            return u
        }
        // 2. Windows-1251 (Kyrillisch) — russische/bulgarische Sender. Muss VOR
        //    Latin-1 (Schritt 4, bildet jedes Byte stumm ab) UND vor Shift-JIS
        //    (Schritt 3, akzeptiert kyrillische Bytes faelschlich als Halbkatakana).
        //    Nur per Heuristik, sonst wuerden westliche Latin-1-Titel zu Mojibake.
        if looksLikeWindows1251(bytes) {
            let cp1251 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue))
            if let cyr = String(data: data, encoding: String.Encoding(rawValue: cp1251)),
               cyr.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                return cyr
            }
        }
        // 3. Shift-JIS / CP932 — japanische Sender (z.B. „Retro PC Game Music (JP)").
        //    CP932 akzeptiert leider auch westliche Latin-1-Akzente als gueltige
        //    Doppelbytes (z.B. „Björk" => „Bjk", weil 0xF6 0x72 ein gueltiges Paar
        //    bildet). Darum nur uebernehmen, wenn das Ergebnis wirklich japanische
        //    Zeichen enthaelt (Hiragana/Katakana/Halbkatakana/CJK); sonst weiter
        //    zu Latin-1 (Schritt 4).
        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        if let sj = String(data: data, encoding: String.Encoding(rawValue: cp932)),
           sj.unicodeScalars.contains(where: { isJapaneseScalar($0.value) }) {
            return sj
        }
        // 4. Latin-1 — bildet jedes einzelne Byte ab, daher letzter Fallback.
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    // Heuristik: Sieht die Byte-Folge nach Windows-1251 (Kyrillisch) aus?
    // In 1251 liegen die kyrillischen Buchstaben bei 0xC0–0xFF (А–я) plus
    // 0xA8 (Ё) und 0xB8 (ё). Kyrillische Woerter sind Laeufe aufeinanderfolgender
    // solcher Bytes; westliche Latin-1-Titel haben dort nur vereinzelte
    // Akzentbuchstaben (é, ü…), nie lange Laeufe. Darum erst ab einem Lauf von
    // >=3 als Kyrillisch werten — so bleiben ASCII- und Latin-1-Titel unberuehrt.
    private func looksLikeWindows1251(_ bytes: [UInt8]) -> Bool {
        var run = 0
        for b in bytes {
            if b >= 0xC0 || b == 0xA8 || b == 0xB8 {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    // Echtes japanisches Zeichen? Hiragana (0x3040–0x309F), Katakana (0x30A0–0x30FF),
    // Halbbreite Katakana (0xFF61–0xFF9F) oder CJK-Ideogramme (0x4E00–0x9FFF).
    // Westliche Latin-1-Akzente, die CP932 faelschlich als Doppelbyte schluckt,
    // landen ausserhalb dieser Bereiche und werden so abgelehnt.
    private func isJapaneseScalar(_ v: UInt32) -> Bool {
        return (0x3040...0x30FF).contains(v)
            || (0xFF61...0xFF9F).contains(v)
            || (0x4E00...0x9FFF).contains(v)
    }

}

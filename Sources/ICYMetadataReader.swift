import Foundation

// Liest den ICY-Live-Titel (StreamTitle) direkt aus dem Shoutcast/Icecast-Stream
// (VLCKit gibt ihn nicht heraus) UND liefert die reinen Audio-Bytes fuer den
// Recorder. Eine Verbindung mit `Icy-MetaData: 1`:
//  - `icy-metaint: N` => N Audio-Bytes, dann 1 Laengenbyte L, dann L*16 Bytes
//    Metadaten "StreamTitle='Interpret - Titel';…". Audio-Bytes => onAudio.
//  - kein `icy-metaint` => reiner Audio-Stream; nur weiterlesen, wenn fuer die
//    Aufnahme gebraucht (allowAudioOnly), sonst abbrechen.
final class ICYMetadataReader: NSObject, URLSessionDataDelegate {
    var onTitle: ((String) -> Void)?          // einmal bei init gesetzt; Aufruf hopst auf Main

    // Pro-Session-Senken (Content-Type / Audio-Bytes). Werden ueber start() gesetzt und
    // NUR auf `q` gelesen/geschrieben — frueher waren es offene `var`, die der Main-Thread
    // (RadioPlayer.start) beim Senderwechsel neu zuwies, waehrend eine noch auslaufende
    // Delegate-Callback der ALTEN Session sie las (Race auf der Closure-Referenz).
    private var onContentType: ((String?) -> Void)?
    private var onAudio: ((Data) -> Void)?

    private var session: URLSession?          // nur Main-Thread (start/stop)
    private var task: URLSessionDataTask?     // nur Main-Thread (start/stop)

    // Serielle Queue: serialisiert ALLEN veraenderlichen Parser-/Senken-Zustand. Die
    // URLSession-Delegate-Callbacks laufen auf einer eigenen Hintergrund-Queue; ihre
    // Rumpf-Arbeit wird auf `q` gehopst, ebenso der Reset in stop(). So koennen sich
    // weder Main-vs-Delegate noch alte-vs-neue Session in die Quere kommen.
    private let q = DispatchQueue(label: "de.danielmuller.macradio.icy")

    private var allowAudioOnly = false        // nur auf q

    // Parser-Zustand (nur auf `q` angefasst).
    private var metaint = 0
    private var audioOnly = false   // Stream ohne ICY-Metadaten
    private var skip = 0
    private var inMeta = false
    private var metaLeft = 0
    private var buf = [UInt8]()
    private var lastTitle = ""

    func start(url: URL, allowAudioOnly: Bool = false,
               onContentType: ((String?) -> Void)? = nil,
               onAudio: ((Data) -> Void)? = nil) {
        stop()
        // Per-Session-Konfiguration + frischer Parser-Reset auf `q`. Da `q` seriell ist
        // und der Reaktivierungs-Block VOR dem Resume der neuen Session eingereiht wird,
        // greift er garantiert vor den Delegate-Callbacks dieser Session.
        q.async {
            self.allowAudioOnly = allowAudioOnly
            self.onContentType = onContentType
            self.onAudio = onAudio
            self.metaint = 0; self.audioOnly = false; self.skip = 0
            self.inMeta = false; self.metaLeft = 0
            self.buf.removeAll(keepingCapacity: false); self.lastTitle = ""
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.setValue("MuckeBaby/1.0", forHTTPHeaderField: "User-Agent")
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    func stop() {
        // Task/Session synchron auf dem Aufrufer (Main) abbauen, damit start() sofort eine
        // neue Session bauen kann; den Zustands-Reset auf `q` nachziehen, damit er nicht mit
        // einem noch laufenden Delegate-Callback kollidiert.
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        q.async {
            self.metaint = 0; self.audioOnly = false; self.skip = 0
            self.inMeta = false; self.metaLeft = 0
            self.buf.removeAll(keepingCapacity: false); self.lastTitle = ""
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Header roh auf dem Aufrufer lesen, die Zustands-Auswertung + Senken-Aufruf auf `q`.
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        let metaintHeader = http?.value(forHTTPHeaderField: "icy-metaint") ?? http?.value(forHTTPHeaderField: "Icy-MetaInt")
        q.async {
            self.onContentType?(contentType)
            if let v = metaintHeader, let n = Int(v), n > 0 {
                self.metaint = n; self.skip = n; self.inMeta = false; self.audioOnly = false
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
        q.async {
            if self.audioOnly { self.onAudio?(data); return }
            guard self.metaint > 0 else { return }
            // Chunk in Audio-Laufstuecke + Metadatenbloecke zerlegen.
            var audio = Data(); audio.reserveCapacity(data.count)
            for b in data {
                if !self.inMeta {
                    if self.skip > 0 { audio.append(b); self.skip -= 1; continue }
                    self.metaLeft = Int(b) * 16
                    if self.metaLeft == 0 { self.skip = self.metaint }
                    else { self.inMeta = true; self.buf.removeAll(keepingCapacity: true) }
                } else {
                    self.buf.append(b); self.metaLeft -= 1
                    if self.metaLeft == 0 { self.parse(self.buf); self.inMeta = false; self.skip = self.metaint }
                }
            }
            if !audio.isEmpty { self.onAudio?(audio) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Stream zu Ende / Fehler / Timeout -> die GERADE beendete Session freigeben
        // (sonst bliebe sie mit ihrer starken Referenz auf self samt Socket offen, bis
        // zufaellig ein externes stop()/start() kommt). Nur die lokale `session` anfassen,
        // NICHT self.session, um eine inzwischen gestartete neue Session nicht zu treffen.
        session.finishTasksAndInvalidate()
    }

    private func parse(_ bytes: [UInt8]) {
        // Die Marker `StreamTitle='` und `';` sind reines ASCII => direkt in den
        // Roh-Bytes suchen. So gehen die eigentlichen Titel-Bytes unangetastet
        // an den encoding-toleranten Decoder (wichtig fuer Shift-JIS u.ae.).
        let startMarker = Array("StreamTitle='".utf8)
        let endMarker = Array("';".utf8)
        guard let s = indexOf(startMarker, in: bytes) else { return }
        let titleStart = s + startMarker.count
        guard let e = indexOf(endMarker, in: bytes, from: titleStart) else { return }
        let titleBytes = Array(bytes[titleStart..<e])
        let title = decodeICY(titleBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != lastTitle else { return }
        lastTitle = title
        DispatchQueue.main.async { self.onTitle?(title) }
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

    // Findet die erste Position der Byte-Folge `needle` in `haystack` ab `from`.
    private func indexOf(_ needle: [UInt8], in haystack: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = from
        while i <= last {
            var match = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] { match = false; break }
            if match { return i }
            i += 1
        }
        return nil
    }
}

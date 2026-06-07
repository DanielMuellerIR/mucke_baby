import Foundation

// Liest den ICY-Live-Titel (StreamTitle) direkt aus dem Shoutcast/Icecast-Stream
// (VLCKit gibt ihn nicht heraus) UND liefert die reinen Audio-Bytes fuer den
// Recorder. Eine Verbindung mit `Icy-MetaData: 1`:
//  - `icy-metaint: N` => N Audio-Bytes, dann 1 Laengenbyte L, dann L*16 Bytes
//    Metadaten "StreamTitle='Interpret - Titel';…". Audio-Bytes => onAudio.
//  - kein `icy-metaint` => reiner Audio-Stream; nur weiterlesen, wenn fuer die
//    Aufnahme gebraucht (allowAudioOnly), sonst abbrechen.
final class ICYMetadataReader: NSObject, URLSessionDataDelegate {
    var onTitle: ((String) -> Void)?          // Main-Thread
    var onContentType: ((String?) -> Void)?   // Delegate-Queue, einmal bei Antwort
    var onAudio: ((Data) -> Void)?            // Delegate-Queue, reine Audio-Bytes

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var allowAudioOnly = false

    // Parser-Zustand (nur auf der Delegate-Queue angefasst).
    private var metaint = 0
    private var audioOnly = false   // Stream ohne ICY-Metadaten
    private var skip = 0
    private var inMeta = false
    private var metaLeft = 0
    private var buf = [UInt8]()
    private var lastTitle = ""

    func start(url: URL, allowAudioOnly: Bool = false) {
        stop()
        self.allowAudioOnly = allowAudioOnly
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
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        metaint = 0; audioOnly = false; skip = 0; inMeta = false; metaLeft = 0
        buf.removeAll(keepingCapacity: false); lastTitle = ""
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        onContentType?(http?.value(forHTTPHeaderField: "Content-Type"))
        if let v = http?.value(forHTTPHeaderField: "icy-metaint") ?? http?.value(forHTTPHeaderField: "Icy-MetaInt"),
           let n = Int(v), n > 0 {
            metaint = n; skip = n; inMeta = false; audioOnly = false
            completionHandler(.allow)
        } else if allowAudioOnly {
            audioOnly = true                 // keine Metadaten, aber fuer Aufnahme behalten
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if audioOnly { onAudio?(data); return }
        guard metaint > 0 else { return }
        // Chunk in Audio-Laufstuecke + Metadatenbloecke zerlegen.
        var audio = Data(); audio.reserveCapacity(data.count)
        for b in data {
            if !inMeta {
                if skip > 0 { audio.append(b); skip -= 1; continue }
                metaLeft = Int(b) * 16
                if metaLeft == 0 { skip = metaint }
                else { inMeta = true; buf.removeAll(keepingCapacity: true) }
            } else {
                buf.append(b); metaLeft -= 1
                if metaLeft == 0 { parse(buf); inMeta = false; skip = metaint }
            }
        }
        if !audio.isEmpty { onAudio?(audio) }
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
        //    Liefert nil bei ungueltigen Byte-Folgen, daher als dritte Wahl sicher.
        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        if let sj = String(data: data, encoding: String.Encoding(rawValue: cp932)) {
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

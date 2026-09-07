import Foundation

// Die URLSession bleibt echt; dieses Protokoll liefert ausschließlich Testbytes.
final class ICYFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["icy-metaint": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var metadata = Array("StreamTitle='\(request.url!.lastPathComponent)';".utf8)
        while metadata.count % 16 != 0 { metadata.append(0) }
        client?.urlProtocol(self, didLoad: Data([65, UInt8(metadata.count / 16)] + metadata))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ICYHarness {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
            exit(1)
        }
    }
    static func drainMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    static func main() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ICYFixtureProtocol.self]
        let titleQueue = DispatchQueue(label: "icy.test.titles", target: .main)
        titleQueue.suspend()
        let reader = ICYMetadataReader(configuration: configuration, titleQueue: titleQueue)
        var titles: [String] = []
        reader.onTitle = { titles.append($0) }
        func start(_ title: String) {
            let parsed = DispatchSemaphore(value: 0)
            reader.start(url: URL(string: "https://fixture.invalid/\(title)")!,
                         onAudio: { _ in parsed.signal() })
            // onAudio läuft erst nach parse(): der Titel wartet jetzt auf Main.
            let deadline = Date(timeIntervalSinceNow: 5)
            while parsed.wait(timeout: .now()) != .success {
                check(Date() < deadline, "ICY-Fixture wurde nicht zerlegt")
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        start("old")
        reader.stop()
        titleQueue.resume()
        drainMain()
        check(titles.isEmpty, "alter Titel kam nach stop() an")
        titleQueue.suspend()
        start("old")
        start("current")
        titleQueue.resume()
        drainMain()
        check(titles == ["current"], "Senderwechsel lieferte alten Titel: \(titles)")

        // Nicht zur aktiven Session gehörende Delegate-Aufrufe dürfen weder
        // Parserzustand noch Senken des laufenden Senders verändern.
        let foreign = URLSession(configuration: configuration)
        let task = foreign.dataTask(with: URL(string: "https://fixture.invalid/foreign")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["icy-metaint": "1"])!
        let checked = DispatchSemaphore(value: 0)
        reader.urlSession(foreign, dataTask: task, didReceive: response) { disposition in
            check(disposition == .cancel, "fremde Response wurde akzeptiert")
            checked.signal()
        }
        check(checked.wait(timeout: .now() + 5) == .success, "Response-Abschluss fehlt")
        var metadata = Array("StreamTitle='foreign';".utf8)
        while metadata.count % 16 != 0 { metadata.append(0) }
        reader.urlSession(foreign, dataTask: task, didReceive: Data([65, UInt8(metadata.count / 16)] + metadata))
        drainMain()
        check(titles == ["current"], "fremde Daten wurden als aktueller Titel geliefert")
        reader.stop()
        foreign.invalidateAndCancel()
        print("ICYHarness: OK")
    }
}

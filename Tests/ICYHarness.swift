import Foundation

// Die URLSession bleibt echt; dieses Protokoll liefert ausschließlich Testbytes.
final class ICYFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "fragmented" || request.url!.lastPathComponent == "audio-only" {
            let audioOnly = request.url!.lastPathComponent == "audio-only"
            var headers = ["Content-Type": "audio/mpeg"]
            if !audioOnly { headers["icy-metaint"] = "8" }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let audio = Array(UInt8.min...UInt8.max)
            var wire = [UInt8]()
            for position in stride(from: 0, to: audio.count, by: 8) {
                wire += audio[position..<position + 8]
                if !audioOnly {
                    if position % 16 == 0 {
                        wire.append(0)
                    } else {
                        var metadata = Array("StreamTitle='Björk - Fixture';".utf8)
                        while metadata.count % 16 != 0 { metadata.append(0) }
                        wire.append(UInt8(metadata.count / 16))
                        wire += metadata
                    }
                }
            }
            var position = 0
            let sizes = [1, 3, 17]
            var chunk = 0
            while position < wire.count {
                let end = min(wire.count, position + sizes[chunk % sizes.count])
                client?.urlProtocol(self, didLoad: Data(wire[position..<end]))
                position = end; chunk += 1
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
        // Response-Senke haelt unmittelbar vor recorder.begin an. stop muss
        // diesen Aufruf abwarten, bevor der abschliessende end-Auftrag folgt.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = Recorder(directory: directory, minimumFreeBytes: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let racing = ICYMetadataReader(configuration: configuration)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        racing.start(url: URL(string: "https://fixture.invalid/recording")!, allowAudioOnly: true,
            onContentType: { contentType in
                entered.signal()
                check(resume.wait(timeout: .now() + 5) == .success, "Callback-Freigabe fehlt")
                recorder.begin(station: "Fixture", contentType: contentType)
            }, onAudio: { recorder.write($0) })
        check(entered.wait(timeout: .now() + 5) == .success, "Response-Senke fehlt")
        DispatchQueue.global().async {
            racing.stop()
            recorder.end()
            recorder.flush()
            finished.signal()
        }
        check(finished.wait(timeout: .now() + 0.05) == .timedOut,
              "stop kehrt vor Ende der laufenden Senke zurueck")
        resume.signal()
        check(finished.wait(timeout: .now() + 5) == .success, "Stop/Flush fehlt")
        let clips = recorder.snapshot()
        check(clips.count == 1, "Recorder-Start wurde nicht ausgefuehrt")
        check(clips.allSatisfy { $0.end != nil }, "nach Stop/Flush blieb Aufnahme offen")
        for path in ["fragmented", "audio-only"] {
            let pipelineDirectory = directory.appendingPathComponent(path)
            let pipelineRecorder = Recorder(directory: pipelineDirectory, minimumFreeBytes: -1)
            let pipeline = ICYMetadataReader(configuration: configuration)
            let received = DispatchSemaphore(value: 0)
            var audioCount = 0
            pipeline.start(url: URL(string: "https://fixture.invalid/\(path)")!, allowAudioOnly: true,
                onContentType: { pipelineRecorder.begin(station: "Fixture", contentType: $0) },
                onAudio: { data in
                    pipelineRecorder.write(data)
                    audioCount += data.count
                    if audioCount == 256 { received.signal() }
                })
            check(received.wait(timeout: .now() + 5) == .success, "fragmentierte Audio-Fixture unvollständig")
            pipeline.stop()
            pipelineRecorder.end(); pipelineRecorder.flush()
            let clip = pipelineRecorder.snapshot().first!
            let bytes = try! Data(contentsOf: pipelineDirectory.appendingPathComponent(clip.file))
            check(bytes == Data(UInt8.min...UInt8.max), "ICY-Metadaten gelangten in Aufnahme oder Audio ging verloren")
            check(clip.end != nil && clip.ext == "mp3", "ICY/Recorder-Codec oder Abschluss falsch")
        }
        print("ICYHarness: OK")
    }
}

import Foundation

// Echte Reader-, Recorder- und Verlaufsklassen; nur VLC und Netzwerk sind Fixtures.
enum RolloverFixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeRollover-" + UUID().uuidString)
    static let titles = DispatchQueue(label: "fixture.rollover.titles", target: .main)
    static let states = DispatchQueue(label: "fixture.rollover.states", target: .main)
    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RolloverProtocol.self]
        return config
    }
}
final class RolloverProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var instance: RolloverProtocol?
    private static var count = 0
    static var starts: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var ready: Bool { lock.lock(); defer { lock.unlock() }; return instance != nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/ogg", "icy-metaint": "4"])!, cacheStoragePolicy: .notAllowed)
        Self.lock.lock(); Self.instance = self; Self.count += 1; Self.lock.unlock()
    }
    override func stopLoading() {
        Self.lock.lock(); if Self.instance === self { Self.instance = nil }; Self.lock.unlock()
    }
    static func emit(title: String) {
        var metadata = Data("StreamTitle='\(title)';".utf8)
        let blocks = (metadata.count + 15) / 16
        metadata.append(Data(repeating: 0, count: blocks * 16 - metadata.count))
        var wire = Data("OggS".utf8); wire.append(UInt8(blocks)); wire.append(metadata)
        lock.lock(); let current = instance; lock.unlock()
        guard let current else { fatalError("Rollover-Verbindung fehlt") }
        current.client?.urlProtocol(current, didLoad: wire)
    }
}
enum RadioBrowserAPI { static func countClick(stationUUID: String) {} }
enum PlaylistResolver { static func resolve(_ raw: String) async -> URL? { URL(string: raw) } }

@main
struct PlayerRolloverHarness {
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<3000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        check(false, "Rollover-Fixture wartet zu lange")
    }
    @MainActor static func main() async throws {
        let titleFirst = CommandLine.arguments.contains("--title-first")
        defer { try? FileManager.default.removeItem(at: RolloverFixture.root) }
        let suite = "MuckeRollover-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recorder = Recorder(directory: RolloverFixture.root.appendingPathComponent("recordings"), minimumFreeBytes: -1)
        let radio = RadioPlayer(recorder: recorder, preferences: preferences)
        check(!radio.recordingRequested, "Aufnahme-Default ist nicht aus")
        radio.setRecordingRequested(true)
        radio.play(Station(name: "Rollover", url: "https://fixture.invalid/rollover"))
        await waitFor { radio.currentStreamURL != nil && RolloverProtocol.ready }
        let audioPlayer = VLCMediaPlayer.latest!
        audioPlayer.timeEvent()
        await waitFor { radio.isPlaying }
        RolloverProtocol.emit(title: "Artist - Before rollover")
        await waitFor { radio.nowPlayingTitle == "Artist - Before rollover" && radio.recordingState.phase == .recording }
        let streamID = recorder.captureState().streamID!
        let revision = recorder.captureState().revision
        let base = Date().addingTimeInterval(-86_500)
        recorder.configureCapture(station: "Rollover", streamID: streamID, enabled: true, revision: revision, at: base, uptime: 0)
        recorder.captureFormat("audio/ogg", streamID: streamID)
        recorder.captureAudio(Data("OggS aged fixture".utf8), at: base, receivedUptime: 1, streamID: streamID)
        recorder.flush()
        let oldSegment = recorder.captureState().segmentID!
        await waitFor { radio.recordingState.segmentID == oldSegment && radio.recordingState.phase == .recording }
        radio.history.clear()
        radio.history.note(station: "Rollover", raw: "Artist - Before rollover", at: base, sessionID: oldSegment)
        let oldEntryID = radio.history.entries.last!.id
        if titleFirst { RolloverFixture.states.suspend() }
        else { RolloverFixture.titles.suspend() }
        RolloverProtocol.emit(title: "Artist - After rollover")
        if titleFirst {
            await waitFor { radio.nowPlayingTitle == "Artist - After rollover" }
            RolloverFixture.states.resume()
        }
        await waitFor { RolloverProtocol.starts == 2 && RolloverProtocol.ready }
        let oldClip = recorder.snapshot().first { $0.sessionID == oldSegment }!
        let boundary = oldClip.receivedEnd!
        check(radio.nowPlayingTitle == "Artist - After rollover", "Status vor Titelzustellung verwirft den empfangenen Rollovertitel")
        check(radio.history.entries.first { $0.id == oldEntryID }?.end == boundary,
              "Verlauf schließt nicht an der empfangenen Rollovergrenze")
        check(radio.history.entries.last?.raw == "Artist - After rollover" && radio.history.entries.last?.start == boundary,
              "Neuer Titel beginnt nicht an der empfangenen Grenze")
        check(VLCMediaPlayer.latest === audioPlayer && radio.isPlaying, "Headererneuerung unterbricht VLC")
        if !titleFirst { try? await Task.sleep(nanoseconds: 5_100_000_000) }
        RolloverProtocol.emit(title: "Artist - After rollover")
        await waitFor { radio.recordingState.phase == .recording && radio.recordingState.streamID != streamID }
        let newState = recorder.captureState()
        check(radio.history.entries.last?.sessionID == newState.segmentID && radio.history.entries.last?.raw == "Artist - After rollover",
              "Neuer Aufnahmeabschnitt erhält nicht den empfangenen Titel")
        if !titleFirst {
            let gap = radio.history.entries.first { $0.start == boundary }!
            check(gap.end == newState.startedAt && recorder.exportSource(for: gap) == nil,
                  "Headerwartezeit wird fälschlich einer Aufnahmedatei zugeordnet")
        }
        let starts = RolloverProtocol.starts
        recorder.onCaptureState?(RecordingState(phase: .needsStreamHeader, revision: revision, streamID: streamID,
            rollover: .init(title: "Stale - Wrong title", receivedAt: Date())))
        check(radio.nowPlayingTitle == "Artist - After rollover" && RolloverProtocol.starts == starts,
              "Alter Rolloverstatus verändert Titel oder startet nochmals")
        recorder.captureAudio(Data([99]), at: Date(), streamID: streamID)
        recorder.finishCapture(streamID: streamID, at: Date()); recorder.flush()
        check(recorder.captureState().streamID == newState.streamID && recorder.captureState().phase == .recording,
              "Alte Stream-ID verändert den neuen Aufnahmeabschnitt")
        radio.stop()
        let historyCount = radio.history.entries.count
        let stoppedTitle = radio.nowPlayingTitle
        if !titleFirst { RolloverFixture.titles.resume() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(radio.nowPlayingTitle == stoppedTitle && radio.history.entries.count == historyCount && RolloverProtocol.starts == starts,
              "Verspäteter Titel startet nach Stop erneut oder verändert Verlauf")
        await waitFor { !RolloverProtocol.ready }
        recorder.flush()
        check(recorder.snapshot().allSatisfy { $0.end != nil }, "Stop lässt Aufnahme offen")
        print("PlayerRolloverHarness: \(titleFirst ? "Titel vor Status" : "Status vor Titel"), Empfangsgrenze, Verlauf, neuer Abschnitt, VLC-Instanz und Generationen OK")
    }
}

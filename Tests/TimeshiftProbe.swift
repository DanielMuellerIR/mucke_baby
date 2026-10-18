// Separates Test-App-Bundle; wird von build.sh nicht in die Produkt-App eingebaut.
import AppKit
import Combine
import Foundation
import VLCKit
import CoreAudio

@main @MainActor final class TimeshiftProbe: NSObject, NSApplicationDelegate {
    private var playback: TimeshiftPlayback!
    private var window: NSWindow!
    private var label = NSTextField(wrappingLabelWithString: "")
    private var status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var root: URL!
    private var url: URL!
    private var observedTitles = Set<String>()

    static func main() {
        let delegate = TimeshiftProbe()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count >= 3, let url = URL(string: args[1]), url.host == "127.0.0.1" else { exit(2) }
        self.url = url; root = URL(fileURLWithPath: args[2], isDirectory: true)
        try? Data(String(getpid()).utf8).write(to: root.appendingPathComponent("app.pid"))
        playback = TimeshiftPlayback(makeBuffer: { try TimeshiftBuffer(parentDirectory: self.root) })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mucke, Baby! — Timeshift experiment / Zeitversatz-Versuch"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.wantsLayer = true
        window.contentView!.layer!.backgroundColor = NSColor.white.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let explanation = NSTextField(wrappingLabelWithString:
            "Experimental MP3 test · Experimenteller MP3-Test\n30 s / 2 MiB compressed RAM + ≤2 MiB local excerpt. Stops below 10 GiB free.\nTemporärer Puffer: alte Frames werden entfernt. Keine dauerhaften Aufnahmen.\nDer feste Ausschnitt endet. Continuous playback is outside this experiment.")
        explanation.font = .systemFont(ofSize: 14)
        for view in [explanation, label, status] { view.textColor = .black }
        for view in [explanation, label, status] { stack.addArrangedSubview(view) }
        for (title, action) in [("Enable test / Versuch aktivieren", #selector(enable)),
                               ("12 s back / 12 s zurück", #selector(delayed)),
                               ("Pause / Resume · Pause / Fortsetzen", #selector(pauseResume)),
                               ("Live", #selector(live)), ("Stop / Puffer entfernen", #selector(stop))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; stack.addArrangedSubview(button)
        }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                                     stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                                     stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if args.contains("--automated") {
            Task { do { try await run(); finish(error: nil) } catch { finish(error: error) } }
        }
    }

    private func refresh() {
        label.stringValue = "\(playback.phase.rawValue) · \(String(format: "%.1f", playback.bufferedDuration)) s buffered · \(String(format: "%.1f", playback.position)) s playback\nLive: \(playback.liveTitle)\nHeard / Gehört: \(playback.heardTitle)"
        if playback.phase == .delayed { observedTitles.insert(playback.heardTitle) }
        if let failure = playback.failure { status.stringValue = String(describing: failure) }
        else if playback.phase == .finished && playback.endUsedStallGuard {
            status.stringValue = "VLC end stall: excerpt closed / Stillstand am Dateiende: Ausschnitt beendet"
        } else { status.stringValue = "" }
    }
    @objc private func enable() { do { try playback.start(url: url) } catch { status.stringValue = String(describing: error) } }
    @objc private func delayed() { do { try playback.playDelayed(delay: 12) } catch { status.stringValue = String(describing: error) } }
    @objc private func pauseResume() { if playback.phase == .paused { playback.resume() } else { playback.pause() } }
    @objc private func live() { do { try playback.returnToLive() } catch { status.stringValue = String(describing: error) } }
    @objc private func stop() { playback.stop() }

    private func check(_ value: Bool, _ text: String) throws {
        if !value { throw NSError(domain: "TimeshiftProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    }
    private func wait(_ label: String, timeout: TimeInterval = 25, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let context = " phase=\(playback.phase.rawValue), state=\(playback.player.map { Int($0.state.rawValue) } ?? -1), position=\(playback.position)"
        throw NSError(domain: "TimeshiftProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout: " + label + context])
    }
    private func connectionCount() async throws -> Int {
        let stats = url.deletingLastPathComponent().appendingPathComponent("stats")
        let (data, _) = try await URLSession.shared.data(from: stats)
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (value["active"] as! [String: Any]).count
    }
    private func outputRunning() -> Bool {
        var pid = getpid(), object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr else { return false }
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var running: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr && running != 0
    }
    private func waitConnections(_ count: Int) async throws {
        for _ in 0..<60 {
            if try await connectionCount() == count { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "TimeshiftProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Verbindungen != \(count)"])
    }
    private func shot(_ name: String) throws {
        refresh()
        window.contentView!.layoutSubtreeIfNeeded()
        let view = window.contentView!, rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    }

    private func run() async throws {
        try playback.start(url: url)
        try await wait("Puffer 22 Sekunden") { playback.bufferedDuration >= 22 }
        try await waitConnections(2)
        try await wait("Live-CoreAudio-Ausgang") { outputRunning() }
        try shot("live")
        try playback.playDelayed(delay: 12)
        try await wait("Lokale VLC-Wiedergabe") { playback.position >= 2 }
        try check(playback.player?.media?.url?.isFileURL == true, "VLC liest keine lokale Datei")
        try await waitConnections(1)
        try await wait("Lokaler CoreAudio-Ausgang") { outputRunning() }
        let snapshot = playback.snapshot!, directory = playback.buffer!.directory
        let initialDelay = playback.buffer!.metrics.live - snapshot.start - playback.position
        let bytes = try Data(contentsOf: snapshot.url)
        try bytes.write(to: root.appendingPathComponent("played-excerpt.mp3"))
        try JSONSerialization.data(withJSONObject: ["start": snapshot.start, "end": snapshot.end, "bytes": snapshot.bytes,
             "titles": snapshot.titles.map { ["offset": $0.offset, "raw": $0.raw] }], options: .prettyPrinted)
            .write(to: root.appendingPathComponent("timeline.json"))
        try shot("delayed")
        let pausedAt = ProcessInfo.processInfo.systemUptime
        playback.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let paused = Double(playback.player!.time.intValue) / 1000
        // Empfang läuft während der Pause über ein vollständiges Pufferfenster weiter.
        try await Task.sleep(nanoseconds: 34_000_000_000)
        let after = Double(playback.player!.time.intValue) / 1000
        let pauseWallSeconds = ProcessInfo.processInfo.systemUptime - pausedAt
        let pausedDelay = playback.buffer!.metrics.live - snapshot.start - after
        try check(abs(after - paused) < 0.15, "Pause lässt die VLC-Zeit weiterlaufen")
        try check(playback.buffer!.metrics.oldest > snapshot.end, "Ältester Bereich wurde im Überlauf nicht ersetzt")
        try check(try Data(contentsOf: snapshot.url) == bytes, "Pause/Überlauf verändert aktiven Ausschnitt")
        try check(playback.buffer!.metrics.bufferedBytes <= 2 * 1024 * 1024 && playback.buffer!.metrics.duration <= 30.01, "Pufferlimit verletzt")
        try shot("paused")
        playback.resume()
        try await wait("Fortsetzen") { playback.position > after + 1 }
        try await wait("Ausschnittende") { playback.phase == .finished }
        let endUsedStallGuard = playback.endUsedStallGuard
        try check(observedTitles.count >= 2, "Keine Titelwechsel entlang der lokalen Datei")
        try shot("finished")
        try playback.returnToLive()
        try await waitConnections(2)
        try await wait("Live-Rückkehr") { playback.player?.isPlaying == true && !playback.heardTitle.isEmpty }
        try await wait("CoreAudio nach Live-Rückkehr") { outputRunning() }
        try shot("returned-live")
        let metrics = playback.buffer!.metrics
        playback.stop()
        try await waitConnections(0)
        try check(!FileManager.default.fileExists(atPath: directory.path), "Puffer bleibt nach Stop liegen")
        try JSONSerialization.data(withJSONObject: ["passed": true, "connections": [2,1,2,0], "pauseClockAdvanceSeconds": after - paused,
             "pauseWallSeconds": pauseWallSeconds, "initialDelaySeconds": initialDelay, "pausedDelaySeconds": pausedDelay,
             "bufferSeconds": metrics.duration, "bufferBytes": metrics.bufferedBytes, "observedTitles": observedTitles.sorted(),
             "coreAudioRunning": true, "endUsedStallGuard": endUsedStallGuard, "humanListeningVerified": false], options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("result.json"))
    }
    private func finish(error: Error?) {
        if let error { try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("failure.txt")) }
        playback.stop(); timer?.invalidate(); window.orderOut(nil); NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { playback?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

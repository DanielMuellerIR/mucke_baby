import AppKit
import SwiftUI
import VLCKit

// Der native Test liest ausschließlich den tatsächlichen VLC-Ausgang. Der
// Produktionsweg nutzt weiterhin den bereits separat geprüften Prozess-AudioTap.
@MainActor final class TimeshiftRecognitionOutput {
    let capture = RecognitionCapture()
    private let root: URL
    private var file: URL?
    private var cursor = 44
    private var serial = 0
    private var listening = false
    private(set) weak var latest: VLCMediaPlayer?
    init(root: URL) { self.root = root }
    func makePlayer() -> VLCMediaPlayer {
        serial += 1
        let next = root.appendingPathComponent("output-\(serial).wav")
        file = next; cursor = 44; listening = false
        let player = VLCMediaPlayer(library: VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + next.path,
            "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"]))
        latest = player
        return player
    }
    func poll(_ active: Bool) {
        guard let file, let data = try? Data(contentsOf: file), data.count >= 44 else { return }
        if active && !listening { cursor = data.count - (data.count - 44) % 4 }
        listening = active
        guard active, data.count > cursor else { return }
        let end = data.count - (data.count - 44) % 4
        let samples = data.withUnsafeBytes { bytes in
            stride(from: cursor, to: end, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        cursor = end
        capture.append(samples, sampleRate: 48_000)
    }
}

@MainActor final class TimeshiftRecognitionMatcher: RecognitionMatching {
    let root: URL
    var automatic = true
    var completions: [@MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void] = []
    var frequencies: [Double] = []
    init(root: URL) { self.root = root }
    func match(_ pcm: RecognitionPCM, completion: @escaping @MainActor (Result<RecognizedTrack?, RecognitionFailure>) -> Void) {
        // Ein unabhängiger Python-Prüfer wertet dieselben PCM-Dateien mit FFT aus.
        let crossings = zip(pcm.samples, pcm.samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) / (Double(pcm.samples.count) / pcm.sampleRate)
        frequencies.append(frequency); completions.append(completion)
        try! pcm.samples.withUnsafeBytes { try Data($0).write(to: root.appendingPathComponent("capture-\(frequencies.count).f32")) }
        if automatic { completion(.success(Self.track(frequency))) }
    }
    static func track(_ frequency: Double) -> RecognizedTrack {
        RecognizedTrack(title: frequency < 660 ? "Tone 440" : "Tone 880", artist: "Fixture Catalog", shazamID: "fixture", appleMusicURL: nil)!
    }
    // Verspätete Antworten absichtlich erhalten: der Dienst muss sie sperren.
    func cancel() {}
}

extension TimeshiftTransportProbe {
    func runRecognition() async throws {
        func check(_ condition: Bool, _ message: String = "Nativer Erkennungskontext verletzt") throws {
            if !condition { throw NSError(domain: "TimeshiftRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let output = recognitionOutput!, matcher = recognitionMatcher!
        let pump = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak recognition] _ in
            Task { @MainActor in output.poll(recognition?.phase == .listening) }
        }
        defer { pump.invalidate(); recognition.cancel(); player.stop(); player.recorder.flush() }
        let base = URL(string: CommandLine.arguments[2])!.deletingLastPathComponent()
        func settle(_ minimum: Double = 12) async throws {
            try await wait { self.player.canPause && self.player.timeshiftTransport.timeline.live > minimum }
        }
        func rejected(_ name: String, change: () -> Void) async throws {
            matcher.automatic = false
            recognition.start()
            try await wait { self.recognition.phase == .matching }
            let late = matcher.completions.last!
            change()
            late(.success(TimeshiftRecognitionMatcher.track(440)))
            try check(recognition.currentResult == nil && recognition.currentAdoption == nil
                         && !recognition.adoptCurrentResult(), "Veralteter Treffer: " + name)
            try record(name)
            matcher.automatic = true
        }
        let directOnly = ProcessInfo.processInfo.environment["MUCKE_RECOGNITION_DIRECT_ONLY"] == "1"
        let coreOnly = ProcessInfo.processInfo.environment["MUCKE_RECOGNITION_CORE_ONLY"] == "1"
        if directOnly {
            player.play(Station(name: "Fixture • heaac", url: base.appendingPathComponent("heaac").absoluteString))
            try await settle()
            player.play(player.currentStation!)
        }
        for codec in directOnly ? [] : ["mp3", "aac", "heaac"] {
            player.play(Station(name: "Fixture • " + codec, url: base.appendingPathComponent(codec).absoluteString))
            try await settle(36)
            player.seekTimeshift(to: 6)
            try await wait { self.player.canPause }
            try check(player.nowPlayingTitle.contains("440"))
            let count = player.history.entries.count
            let clips = player.recorder.snapshot().map(\.id)
            let before = player.recognitionContext!
            try mark(codec + "-recognize-ready")
            try await wait { self.recognition.currentResult != nil }
            let result = recognition.currentResult!
            try check(result.track.title == "Tone 440" && result.context.title.contains("440"))
            try check(result.context.listening?.outputID == before.listening?.outputID
                         && result.context.listening?.receivedAt != nil && result.context.listening!.position! < 15)
            try check(recognition.currentAdoption == nil && bookmarks.entries.count == (codec == "mp3" ? 0 : 1),
                         "Treffer wird automatisch übernommen/gemerkt")
            try mark(codec + "-result")
            try await wait { self.recognition.currentAdoption != nil && self.bookmarks.contains(result.song(station: self.player.currentStation!.name)) }
            let saved = bookmarks.entries.first!
            if codec == "mp3" {
                let origin = result.context.listening!, stored = saved.recognition!.listening!
                // Das portable ISO-Format speichert Millisekunden, die Laufzeituhr mehr.
                try check(stored.outputID == origin.outputID && stored.revision == origin.revision
                    && stored.position == origin.position
                    && abs(stored.receivedAt!.timeIntervalSince(origin.receivedAt!)) < 0.001
                    && abs(saved.heardAt.timeIntervalSince(result.capturedAt)) < 0.001,
                    "Persistierter Hörkontext weicht über die dokumentierte Millisekundenpräzision hinaus ab")
            }
            try check(player.history.entries.count == count && player.recorder.snapshot().map(\.id) == clips,
                         "Anzeigeübernahme oder Merken verändert Empfangsdaten")
            try record(codec + "-adopted")
            if codec == "mp3" { try await recognitionViews() }
            try mark(codec + "-adopted")
            try await wait { self.player.isPaused }
            try check(recognition.currentResult == nil && recognition.currentAdoption == nil)
            try mark(codec + "-paused")
            try await wait { self.player.isPlaying }
            try check(!result.context.isCurrent(player.recognitionContext))
            player.seekTimeshift(to: 6); try await wait { self.player.canPause }
            try await rejected(codec + "-same-title-seek", change: { player.seekTimeshift(to: 8) })
            try await wait { self.player.canPause }
            try await rejected(codec + "-live", change: { player.returnToLive() })
            try await wait { self.player.canPause }
            if codec == "mp3" {
                player.seekTimeshift(to: player.timeshiftTransport.timeline.oldest)
                try await wait { self.player.canPause }; player.pause()
                try await wait(seconds: 75) { self.player.timeshiftTransport.phase == .expired }
                try check(recognition.currentResult == nil && recognition.currentAdoption == nil && !player.isPlaying)
                try record("expired-held")
                player.returnToLive(); try await wait { self.player.canPause }
            }
            matcher.automatic = false
            recognition.start(); try await wait { self.recognition.phase == .matching }
            let reconnectLate = matcher.completions.last!
            _ = try await URLSession.shared.data(from: base.appendingPathComponent("control/drop"))
            try await wait { self.player.timeshiftTransport.phase == .expired && self.player.timeshiftTransport.timeline.canStart }
            reconnectLate(.success(TimeshiftRecognitionMatcher.track(440)))
            try check(recognition.currentResult == nil && recognition.currentAdoption == nil && !player.isPlaying)
            matcher.automatic = true
            try record(codec + "-reconnected-playing")
            player.returnToLive(); try await wait { self.player.canPause }
            player.pause()
            _ = try await URLSession.shared.data(from: base.appendingPathComponent("control/drop"))
            try await wait { self.player.timeshiftTransport.phase == .expired && self.player.timeshiftTransport.timeline.canStart }
            try check(recognition.currentResult == nil && recognition.currentAdoption == nil && !player.isPlaying)
            try record(codec + "-reconnected-held")
            player.returnToLive(); try await wait { self.player.canPause }
            // Derselbe Sender und Text dürfen nach einem Neustart nicht genügen.
            let station = player.currentStation!
            try await rejected(codec + "-station-restart", change: { player.play(station) })
        }
        // Direkte Container bleiben auch bei aktivierter Pufferoption erkennbar.
        for codec in coreOnly ? [] : ["vorbis", "opus", "flac"] {
            player.play(Station(name: "Fixture • " + codec, url: base.appendingPathComponent(codec).absoluteString))
            do { try await wait { self.player.isPlaying && !self.player.nowPlayingTitle.isEmpty } }
            catch { try record(codec + "-playback-timeout"); throw error }
            try check(!player.canPause && player.recognitionContext?.listening?.position == nil)
            recognition.start()
            try await wait { self.recognition.currentResult != nil || !self.recognition.phase.isBusy }
            try check(recognition.currentResult?.track.title == "Tone 440",
                "Direkte Erkennung \(codec): \(recognition.phase); \(player.statusText); \(player.metadataStatus ?? "")")
            try record(codec + "-direct")
        }
        player.stop(); player.recorder.flush()
        try mark("recognition-passed")
    }

    func recognitionViews() async throws {
        let dialog = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 580, height: 580),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { dialog.orderOut(nil) }
        for theme in ThemeID.allCases {
            for width in [940.0, 660.0] {
                for dark in theme == .schlicht ? [false, true] : [false] {
                    install(theme: theme, width: width, dark: dark)
                    let prefix = "recognition-\(theme.rawValue)-\(Int(width))-\(dark ? "dark" : "light")"
                    try await Task.sleep(for: .milliseconds(120))
                    try shot(prefix + "-main"); try shot(prefix + "-mini", mini: true)
                    dialog.contentView = NSHostingView(rootView: environment(
                        MusicRecognitionView(availableWidth: width == 660 ? 388 : 580, availableHeight: 580), theme: theme, dark: dark))
                    dialog.setContentSize(NSSize(width: width == 660 ? 388 : 580, height: 580))
                    dialog.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(120))
                    let view = dialog.contentView!
                    view.layoutSubtreeIfNeeded()
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(prefix + "-dialog.png"))
                }
            }
        }
        install(theme: .schlicht, width: 940, dark: false)
    }
}

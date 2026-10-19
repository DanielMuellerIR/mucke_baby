import AppKit
import SwiftUI
import MediaPlayer
import VLCKit

final class TimeshiftTestCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var low = false
    func setLow(_ value: Bool) { lock.lock(); low = value; lock.unlock() }
    func available(at url: URL) -> Int64 {
        lock.lock(); let low = low; lock.unlock()
        if low { return Recorder.minFreeBytes - 1 }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
}

extension TimeshiftTransportProbe {
    func runIntegration() async throws {
        let base = URL(string: CommandLine.arguments[2])!.deletingLastPathComponent()
        let quick = ProcessInfo.processInfo.environment["MUCKE_TRANSPORT_QUICK"] == "1"
        func change(_ format: String) {
            player.play(Station(name: "Fixture • " + format, url: base.appendingPathComponent(format).absoluteString))
        }
        func settle() async throws {
            try await wait { self.player.canPause && self.player.timeshiftTransport.timeline.live > 12 }
        }
        try await settle()
        try record("aac-ready")
        mainWindow.orderOut(nil); miniWindow.center(); miniWindow.makeKeyAndOrderFront(nil)
        try mark("integration-pause-ready")
        try await wait { self.player.isPaused }
        let originalPosition = player.timeshiftTransport.position
        let originalClip = player.recordingState.segmentID
        try mark("integration-record-off-ready")
        try await wait { !self.player.recordingRequested && self.player.recordingState.phase == .off }
        try record("record-off-paused")
        try await Task.sleep(for: .seconds(6))
        try mark("integration-record-on-ready")
        try await wait { self.player.recordingState.phase == .recording }
        let newClip = player.recordingState.segmentID
        precondition(originalClip != newClip && player.isPaused)
        try await Task.sleep(for: .seconds(7))
        player.seekTimeshift(to: player.timeshiftTransport.timeline.live - 4)
        precondition(player.isPaused && player.currentSong?.sessionID == newClip,
                     "Gehörter Frame erhält falschen Mitschnitt nach Aufnahmewechsel")
        try record("new-recording-position")
        player.seekTimeshift(to: originalPosition)
        precondition(player.currentSong?.sessionID == originalClip, "Seek verliert ursprüngliche Aufnahmezuordnung")
        try record("old-recording-position")
        try shot("integration-paused", mini: true)

        // Der echte Startknopf muss in Pause bedienbar sein; die Oberfläche setzt eine Minute.
        miniWindow.orderOut(nil); mainWindow.makeKeyAndOrderFront(nil)
        try mark("integration-timer-ready")
        try await wait { self.player.sleepTimer.remaining != nil }
        try record("timer-started-paused")
        try await wait(seconds: 70) { !self.player.hasPlaybackIntent }
        precondition(player.currentStreamURL == nil)
        try record("timer-expired")
        let clipsAfterTimer = player.recorder.snapshot()
        precondition(clipsAfterTimer.allSatisfy { $0.end != nil })
        change("aac"); try await settle()

        player.pause()
        player.prepareForSleep()
        precondition(!player.isPlaying && player.currentStreamURL == nil)
        player.resumeAfterWake()
        precondition(!player.isPlaying && player.timeshiftTransport.phase == .expired)
        try record("wake-held")
        try mark("integration-wake-live-ready")
        try await wait { self.player.isPlaying }
        try await settle()
        try record("wake-explicit-live")

        player.pause()
        let control = base.appendingPathComponent("control/drop")
        _ = try await URLSession.shared.data(from: control)
        try await wait { self.player.timeshiftTransport.phase == .expired }
        try await wait { self.player.timeshiftTransport.timeline.canStart }
        precondition(!player.isPlaying)
        try record("reconnected-held")
        player.returnToLive(); try await settle()
        var audio = AudioConfiguration()
        audio.equalizerEnabled = true; audio.bands[5] = -12
        player.configureAudio(audio)
        player.seekTimeshift(to: player.timeshiftTransport.timeline.oldest)
        try await wait { self.player.isPlaying }
        precondition(player.audioNotice == nil)
        try record("equalizer-seek")

        capacity.setLow(true)
        try await wait { self.player.recordingState.phase == .lowDisk && !self.player.isPlaying }
        try record("disk-low")
        try await Task.sleep(for: .milliseconds(500))
        mainWindow.orderOut(nil); miniWindow.makeKeyAndOrderFront(nil)
        try shot("integration-low-disk", mini: true)
        precondition(player.hasPlaybackIntent && player.recordingRequested)
        capacity.setLow(false)
        player.setRecordingRequested(false); player.setRecordingRequested(true)
        player.returnToLive(); try await settle()
        try record("disk-recovered")

        miniWindow.orderOut(nil); mainWindow.makeKeyAndOrderFront(nil)
        for theme in ThemeID.allCases {
            for width in [940.0, 660.0] {
                for dark in [false, true] {
                    install(theme: theme, width: width, dark: dark)
                    try await Task.sleep(for: .milliseconds(180))
                    try shot("aac-\(theme.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
        if !quick {
            player.pause()
            var samples: [[String: Double]] = []
            for _ in 0..<70 {
                let transport = player.timeshiftTransport
                samples.append(["position": transport.position, "oldest": transport.timeline.oldest,
                                "live": transport.timeline.live, "bytes": Double(transport.timeline.bytes)])
                precondition(transport.timeline.bytes <= 32 * 1024 * 1024)
                precondition(transport.timeline.live - transport.timeline.oldest <= 300.001)
                try JSONSerialization.data(withJSONObject: samples).write(to: root.appendingPathComponent("bounds.json"), options: .atomic)
                if transport.phase == .expired { break }
                try await Task.sleep(for: .seconds(5))
            }
            precondition(player.timeshiftTransport.phase == .expired && !player.isPlaying)
            try record("aac-full-pause-expired")
            player.returnToLive(); try await wait { self.player.isPlaying }
        }

        change("heaac"); try await settle()
        player.pause(); player.skipTimeshift(by: -5); player.resume()
        try await wait { self.player.canPause }
        try await Task.sleep(for: .seconds(2))
        precondition(player.isPlaying, "HE-AAC verliert sein Decoderformat")
        try record("heaac-resume")
        change("mp3"); try await settle()
        player.pause(); player.skipTimeshift(by: -5); player.resume()
        try await wait { self.player.isPlaying }
        try record("mp3-resume")
        for format in ["vorbis", "opus", "flac"] {
            player.setRecordingRequested(false); change(format)
            try await wait { self.player.isPlaying }
            try await wait { !self.player.timeshiftTransport.timeline.canStart && self.player.timeshiftStatus.contains("MP3") }
            player.setRecordingRequested(true)
            try await wait { self.player.recordingState.phase == .recording }
            try await Task.sleep(for: .seconds(7))
            try record(format + "-recording-live")
            player.setRecordingRequested(false)
            try await wait { self.player.recordingState.phase == .off }
        }
        for format in ["hls/index.m3u8", "manifest"] {
            player.setRecordingRequested(true); change(format)
            try await wait { self.player.isPlaying && self.player.recordingState.phase == .unsupportedFormat }
            let count = player.recorder.snapshot().count
            try await Task.sleep(for: .seconds(3))
            precondition(player.recorder.snapshot().count == count)
            try record(format.hasPrefix("hls") ? "hls-path" : "hls-mime")
        }
        for theme in ThemeID.allCases {
            for width in [940.0, 660.0] {
                for dark in [false, true] {
                    install(theme: theme, width: width, dark: dark)
                    try await Task.sleep(for: .milliseconds(180))
                    try shot("hls-\(theme.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
        mainWindow.orderOut(nil); miniWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        try shot("integration-hls", mini: true)
        player.stop(); player.recorder.flush()
        let clips = player.recorder.snapshot()
        try JSONEncoder.isoPretty.encode(clips).write(to: root.appendingPathComponent("clips.json"))
        let exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        for (name, ext) in [("mp3", "mp3"), ("aac", "aac"), ("heaac", "aac"), ("ogg", "ogg"), ("opus", "opus"), ("flac", "flac")] {
            guard let clip = clips.last(where: {
                $0.file.hasSuffix("." + ext) && (ext != "aac" || $0.station.lowercased() == "fixture • " + name)
            }) else { fatalError("Aufnahme fehlt: " + name) }
            let source = player.recorder.dir.appendingPathComponent(clip.file)
            for mode in [SongExporter.Mode.hardCut, .faded] {
                let target = exports.appendingPathComponent(name + (mode == .hardCut ? "-hard.m4a" : "-fade.m4a"))
                try await SongExporter.export(source: source, offset: 1, duration: 3, mode: mode, to: target)
            }
        }
        if !quick { try await checkBufferedEqualizer(base: base) }
        try mark("integration-passed")
    }

    private func checkBufferedEqualizer(base: URL) async throws {
        var results: [[String: String]] = []
        let suite = "de.danielmuller.mucke.effects-test"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        for codec in ["mp3", "aac"] {
            for mode in ["off", "flat", "cut"] {
                let folder = root.appendingPathComponent("effects-\(codec)-\(mode)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var index = 0
                var latest = folder.appendingPathComponent("unused.wav")
                let radio = RadioPlayer(makePlayer: {
                    latest = folder.appendingPathComponent("pcm-\(index).wav"); index += 1
                    return VLCMediaPlayer(library: VLCLibrary(options: [
                        "--aout=afile", "--audiofile-file=" + latest.path,
                        "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"]))
                }, recorder: Recorder(directory: folder.appendingPathComponent("recordings")),
                   preferences: preferences, history: SongHistory(directory: folder.appendingPathComponent("history")),
                   timeshiftRoot: folder.appendingPathComponent("buffers"))
                var configuration = AudioConfiguration()
                configuration.equalizerEnabled = mode != "off"
                if mode == "cut" { configuration.bands[5] = -12 }
                radio.configureAudio(configuration); radio.setTimeshiftRequested(true)
                radio.play(Station(name: "Effects", url: base.appendingPathComponent("effects-" + codec).absoluteString))
                let deadline = Date().addingTimeInterval(25)
                while Date() < deadline && !(radio.canPause && radio.timeshiftTransport.timeline.live > 9) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                precondition(radio.canPause && radio.audioNotice == nil, "Puffer-Equalizer hat keinen lokalen Ausgang")
                radio.stop(); radio.recorder.flush()
                try await Task.sleep(for: .milliseconds(300))
                results.append(["codec": codec, "mode": mode, "file": latest.path.replacingOccurrences(of: root.path + "/", with: "")])
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: root.appendingPathComponent("effects.json"))
    }
}

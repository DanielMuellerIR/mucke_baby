import AppKit
import VLCKit

@main struct TimeshiftSeekHarness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [[String: Any]] = []
        for name in ["cbr", "vbr", "mpeg2", "mpeg1-32k", "mpeg2-16k", "mpeg25-8k"] {
            let folder = root.appendingPathComponent(name)
            let audio = try Data(contentsOf: folder.appendingPathComponent("source.mp3"))
            let header = MP3FrameHeader(Array(audio.prefix(4)))!
            let rate = header.format / 10
            let samples = Int((header.duration * Double(rate)).rounded())
            var offset = 0, frameCount = 0
            while offset < audio.count {
                let frame = MP3FrameHeader(Array(audio[offset..<min(offset + 4, audio.count)]))!
                offset += frame.bytes; frameCount += 1
            }
            let control = folder.appendingPathComponent("control.wav")
            if !FileManager.default.fileExists(atPath: control.path) {
                let library = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + control.path,
                    "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"])
                let player = VLCMediaPlayer(library: library)
                player.media = VLCMedia(url: folder.appendingPathComponent("source.mp3")); player.play()
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(100))
                    let bytes = (try? control.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if bytes >= 44 + frameCount * samples * 4 || player.state == .error { break }
                }
                player.stop()
            }
            for seconds in [header.duration, 1.224, 3.336, 7.104] {
                let requested = Int(floor(seconds / header.duration + 0.000001))
                let buffer = try TimeshiftSegments(root: root.appendingPathComponent("buffers"), freeBytes: { _ in Int64.max })
                try buffer.accept(contentType: "audio/mpeg"); try buffer.append(audio)
                let reader = try buffer.makeReader(at: Double(requested) * header.duration)
                let actual = Int((reader.playbackStart / header.duration).rounded())
                precondition(actual == requested && buffer.metrics.live - reader.playbackStart >= 3)
                let remainingFrames = Int(((buffer.metrics.live - reader.playbackStart) / header.duration).rounded())
                let expectedBytes = 44 + remainingFrames * samples * 4
                try buffer.finishReception()
                let output = folder.appendingPathComponent("seek-\(requested).wav")
                let library = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + output.path,
                    "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"])
                let player = VLCMediaPlayer(library: library)
                let media = VLCMedia(stream: reader)
                for option in reader.mediaOptions { media.addOption(option) }
                player.media = media; player.play()
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(100))
                    let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if bytes >= expectedBytes || player.state == .error { break }
                }
                buffer.cancelReaders(); player.stop(); reader.close(); try buffer.close()
                results.append(["case": name, "requestedFrame": requested, "offsetSamples": actual * samples,
                    "decoderStart": reader.start, "playbackStart": reader.playbackStart,
                    "options": reader.mediaOptions, "output": name + "/" + output.lastPathComponent])
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("seeks.json"), options: .atomic)
            }
        }
        try Data("passed".utf8).write(to: root.appendingPathComponent("native.txt"))
    }
}

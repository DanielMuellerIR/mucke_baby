import Foundation
import AppKit
import VLCKit

@main struct TimeshiftContinuousHarness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try Data(contentsOf: root.appendingPathComponent("source.mp3"))
        var frames: [Data] = [], offset = 0
        while offset < source.count {
            guard let header = MP3FrameHeader(Array(source[offset..<min(offset + 4, source.count)])),
                  offset + header.bytes <= source.count else { fatalError("Fixture nicht framefest") }
            frames.append(source.subdata(in: offset..<offset + header.bytes)); offset += header.bytes
        }
        let firstHeader = MP3FrameHeader(Array(frames[0].prefix(4)))!
        let samplesPerFrame = Int((firstHeader.duration * Double(firstHeader.format / 10)).rounded())
        let expectedBytes = 44 + frames.count * samplesPerFrame * 4
        let buffer = try TimeshiftSegments(root: root.appendingPathComponent("buffers"),
            limits: TimeshiftSegmentLimits(duration: 30, segmentDuration: 0.5), freeBytes: { _ in Int64.max })
        try buffer.accept(contentType: "audio/mpeg")
        let seeking = ProcessInfo.processInfo.environment["MUCKE_DECODER_SEEK"] == "1"
        let initialFrames = seeking ? 250 : 125
        for frame in frames.prefix(initialFrames) { try buffer.append(frame) }
        let reader = try buffer.makeReader(delay: seeking ? 3 : 30)
        let startFrame = Int((reader.playbackStart / firstHeader.duration).rounded())
        let localExpectedBytes = expectedBytes - startFrame * samplesPerFrame * 4
        try JSONSerialization.data(withJSONObject: ["start": reader.start, "playbackStart": reader.playbackStart, "startFrame": startFrame,
            "samplesPerFrame": samplesPerFrame, "decoderPreroll": reader.decoderPreroll,
            "reserve": buffer.metrics.live - reader.start]).write(to: root.appendingPathComponent("reader.json"))
        let output = root.appendingPathComponent("continuous.wav")
        let library = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + output.path,
            "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"])
        let player = VLCMediaPlayer(library: library)
        let media = VLCMedia(stream: reader)
        for option in reader.mediaOptions { media.addOption(option) }
        player.media = media; player.play()
        // Der Leser erreicht mehrfach das gerade wachsende Ende. Er darf dort
        // keinen EOF liefern und beim Segmentwechsel keine Frames verdoppeln.
        for (index, frame) in frames.dropFirst(initialFrames).enumerated() {
            try buffer.append(frame)
            if index % 10 == 0 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        try buffer.finishReception()
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 >= localExpectedBytes { break }
        }
        let entries = buffer.index
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("segments.json"))
        let export = root.appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
        for segment in entries { try FileManager.default.copyItem(at: buffer.directory.appendingPathComponent(segment.file), to: export.appendingPathComponent(segment.file)) }
        buffer.cancelReaders(); player.stop(); reader.close(); try buffer.close()
        precondition(!FileManager.default.fileExists(atPath: buffer.directory.path), "Leser hält Puffer nach Stop")
        let control = root.appendingPathComponent("control.wav")
        let controlLibrary = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + control.path,
            "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"])
        let direct = VLCMediaPlayer(library: controlLibrary)
        direct.media = VLCMedia(url: root.appendingPathComponent("source.mp3")); direct.play()
        for _ in 0..<250 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? control.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 >= expectedBytes { break }
        }
        direct.stop()
        try Data("native decoder completed".utf8).write(to: root.appendingPathComponent("native.txt"))
    }
}

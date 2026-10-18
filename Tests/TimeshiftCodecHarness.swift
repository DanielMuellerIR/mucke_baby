import Foundation
import AppKit
import VLCKit

@main struct TimeshiftCodecHarness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var results = [[String: Any]]()
        for name in ["mp3", "aac", "aac-aligned", "ogg", "opus"] {
            let output = root.appendingPathComponent("vlc-" + name + ".wav")
            precondition(!FileManager.default.fileExists(atPath: output.path), "Frische Ausgabe erforderlich")
            let library = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + output.path,
                "--audiofile-format=float32", "--audiofile-wav", "--audiofile-channels=1", "--quiet"])
            let player = VLCMediaPlayer(library: library)
            player.media = VLCMedia(url: root.appendingPathComponent("cut-" + name + (name == "aac-aligned" ? ".aac" : "." + name)))
            player.play()
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if player.state == .ended || player.state == .error { break }
            }
            player.stop()
            let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            results.append(["format": name, "pcmFileBytes": bytes])
            precondition((name == "ogg" || name == "opus") ? bytes == 0 : bytes > 100_000,
                         "Geänderte Decodergrenze: " + name)
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vlc-results.json"))
    }
}

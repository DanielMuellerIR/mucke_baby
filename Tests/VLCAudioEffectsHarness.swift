import Foundation
import AppKit
import VLCKit

@main
struct VLCAudioEffectsHarness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["off", "flat", "cut", "headroom"] {
            let destination = root.appendingPathComponent(name + ".wav")
            precondition(!FileManager.default.fileExists(atPath: destination.path))
            let library = VLCLibrary(options: ["--aout=afile", "--audiofile-file=" + destination.path,
                                              "--audiofile-format=float32", "--audiofile-wav",
                                              "--audiofile-channels=1", "--quiet"])
            let player = VLCMediaPlayer(library: library)
            player.media = VLCMedia(url: root.appendingPathComponent("three-tones.wav"))
            if name != "off" {
                var configuration = AudioConfiguration()
                if name == "cut" { configuration.bands[5] = -12 }
                if name == "headroom" { configuration.bands[5] = 6 }
                let equalizer = VLCAudioEqualizer()
                equalizer.preAmplification = Float(configuration.vlcPreampDB)
                for (band, value) in zip(equalizer.bands, configuration.bands) { band.amplification = Float(value) }
                player.equalizer = equalizer
            }
            player.play()
            for _ in 0..<70 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if player.state == .ended || player.state == .error { break }
            }
            player.stop()
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            precondition(size > 100_000, "Kein echter PCM-Ausgang")
        }
    }
}

import Foundation

@main
struct ExportPositionHarness {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for ext in ["mp3", "aac", "ogg", "opus"] {
            let source = root.appendingPathComponent("marked.\(ext)")
            let bounds = try await SongExporter.inspect(source: source)
            let range = try ExportRange(offset: 1.5, duration: 2.7, audio: bounds)
            let cut = try range.cut(startAdjustment: 0, endAdjustment: 0)
            for (name, mode) in [("hard", SongExporter.Mode.hardCut), ("faded", .faded)] {
                let preview = root.appendingPathComponent("preview-\(ext)-\(name).m4a")
                let saved = root.appendingPathComponent("saved-\(ext)-\(name).m4a")
                try await SongExporter.export(source: source, offset: cut.start,
                                              duration: cut.duration, mode: mode, to: preview)
                try await SongExporter.savePrepared(preview, originalSource: source, to: saved)
                guard try Data(contentsOf: preview) == Data(contentsOf: saved) else {
                    fatalError("Vorhördatei und gespeicherter Export unterscheiden sich")
                }
            }
        }
    }
}

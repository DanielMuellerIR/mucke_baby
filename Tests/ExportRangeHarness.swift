import Foundation

@main struct ExportRangeHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let range = try ExportRange(offset: 2, duration: 5, audio: ExportAudioBounds(start: 0, end: 12))
        check(try range.cut(startAdjustment: -0.5, endAdjustment: 0.25) == ExportCut(start: 1.5, end: 7.25), "Korrekturen ändern nicht beide Grenzen")
        let partial = try ExportRange(offset: 8, duration: 8, audio: ExportAudioBounds(start: 0, end: 10))
        check(partial.isPartial && partial.baseline == ExportCut(start: 8, end: 10), "Abgeschnittene Quelle bleibt zu lang")
        let outside = try ExportRange(offset: 20, duration: 5, audio: ExportAudioBounds(start: 0, end: 10))
        check(try outside.cut(startAdjustment: -1, endAdjustment: 0) == ExportCut(start: 9, end: 10), "Verfügbares Ende lässt sich nicht bewusst korrigieren")
        for pair in [(-3.0, 0.0), (20, 0), (0, -20), (0, 20), (0, -4.5), (4, -4), (.nan, 0), (0, .infinity)] {
            do { _ = try range.cut(startAdjustment: pair.0, endAdjustment: pair.1); fatalError("Ungültiger Ausschnitt akzeptiert") }
            catch is ExportRangeError {}
        }
        for bounds in [ExportAudioBounds(start: -1, end: 2), ExportAudioBounds(start: 1, end: 1), ExportAudioBounds(start: 0, end: .nan)] {
            do { _ = try ExportRange(offset: 0, duration: 1, audio: bounds); fatalError("Ungültige Mediengrenzen akzeptiert") }
            catch is ExportRangeError {}
        }
        print("ExportRangeHarness: Mediengrenzen, Korrektur, Teilquelle, Mindestlänge und ungültige Werte OK")
    }
}

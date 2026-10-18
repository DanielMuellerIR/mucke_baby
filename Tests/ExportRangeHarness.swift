import Foundation

@main struct ExportRangeHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        check(ExportAdjustmentText.parse("-19,7", locale: de) == -19.7, "Deutsche Nachkommastellen gehen verloren")
        check(ExportAdjustmentText.parse("-19.7", locale: en) == -19.7, "Englische Nachkommastellen gehen verloren")
        check(ExportAdjustmentText.parse("  +0,5  ", locale: de) == 0.5, "Vorzeichen oder Leerraum falsch")
        check(ExportAdjustmentText.parse("-19.7", locale: de) == nil && ExportAdjustmentText.parse("-19,7", locale: en) == nil,
              "Fremdes Dezimaltrennzeichen wird teilweise übernommen")
        for locale in [de, en] {
            for text in ["", "-", "+", "NaN", "inf", "1e2", "2x", "1,234.5", "1.234,5", "1..2"] {
                check(ExportAdjustmentText.parse(text, locale: locale) == nil, "Ungültiger Text wird als gültiger Präfix übernommen")
            }
        }
        check(ExportAdjustmentText.format(0.5, locale: de) == "0,5" && ExportAdjustmentText.format(0.5, locale: en) == "0.5", "Stepper verwendet falsches Dezimaltrennzeichen")
        check(ExportTimeText.format(5, locale: de) == "0:00:05,00", "Deutsche Zeit enthält Leerstellen statt Nullen")
        check(ExportTimeText.format(125.5, locale: en) == "0:02:05.50", "Englische Zeit falsch")
        check(ExportTimeText.format(59.999, locale: en) == "0:01:00.00" && ExportTimeText.format(.nan, locale: en) == "—", "Zeitübertrag oder ungültige Zeit falsch")
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
        print("ExportRangeHarness: Mediengrenzen, Korrektur, Teilquelle, Mindestlänge, strikte DE/EN-Eingabe und Zeitdarstellung OK")
    }
}

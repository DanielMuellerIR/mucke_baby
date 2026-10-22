import Foundation

@main
enum FixtureToneHarness {
    static func main() {
        for frequency in [110.0, 220, 440, 660, 880, 1760] {
            let samples = (0..<(48_000 * 3)).map { Float(0.1 * sin(2 * .pi * frequency * Double($0) / 48_000)) }
            let measured = FixtureTone.frequency(samples: samples, sampleRate: 48_000)
            precondition(abs(measured - frequency) < 1, "Nulldurchgänge messen falsche Frequenz")
            let expected = [440.0, 880].contains(frequency) ? "Tone \(Int(frequency))" : nil
            precondition(FixtureTone.title(frequency: measured) == expected, "Unpassende Frequenz wird als Sollton erkannt")
        }
        for frequency in [0.0, 434, 446, 874, 886, .nan, .infinity] {
            precondition(FixtureTone.title(frequency: frequency) == nil, "Toleranz akzeptiert unpassende Frequenz")
        }
        for samples: [Float] in [[], [0], [0, 0, 0], [.nan, .infinity], [0.1, 0.1, 0.1]] {
            precondition(FixtureTone.title(frequency: FixtureTone.frequency(samples: samples, sampleRate: 48_000)) == nil,
                         "Leere, stille oder ungültige PCM-Daten werden erkannt")
        }
        print("FixtureTone: 440/880 Hz erkannt; Oktavfehler, Fremdtöne, Stille und ungültige PCM-Daten abgelehnt")
    }
}

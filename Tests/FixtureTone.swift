import Foundation

enum FixtureTone {
    static func frequency(samples: [Float], sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, samples.count > 1,
              samples.allSatisfy(\.isFinite) else { return .nan }
        let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        return Double(crossings) / (Double(samples.count) / sampleRate)
    }

    static func title(frequency: Double) -> String? {
        guard let expected = [440, 880].first(where: { abs(frequency - Double($0)) <= 5 }) else { return nil }
        return "Tone \(expected)"
    }
}

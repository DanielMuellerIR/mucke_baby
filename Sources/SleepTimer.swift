import Foundation

struct SleepTimerSchedule: Equatable {
    private(set) var deadline: TimeInterval?
    private(set) var fadeDuration: TimeInterval = 10
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    @discardableResult
    mutating func start(duration: TimeInterval, at now: TimeInterval) -> Bool {
        guard now.isFinite, duration.isFinite, (1...Self.maximumDuration).contains(duration) else { return false }
        guard (now + duration).isFinite else { return false }
        deadline = now + duration
        fadeDuration = min(10, duration / 2)
        return true
    }

    @discardableResult
    mutating func extend(by duration: TimeInterval, at now: TimeInterval) -> Bool {
        guard let deadline, now.isFinite, duration.isFinite, duration > 0, deadline > now else { return false }
        self.deadline = min(deadline + duration, now + Self.maximumDuration)
        return true
    }

    mutating func cancel() { deadline = nil }

    func remaining(at now: TimeInterval) -> TimeInterval? {
        guard let deadline, now.isFinite else { return nil }
        return max(0, deadline - now)
    }

    func fadeFactor(at now: TimeInterval) -> Double {
        remaining(at: now).map { min(1, $0 / fadeDuration) } ?? 1
    }
}

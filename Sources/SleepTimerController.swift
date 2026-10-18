import Foundation
import Combine

@MainActor
final class SleepTimerController: ObservableObject {
    @Published private(set) var remaining: TimeInterval?
    private(set) var fadeFactor = 1.0
    var onFadeChange: ((Double) -> Void)?
    var onExpire: (() -> Void)?
    private var schedule = SleepTimerSchedule()
    private var timer: Timer?
    private let now: () -> TimeInterval
    private var latestTime = -Double.infinity

    init(now: (() -> TimeInterval)? = nil) {
        let clock = ContinuousClock(), origin = clock.now
        self.now = now ?? {
            // ContinuousClock zählt auch übersprungene Zeit, unabhängig von Änderungen der Systemuhr.
            let elapsed = origin.duration(to: clock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }

    private func currentTime() -> TimeInterval {
        let value = now()
        if value.isFinite { latestTime = max(latestTime, value) }
        return latestTime
    }

    @discardableResult
    func start(duration: TimeInterval) -> Bool {
        guard schedule.start(duration: duration, at: currentTime()) else { return false }
        timer?.invalidate()
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
        return true
    }

    func extend(minutes: Int) {
        refresh()
        guard schedule.extend(by: Double(minutes) * 60, at: currentTime()) else { return }
        refresh()
    }

    func cancel() {
        schedule.cancel(); timer?.invalidate(); timer = nil
        remaining = nil; setFade(1)
    }

    func refresh() {
        let time = currentTime()
        let next = schedule.remaining(at: time)
        if remaining.map(ceil) != next.map(ceil) { remaining = next }
        setFade(schedule.fadeFactor(at: time))
        if next == 0 {
            schedule.cancel(); timer?.invalidate(); timer = nil
            onExpire?()
            cancel()
        }
    }

    private func setFade(_ value: Double) {
        guard value != fadeFactor else { return }
        fadeFactor = value; onFadeChange?(value)
    }
}

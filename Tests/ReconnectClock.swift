import Foundation

@MainActor
final class ReconnectClock {
    final class Event: ReconnectTimer {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline; self.action = action
        }
        func cancel() { cancelled = true }
    }
    private(set) var now: TimeInterval = 0
    private(set) var events: [Event] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ReconnectTimer {
        let event = Event(deadline: now + delay, action: action)
        events.append(event)
        return event
    }
    func advance(_ interval: TimeInterval) {
        let target = now + interval
        while let index = events.indices.filter({ events[$0].deadline <= target })
            .min(by: { events[$0].deadline < events[$1].deadline }) {
            let event = events.remove(at: index)
            now = event.deadline
            if !event.cancelled { event.action() }
        }
        now = target
    }
}

import Foundation

struct MetadataAnchor: Equatable, Identifiable {
    let position: TimeInterval
    let title: String
    var receivedAt: Date? = nil
    var id: TimeInterval { position }
}

// Mediensekunden gehören nur zur aktuellen Empfangssitzung. Empfangsdatum und
// dauerhafter Verlauf bleiben davon unabhängig; ein Seek erzeugt keinen Eintrag.
struct MetadataTimeline: Equatable {
    static let startReserve: TimeInterval = 3
    var oldest: TimeInterval = 0
    var live: TimeInterval = 0
    var bytes = 0
    var titles: [MetadataAnchor] = []
    var latestStart: TimeInterval { max(oldest, live - Self.startReserve) }
    var canStart: Bool { live - oldest >= Self.startReserve }

    func clamped(_ position: TimeInterval) -> TimeInterval? {
        guard canStart, position.isFinite else { return nil }
        return min(latestStart, max(oldest, position))
    }
    func title(at position: TimeInterval) -> String {
        anchor(at: position)?.title ?? ""
    }
    func anchor(at position: TimeInterval) -> MetadataAnchor? {
        titles.last(where: { $0.position <= position + 0.000001 })
    }
}

struct TimeshiftTransport: Equatable {
    enum Phase { case live, delayed, paused, expired }
    var phase: Phase = .live
    var timeline = MetadataTimeline()
    var position: TimeInterval = 0
    var delay: TimeInterval { max(0, timeline.live - position) }
    var isPaused: Bool { phase == .paused }
    var holdsPlayback: Bool { phase == .paused || phase == .expired }
}

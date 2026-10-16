import Foundation

@MainActor
protocol ReconnectTimer: AnyObject { func cancel() }

@MainActor
private final class TaskReconnectTimer: ReconnectTimer {
    private var task: Task<Void, Never>?
    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

@MainActor
final class PlaybackReconnect {
    enum Phase: Equatable {
        case idle, connecting, playing
        case waiting(attempt: Int, delay: TimeInterval)
        case waitingForNetwork(attempt: Int)
        case exhausted
    }
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> any ReconnectTimer

    private(set) var phase = Phase.idle
    private(set) var desiredStationID: UUID?
    private(set) var retryCount = 0
    var maximumRetries: Int { delays.count }
    var onRetry: ((UUID) -> Void)?
    var onTimeout: (() -> Void)?
    var onChange: ((Phase) -> Void)?

    private let delays: [TimeInterval]
    private let inactivityTimeout: TimeInterval
    private let stableInterval: TimeInterval
    private let schedule: Schedule
    private var networkAvailable = true
    private var intentRevision: UInt64 = 0
    private var attemptRevision: UInt64 = 0
    private var activityRevision: UInt64 = 0
    private var retryRevision: UInt64 = 0
    private var retryTimer: (any ReconnectTimer)?
    private var activityTimer: (any ReconnectTimer)?
    private var stableTimer: (any ReconnectTimer)?

    init(delays: [TimeInterval] = [2, 5, 15], inactivityTimeout: TimeInterval = 30,
         stableInterval: TimeInterval = 60,
         schedule: @escaping Schedule = { TaskReconnectTimer(delay: $0, action: $1) }) {
        self.delays = delays
        self.inactivityTimeout = inactivityTimeout
        self.stableInterval = stableInterval
        self.schedule = schedule
    }

    func beginIntent(stationID: UUID) {
        cancel()
        desiredStationID = stationID
        retryCount = 0
        setPhase(.connecting)
    }

    func attemptStarted() {
        guard desiredStationID != nil else { return }
        cancelAttemptTimers()
        attemptRevision &+= 1
        setPhase(.connecting)
        activity()
    }

    func activity() {
        guard desiredStationID != nil, phase == .connecting || phase == .playing else { return }
        activityTimer?.cancel()
        activityRevision &+= 1
        let activity = activityRevision, intent = intentRevision, attempt = attemptRevision
        activityTimer = schedule(inactivityTimeout) { [weak self] in
            guard let self, self.intentRevision == intent, self.attemptRevision == attempt,
                  self.activityRevision == activity, self.desiredStationID != nil else { return }
            self.onTimeout?()
        }
    }

    func playing() {
        guard desiredStationID != nil, phase == .connecting else { return }
        setPhase(.playing)
        let intent = intentRevision, attempt = attemptRevision
        stableTimer = schedule(stableInterval) { [weak self] in
            guard let self, self.intentRevision == intent, self.attemptRevision == attempt,
                  self.phase == .playing else { return }
            self.retryCount = 0
            self.stableTimer = nil
        }
    }

    func failed() {
        guard desiredStationID != nil, phase == .connecting || phase == .playing else { return }
        cancelAttemptTimers()
        attemptRevision &+= 1
        guard retryCount < delays.count else {
            desiredStationID = nil
            setPhase(.exhausted)
            return
        }
        waitForRetry()
    }

    func setNetworkAvailable(_ available: Bool) {
        let previouslyAvailable = networkAvailable
        networkAvailable = available
        guard desiredStationID != nil else { return }
        if !available, case .waiting = phase {
            cancelRetryTimer()
            setPhase(.waitingForNetwork(attempt: retryCount + 1))
        } else if available && !previouslyAvailable {
            switch phase {
            case .waiting, .waitingForNetwork: retryNow()
            default: break
            }
        }
    }

    func cancel() {
        intentRevision &+= 1
        cancelRetryTimer()
        cancelAttemptTimers()
        desiredStationID = nil
        retryCount = 0
        setPhase(.idle)
    }

    private func waitForRetry() {
        cancelRetryTimer()
        guard networkAvailable else {
            setPhase(.waitingForNetwork(attempt: retryCount + 1))
            return
        }
        let delay = delays[retryCount]
        setPhase(.waiting(attempt: retryCount + 1, delay: delay))
        let intent = intentRevision, revision = retryRevision
        retryTimer = schedule(delay) { [weak self] in
            guard let self, self.intentRevision == intent, self.retryRevision == revision,
                  self.desiredStationID != nil else { return }
            self.retryNow()
        }
    }

    private func retryNow() {
        guard let id = desiredStationID, retryCount < delays.count else { return }
        cancelRetryTimer()
        retryCount += 1
        setPhase(.connecting)
        onRetry?(id)
    }

    private func cancelRetryTimer() {
        retryRevision &+= 1
        retryTimer?.cancel(); retryTimer = nil
    }

    private func cancelAttemptTimers() {
        activityRevision &+= 1
        activityTimer?.cancel(); activityTimer = nil
        stableTimer?.cancel(); stableTimer = nil
    }

    private func setPhase(_ phase: Phase) { self.phase = phase; onChange?(phase) }
}

import Foundation
import Combine
import VLCKit

// Experimenteller Einstieg. Die normale RadioPlayer-Bedienung aktiviert
// ihn nicht. Live: VLC + vorhandener ICY-Empfang; verzögert: lokale Datei + ICY.
@MainActor
final class TimeshiftPlayback: ObservableObject {
    enum Phase: String { case off, live, delayed, paused, finished, failed }
    @Published private(set) var phase = Phase.off
    @Published private(set) var liveTitle = ""
    @Published private(set) var heardTitle = ""
    @Published private(set) var bufferedDuration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var failure: Error?
    private(set) var endUsedStallGuard = false
    private(set) var buffer: TimeshiftBuffer?
    private(set) var snapshot: TimeshiftSnapshot?
    var player: VLCMediaPlayer? { resources.player }
    private let resources = TimeshiftPlaybackResources()
    private let reader = ICYMetadataReader()
    private var shim: PlayerDelegateShim?
    private var streamURL: URL?
    private var generation = UUID()
    private var playbackGeneration = UUID()
    private var endGuard = TimeshiftEndGuard()
    private let makePlayer: () -> VLCMediaPlayer
    private let makeBuffer: () throws -> TimeshiftBuffer

    init(makePlayer: @escaping () -> VLCMediaPlayer = { VLCMediaPlayer() },
         makeBuffer: @escaping () throws -> TimeshiftBuffer = { try TimeshiftBuffer() }) {
        self.makePlayer = makePlayer; self.makeBuffer = makeBuffer
    }

    deinit {
        reader.stop()
        Task { @MainActor [resources, buffer] in
            resources.timer?.invalidate()
            resources.stopPlayer()
            try? buffer?.close()
        }
    }

    func start(url: URL) throws {
        stop()
        failure = nil
        guard StreamURLPolicy.validatedURL(url.absoluteString) != nil else { throw TimeshiftFailure.invalidAudio }
        let buffer = try makeBuffer(), ticket = generation
        self.buffer = buffer; streamURL = url; phase = .live
        reader.onTitle = { [weak self] title, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == ticket else { return }
                self.liveTitle = title
                if self.phase == .live { self.heardTitle = title }
            }
        }
        reader.start(url: url, allowAudioOnly: true,
                     onStart: { [weak self] type, _ in
                         do { try buffer.accept(contentType: type) }
                         catch { Task { @MainActor in self?.fail(error, ticket: ticket) } }
                     },
                     onBoundary: { title, _ in buffer.noteTitle(title) },
                     onAudio: { [weak self] data in
                         do { try buffer.append(data) }
                         catch { Task { @MainActor in self?.fail(error, ticket: ticket) } }
                     },
                     onCompletion: { [weak self] _ in
                         Task { @MainActor in self?.fail(TimeshiftFailure.closed, ticket: ticket) }
                     })
        replacePlayer(url: url, local: false)
        resources.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func playDelayed(delay: TimeInterval) throws {
        guard let buffer, phase != .off, phase != .failed else { throw TimeshiftFailure.notReady }
        stopPlayer()
        do {
            if let snapshot { try buffer.releaseSnapshot(snapshot.id); self.snapshot = nil }
            let value = try buffer.makeSnapshot(delay: delay)
            snapshot = value; position = 0; heardTitle = value.title(at: 0); phase = .delayed
            endGuard.reset(); endUsedStallGuard = false
            replacePlayer(url: value.url, local: true)
        } catch {
            // Ein zu früher Klick darf Live nicht dauerhaft stumm hinterlassen.
            if error as? TimeshiftFailure == .notReady, let streamURL {
                phase = .live; heardTitle = liveTitle; replacePlayer(url: streamURL, local: false)
            } else { fail(error, ticket: generation) }
            throw error
        }
    }

    func pause() {
        guard phase == .delayed else { return }
        player?.pause(); phase = .paused; endGuard.reset()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .delayed; endGuard.reset(); player?.play()
    }

    func returnToLive() throws {
        guard let streamURL, let buffer, phase != .live else { return }
        stopPlayer()
        do {
            if let snapshot { try buffer.releaseSnapshot(snapshot.id); self.snapshot = nil }
        } catch { fail(error, ticket: generation); throw error }
        phase = .live; position = 0; heardTitle = liveTitle
        replacePlayer(url: streamURL, local: false)
    }

    func stop() {
        generation = UUID()
        resources.timer?.invalidate()
        resources.timer = nil
        reader.stop(); reader.onTitle = nil
        stopPlayer()
        if let buffer {
            do { try buffer.close() } catch { failure = error }
        }
        buffer = nil; snapshot = nil; streamURL = nil
        phase = .off; liveTitle = ""; heardTitle = ""; position = 0; bufferedDuration = 0
    }

    private func fail(_ error: Error, ticket: UUID) {
        guard generation == ticket else { return }
        stop(); failure = error; phase = .failed
    }

    private func refresh() {
        bufferedDuration = buffer?.metrics.duration ?? 0
        if let player, let snapshot, phase == .delayed {
            // Endliche lokale Medien können am Ende bereits .stopped melden.
            // Der bestehende Fortschritt unterscheidet das vom Startzustand.
            if player.state == .ended || (player.state == .stopped && position > 0) {
                finishSnapshot(); return
            }
            position = max(0, Double(player.time.intValue) / 1000)
            heardTitle = snapshot.title(at: position)
            if endGuard.observe(position: position, duration: snapshot.duration,
                                uptime: ProcessInfo.processInfo.systemUptime) {
                endUsedStallGuard = true; stopPlayer(); finishSnapshot()
            }
        }
    }

    private func replacePlayer(url: URL, local: Bool) {
        stopPlayer()
        let ticket = playbackGeneration, receptionTicket = generation
        let next = makePlayer()
        let delegate = PlayerDelegateShim(onState: { [weak self] state in
            guard let self, self.playbackGeneration == ticket else { return }
            if state == .error { self.fail(TimeshiftFailure.invalidAudio, ticket: receptionTicket) }
            else if local, self.phase == .delayed,
                    state == .ended || (state == .stopped && self.position > 0) { self.finishSnapshot() }
        }, onTime: {})
        shim = delegate; resources.player = next; next.delegate = delegate
        let media = VLCMedia(url: url)
        media.addOption(local ? ":file-caching=300" : ":network-caching=1500")
        next.media = media; next.audio?.volume = 60; next.play()
    }

    private func stopPlayer() {
        playbackGeneration = UUID()
        resources.stopPlayer()
        shim = nil
    }

    private func finishSnapshot() {
        guard let snapshot else { return }
        position = snapshot.duration; heardTitle = snapshot.title(at: position); phase = .finished
    }
}

@MainActor
private final class TimeshiftPlaybackResources {
    var player: VLCMediaPlayer?
    var timer: Timer?

    func stopPlayer() {
        player?.delegate = nil
        player?.stop()
        player = nil
    }
}

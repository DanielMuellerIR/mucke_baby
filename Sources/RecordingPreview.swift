import Foundation
import Combine
import VLCKit

@MainActor
final class RecordingPreview: ObservableObject {
    private static weak var active: RecordingPreview?
    @Published private(set) var currentID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    private var player: VLCMediaPlayer?
    private var delegate: PlayerDelegateShim?
    private var startTask: Task<Void, Never>?
    private let startDeadlineNanoseconds: UInt64

    init(startDeadlineNanoseconds: UInt64 = 5_000_000_000) {
        self.startDeadlineNanoseconds = startDeadlineNanoseconds
    }

    func play(id: UUID, url: URL, volume: Float) {
        stop()
        guard url.isFileURL else { return }
        Self.active?.stop()
        Self.active = self
        error = nil
        currentID = id; isLoading = true
        let ticket = generation
        let next = VLCMediaPlayer()
        let shim = PlayerDelegateShim(onState: { [weak self] state in
            guard let self, self.generation == ticket else { return }
            if state == .error {
                self.stop()
                self.error = String(localized: "Die Aufnahme kann nicht vorgehört werden.")
            } else if state == .ended || state == .stopped { self.stop() }
        }, onTime: { [weak self, weak next] in
            guard let self, self.generation == ticket, let next, next.time.intValue > 0 else { return }
            self.isLoading = false
            self.startTask?.cancel(); self.startTask = nil
        })
        delegate = shim; next.delegate = shim
        next.media = VLCMedia(url: url)
        player = next
        setVolume(volume)
        next.play()
        startTask = Task { [weak self, startDeadlineNanoseconds] in
            do { try await Task.sleep(nanoseconds: startDeadlineNanoseconds) }
            catch { return }
            guard let self, self.generation == ticket, self.isLoading else { return }
            self.stop()
            self.error = String(localized: "Die Aufnahme kann nicht vorgehört werden.")
        }
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        generation &+= 1
        startTask?.cancel(); startTask = nil
        let previous = player
        player = nil; previous?.delegate = nil; delegate = nil
        currentID = nil; isLoading = false; error = nil
        previous?.stop()
    }

    func setVolume(_ volume: Float) {
        let value = volume.isFinite ? max(0, min(1, volume)) : 0
        player?.audio?.volume = Int32(value * 100)
    }
}

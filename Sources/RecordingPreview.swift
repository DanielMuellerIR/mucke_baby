import Foundation
import Combine
import VLCKit

@MainActor
final class RecordingPreview: ObservableObject {
    @Published private(set) var currentID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    private var player: VLCMediaPlayer?
    private var delegate: PlayerDelegateShim?

    func play(id: UUID, url: URL, volume: Float) {
        stop()
        guard url.isFileURL else { return }
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
        }, onTime: { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.isLoading = false
        })
        delegate = shim; next.delegate = shim
        next.media = VLCMedia(url: url)
        next.audio?.volume = Int32(max(0, min(1, volume)) * 100)
        player = next
        next.play()
    }

    func stop() {
        generation &+= 1
        let previous = player
        player = nil; previous?.delegate = nil; delegate = nil
        currentID = nil; isLoading = false
        previous?.stop()
    }
}

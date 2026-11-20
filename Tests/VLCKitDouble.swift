// Eigenes Testmodul mit derselben Importgrenze wie das Framework.
// Ereignisse werden über dieselbe Delegate-Schnittstelle zugestellt.
import Foundation

public protocol VLCMediaPlayerDelegate: AnyObject {
    func mediaPlayerStateChanged(_ notification: Notification)
    func mediaPlayerTimeChanged(_ notification: Notification)
}

public enum VLCMediaPlayerState: Sendable {
    case opening, buffering, esAdded, playing, paused, stopped, ended, error
}

public final class VLCAudioEqualizer {
    public final class Band {
        public var amplification: Float = 0
    }

    public var bands = (0..<10).map { _ in Band() }
    public var preAmplification: Float = 0

    public init() {}
}

public final class VLCAudio {
    public var volume: Int32 = 0
}

public final class VLCTime {
    public var intValue: Int32 = 0
}

public let VLCMediaTracksInformationAudioRate = "rate"

public final class VLCMedia {
    public var tracksInformation: [Any] = [[VLCMediaTracksInformationAudioRate: 48000]]

    public init(stream: InputStream) {}
    public init(url: URL) {}
    public func addOption(_ option: String) {}
}

public final class VLCMediaPlayer {
    public static var latest: VLCMediaPlayer!
    public weak var delegate: VLCMediaPlayerDelegate?
    public var audio: VLCAudio? = VLCAudio()
    public var equalizer: VLCAudioEqualizer?
    public var time = VLCTime()
    public var media: VLCMedia?
    public var state = VLCMediaPlayerState.stopped
    public var isPlaying = false

    public init() { Self.latest = self }
    public func play() { state = .playing }
    public func stop() { state = .stopped }
    public func pause() { state = .paused }

    public func timeEvent() {
        delegate?.mediaPlayerTimeChanged(Notification(name: Notification.Name("time")))
    }

    public func stateEvent() {
        delegate?.mediaPlayerStateChanged(Notification(name: Notification.Name("state"), object: self))
    }
}

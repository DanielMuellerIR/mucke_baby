import Foundation

extension RecognitionResult {
    func song(station: String) -> SongEntry {
        let fallback = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
        return SongEntry(station: station, raw: context.title.isEmpty ? fallback : context.title,
                         artist: track.artist.isEmpty ? nil : track.artist, title: track.title,
                         start: capturedAt,
                         recognition: SongRecognition(recognizedAt: recognizedAt, stationID: context.stationID,
                                                      originalICY: context.title, shazamID: track.shazamID,
                                                      appleMusicURL: track.appleMusicURL))
    }
}

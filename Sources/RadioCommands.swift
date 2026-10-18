import Foundation

@MainActor
protocol RadioCommandTarget: AnyObject {
    var commandStations: [Station] { get }
    var commandStationID: UUID? { get }
    var commandIsActive: Bool { get }
    var commandRecordingRequested: Bool { get }
    var commandSong: SongEntry? { get }
    func commandPlay(_ station: Station)
    func commandStop()
    func commandSetVolume(_ value: Double)
    func commandBookmark(_ song: SongEntry) throws
}

enum RadioCommandError: LocalizedError {
    case stationUnavailable, unsafeURL, recordingEnabled, invalidVolume, noTitle
    var errorDescription: String? {
        switch self {
        case .stationUnavailable: return String(localized: "Dieser Sender ist nicht mehr vorhanden oder deaktiviert.")
        case .unsafeURL: return String(localized: "Dieser Sender hat keine sichere HTTP- oder HTTPS-Adresse.")
        case .recordingEnabled: return String(localized: "Bitte zuerst die Aufnahme in Mucke, Baby! ausschalten. Dieser Kurzbefehl startet keine Aufnahme.")
        case .invalidVolume: return String(localized: "Die Lautstärke muss eine Zahl zwischen 0 und 100 sein.")
        case .noTitle: return String(localized: "Aktuell ist kein Songtitel verfügbar.")
        }
    }
}

@MainActor
struct RadioCommands {
    let target: any RadioCommandTarget
    func play(stationID: UUID) throws {
        guard let station = target.commandStations.first(where: { $0.id == stationID && $0.enabled }) else {
            throw RadioCommandError.stationUnavailable
        }
        guard StreamURLPolicy.validatedURL(station.url) != nil else { throw RadioCommandError.unsafeURL }
        if target.commandStationID == station.id, target.commandIsActive { return }
        guard !target.commandRecordingRequested else { throw RadioCommandError.recordingEnabled }
        target.commandPlay(station)
    }
    func stop() { target.commandStop() }
    func setVolume(percent: Double) throws {
        guard percent.isFinite, (0...100).contains(percent) else { throw RadioCommandError.invalidVolume }
        target.commandSetVolume(percent / 100)
    }
    func currentTitle() throws -> String {
        guard let song = target.commandSong, !song.isPlaceholder,
              !song.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RadioCommandError.noTitle }
        return song.raw
    }
    func bookmarkCurrentTitle() throws -> String {
        let title = try currentTitle()
        guard let song = target.commandSong else { throw RadioCommandError.noTitle }
        try target.commandBookmark(song)
        return title
    }
}

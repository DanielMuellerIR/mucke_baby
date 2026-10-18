import AppIntents

struct RadioStationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Radiosender"
    static let defaultQuery = RadioStationQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct RadioStationQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [RadioStationEntity] {
        let stations = RadioServices.shared.store.enabledStations
        return identifiers.compactMap { id in stations.first(where: { $0.id == id }).map { .init(id: $0.id, name: $0.name) } }
    }
    @MainActor func suggestedEntities() async throws -> [RadioStationEntity] {
        RadioServices.shared.store.enabledStations.map { .init(id: $0.id, name: $0.name) }
    }
    @MainActor func entities(matching string: String) async throws -> [RadioStationEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct PlayRadioStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Radiosender starten"
    static let description = IntentDescription("Startet einen gespeicherten Sender ohne eine Aufnahme zu aktivieren.")
    static let openAppWhenRun = false
    @Parameter(title: "Radiosender") var station: RadioStationEntity
    static var parameterSummary: some ParameterSummary { Summary("\(\.$station) starten") }
    @MainActor func perform() async throws -> some IntentResult {
        try RadioServices.shared.commands.play(stationID: station.id)
        return .result()
    }
}
struct StopRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Radio stoppen"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        RadioServices.shared.commands.stop()
        return .result()
    }
}
struct SetRadioVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Radiolautstärke setzen"
    static let openAppWhenRun = false
    @Parameter(title: "Lautstärke in Prozent", default: 50) var percent: Double
    static var parameterSummary: some ParameterSummary { Summary("Lautstärke auf \(\.$percent) Prozent setzen") }
    @MainActor func perform() async throws -> some IntentResult {
        try RadioServices.shared.commands.setVolume(percent: percent)
        return .result()
    }
}
struct CurrentRadioTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Aktuellen Radiotitel abfragen"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try RadioServices.shared.commands.currentTitle())
    }
}
struct BookmarkRadioTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Aktuellen Radiotitel merken"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try RadioServices.shared.commands.bookmarkCurrentTitle())
    }
}
struct RadioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayRadioStationIntent(), phrases: ["Starte Radio mit \(.applicationName)"], shortTitle: "Radio starten", systemImageName: "radio")
        AppShortcut(intent: StopRadioIntent(), phrases: ["Stoppe Radio mit \(.applicationName)"], shortTitle: "Radio stoppen", systemImageName: "stop.fill")
        AppShortcut(intent: SetRadioVolumeIntent(), phrases: ["Ändere die Lautstärke mit \(.applicationName)"], shortTitle: "Radiolautstärke", systemImageName: "speaker.wave.2")
        AppShortcut(intent: CurrentRadioTitleIntent(), phrases: ["Frage den Radiotitel mit \(.applicationName)"], shortTitle: "Radiotitel abfragen", systemImageName: "music.note")
        AppShortcut(intent: BookmarkRadioTitleIntent(), phrases: ["Merke den Radiotitel mit \(.applicationName)"], shortTitle: "Radiotitel merken", systemImageName: "heart")
    }
}
extension RadioServices: RadioCommandTarget {
    var commands: RadioCommands { RadioCommands(target: self) }
    var commandStations: [Station] { store.stations }
    var commandStationID: UUID? { player.currentStation?.id }
    var commandStationURL: String? { player.currentStation?.url }
    var commandIsActive: Bool { player.hasPlaybackIntent }
    var commandRecordingRequested: Bool { player.recordingRequested }
    var commandSong: SongEntry? { player.hasPlaybackIntent ? player.currentSong : nil }
    func commandPlay(_ station: Station) {
        // Verhindert späteren Autostart beim ersten Öffnen eines Fensters.
        _ = startup.claimAutoplay()
        startup.rememberStation(station.id)
        player.play(station)
    }
    func commandStop() { _ = startup.claimAutoplay(); player.stop() }
    func commandSetVolume(_ value: Double) {
        UserDefaults.standard.set(value, forKey: "volume")
        player.setVolume(Float(value))
    }
    func commandBookmark(_ song: SongEntry) throws { try bookmarks.add(song) }
}

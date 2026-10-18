import Foundation

@MainActor
final class CommandFixture: RadioCommandTarget {
    var commandStations: [Station] = []
    var commandStationID: UUID?
    var commandIsActive = false
    var commandRecordingRequested = false
    var commandSong: SongEntry?
    var starts: [UUID] = []
    var stops = 0
    var volume = 0.4
    var bookmarks: [SongEntry] = []
    var failWrite = false
    func commandPlay(_ station: Station) { starts.append(station.id); commandStationID = station.id; commandIsActive = true }
    func commandStop() { stops += 1; commandIsActive = false }
    func commandSetVolume(_ value: Double) { volume = value }
    func commandBookmark(_ song: SongEntry) throws {
        if failWrite { throw CocoaError(.fileWriteNoPermission) }
        bookmarks.append(song)
    }
}

@main struct RadioCommandsHarness {
    @MainActor static func main() throws {
        let fixture = CommandFixture(), commands = RadioCommands(target: fixture)
        let valid = Station(name: "Eigener Sender", url: "https://example.test/stream")
        var disabled = Station(name: "Ausgeblendet", url: "https://example.test/other"); disabled.enabled = false
        let unsafe = Station(name: "Altdaten", url: "file:///tmp/stream")
        fixture.commandStations = [valid, disabled, unsafe]
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Ungültige Aktion wurde angenommen") } catch {}
        }
        for id in [UUID(), disabled.id, unsafe.id] { rejects { try commands.play(stationID: id) } }
        precondition(fixture.starts.isEmpty)
        fixture.commandRecordingRequested = true
        rejects { try commands.play(stationID: valid.id) }
        precondition(fixture.starts.isEmpty && fixture.commandRecordingRequested)
        fixture.commandRecordingRequested = false
        try commands.play(stationID: valid.id)
        try commands.play(stationID: valid.id)
        precondition(fixture.starts == [valid.id])
        fixture.commandRecordingRequested = true
        try commands.play(stationID: valid.id)
        precondition(fixture.starts.count == 1)
        for value in [-1.0, 101, Double.nan, Double.infinity, -Double.infinity] {
            rejects { try commands.setVolume(percent: value) }
            precondition(fixture.volume == 0.4)
        }
        try commands.setVolume(percent: 12.5); precondition(fixture.volume == 0.125)
        try commands.setVolume(percent: 0); precondition(fixture.volume == 0)
        try commands.setVolume(percent: 100); precondition(fixture.volume == 1)
        rejects { _ = try commands.currentTitle() }
        fixture.commandSong = SongEntry(station: valid.name, raw: "Björk - Grüße 東京 (Live Mix)", artist: "Björk", title: "Grüße 東京 (Live Mix)", start: Date())
        let title = try commands.currentTitle(); precondition(title == fixture.commandSong?.raw)
        fixture.failWrite = true
        rejects { _ = try commands.bookmarkCurrentTitle() }
        precondition(fixture.bookmarks.isEmpty)
        fixture.failWrite = false
        let saved = try commands.bookmarkCurrentTitle()
        precondition(saved == title && fixture.bookmarks == [fixture.commandSong!])
        commands.stop(); precondition(fixture.stops == 1 && !fixture.commandIsActive)
        print("RadioCommands: verwaiste/deaktivierte/unsichere Sender, Aufnahmegrenze, idempotenter Start, endliche Lautstärke, Titel und Schreibfehler OK")
    }
}

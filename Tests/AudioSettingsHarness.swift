import Foundation

@main
struct AudioSettingsHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-AudioTest-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let firstID = UUID(), secondID = UUID()
        let store = AudioSettingsStore(directory: root)
        check(store.configuration == AudioConfiguration() && !store.isReadOnly, "Frische Einstellungen sind nicht neutral")
        try store.setStationGain(6, for: firstID)
        try store.setStationGain(-6, for: secondID)
        try store.update { $0.equalizerEnabled = true; $0.bands = EqualizerPreset.bass.bands }
        let restored = AudioSettingsStore(directory: root)
        check(restored.configuration == store.configuration, "Senderkorrektur/EQ gehen beim Neustart verloren")
        let config = restored.configuration
        check(abs(pow(Double(config.outputVolume(0.25, stationID: firstID) / 0.25), 3) - pow(10, 6.0 / 20)) < 0.001, "Positive Senderkorrektur entspricht nicht +6 dB am AUHAL-Ausgang")
        check(abs(pow(Double(config.outputVolume(0.5, stationID: secondID) / 0.5), 3) - pow(10, -6.0 / 20)) < 0.001, "Negative Senderkorrektur entspricht nicht -6 dB am AUHAL-Ausgang")
        check(config.outputVolume(0.9, stationID: firstID) == 1 && config.isVolumeLimited(0.9, stationID: firstID), "Senderkorrektur kann den Ausgang übersteuern")
        check(config.outputVolume(0, stationID: firstID) == 0 && config.outputVolume(.nan, stationID: firstID) == 0, "Stumm/ungültiger Pegel erfindet Signal")
        let neutral = AudioConfiguration()
        check(neutral.quantizedOutputVolume(0.779, stationID: nil) == 77, "Neutrale Reglerkurve wurde verändert")
        check(config.quantizedOutputVolume(0.779, stationID: firstID) == 97, "Senderkorrektur verliert den tatsächlichen neutralen Ausgangspegel")
        check(AudioConfiguration.outputAmplitude(forVLCVolume: 50) == 0.125, "AUHAL-Reglerskala nicht berücksichtigt")
        check(!config.isVolumeLimited(0.6, stationID: firstID), "Senderkorrektur warnt vor einer nicht erreichten Pegelgrenze")
        for volume: Float in [0.25, 0.5, 0.75] {
            let base = Double(AudioConfiguration.outputAmplitude(forVLCVolume: neutral.quantizedOutputVolume(volume, stationID: nil)))
            for (id, expectedDB) in [(firstID, 6.0), (secondID, -6.0)] {
                let output = Double(AudioConfiguration.outputAmplitude(forVLCVolume: config.quantizedOutputVolume(volume, stationID: id)))
                check(abs(20 * log10(output / base) - expectedDB) < 0.5, "Quantisierte Senderkorrektur verfehlt den dB-Vertrag")
            }
        }
        check(config.gain(for: UUID()) == 0 && config.effectivePreampDB == -6, "Unbekannter Sender oder Headroom falsch")
        try restored.setStationGain(0, for: firstID)
        check(restored.configuration.gain(for: firstID) == 0 && restored.configuration.gain(for: secondID) == -6, "Reset verändert einen anderen Sender")

        let file = root.appendingPathComponent("audio-settings.json")
        let saved = try Data(contentsOf: file), previous = restored.configuration
        for value in [Double.nan, .infinity, -13, 13] {
            do { try restored.setStationGain(value, for: firstID); fatalError("Ungültige Korrektur gespeichert") }
            catch AudioSettingsStore.StoreError.invalid { }
            let bytes = try Data(contentsOf: file)
            check(restored.configuration == previous && bytes == saved, "Abgewiesener Wert verändert Daten")
        }
        do { try restored.update { $0.bands = [0] }; fatalError("Falsche Bandanzahl gespeichert") }
        catch AudioSettingsStore.StoreError.invalid { }
        var document = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        document["formatVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: document)
        try future.write(to: file)
        do { try restored.setStationGain(2, for: firstID); fatalError("Externe Änderung überschrieben") }
        catch AudioSettingsStore.StoreError.changed { }
        check(restored.configuration == previous, "Externe Änderung verändert aktiven Zustand")
        let protected = AudioSettingsStore(directory: root)
        check(protected.isReadOnly && protected.configuration == AudioConfiguration(), "Neuere Datei wird übernommen")
        do { try protected.setStationGain(1, for: firstID); fatalError("Neuere Datei überschrieben") }
        catch AudioSettingsStore.StoreError.readOnly { }
        check(try Data(contentsOf: file) == future, "Unbekannte Dateiversion verändert")
        try Data("{broken".utf8).write(to: file)
        let damaged = AudioSettingsStore(directory: root)
        check(damaged.isReadOnly && damaged.notice != nil, "Beschädigte Datei ungeschützt")
        check(try Data(contentsOf: file) == Data("{broken".utf8), "Beschädigte Datei nicht erhalten")

        try saved.write(to: file)
        let failed = AudioSettingsStore(directory: root), original = failed.configuration
        let backup = root.appendingPathComponent("held-audio.json")
        try fm.moveItem(at: file, to: backup); try fm.createDirectory(at: file, withIntermediateDirectories: false)
        let child = file.appendingPathComponent("keep.txt");try Data("keep".utf8).write(to: child)
        do { try failed.setStationGain(3, for: firstID); fatalError("Schreibfehler wird als Erfolg gemeldet") } catch {}
        check(failed.configuration == original && failed.notice != nil, "Schreibfehler verändert aktiven Audiopfad")
        check(try Data(contentsOf: child) == Data("keep".utf8), "Fehlerpfad entfernt fremde Dateien")
        try fm.removeItem(at: child);try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: backup)
        let linked = AudioSettingsStore(directory: root)
        let backupBytes = try Data(contentsOf: backup)
        check(linked.isReadOnly && backupBytes == saved, "Symlink nicht geschützt")
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("absent.json"))
        let dangling = AudioSettingsStore(directory: root)
        check(dangling.isReadOnly, "Verwaister Link wird als neue Datei behandelt")
        print("AudioSettingsHarness: neutrale Defaults, Pegel, Headroom, Identität, Neustart, ungültige Daten und Schreibschutz OK")
    }
}

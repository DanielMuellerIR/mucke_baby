import Foundation
import Combine

struct AudioConfiguration: Codable, Equatable, Sendable {
    var equalizerEnabled = false
    var bands = Array(repeating: 0.0, count: 10)
    var preampDB = 0.0
    var stationGainDB: [String: Double] = [:]

    func gain(for stationID: UUID?) -> Double {
        stationID.flatMap { stationGainDB[$0.uuidString] } ?? 0
    }

    var effectivePreampDB: Double {
        min(preampDB, -max(0, bands.max() ?? 0))
    }

    // Der gepinnte VLC-Equalizer multipliziert das Eingangssignal mit 0,25.
    // Diesen festen Faktor ausgleichen, bevor die sichtbare Pegelreserve gilt.
    var vlcPreampDB: Double { effectivePreampDB + 20 * log10(4) }

    func outputVolume(_ volume: Float, stationID: UUID?) -> Float {
        let volume = volume.isFinite ? min(1, max(0, volume)) : 0
        return min(1, volume * Float(pow(10, gain(for: stationID) / 20)))
    }

    func isVolumeLimited(_ volume: Float, stationID: UUID?) -> Bool {
        volume.isFinite && volume > 0 && Double(volume) * pow(10, gain(for: stationID) / 20) > 1
    }

    var isValid: Bool {
        bands.count == 10 && bands.allSatisfy { $0.isFinite && (-12...12).contains($0) }
            && preampDB.isFinite && (-12...0).contains(preampDB)
            && stationGainDB.count <= 2048
            && stationGainDB.allSatisfy { UUID(uuidString: $0.key)?.uuidString == $0.key
                && $0.value.isFinite && (-12...12).contains($0.value) }
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat, bass, speech, soft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: String(localized: "Neutral")
        case .bass: String(localized: "Mehr Bass")
        case .speech: String(localized: "Sprachbetonung")
        case .soft: String(localized: "Sanfte Höhen")
        }
    }
    var bands: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0]
        case .speech: [-6, -4, -2, 0, 2, 3, 3, 1, -2, -4]
        case .soft: [0, 0, 0, 0, 0, 0, -1, -3, -5, -6]
        }
    }
}

@MainActor
final class AudioSettingsStore: ObservableObject {
    @Published private(set) var configuration = AudioConfiguration()
    @Published private(set) var notice: String?
    private(set) var isReadOnly = false
    private let file: URL
    private var diskData: Data?
    private struct Document: Codable {
        var formatVersion = 1
        let audio: AudioConfiguration
    }
    enum StoreError: LocalizedError, Equatable {
        case invalid, readOnly, tooLarge, changed
        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "Ungültige Audioeinstellungen.")
            case .readOnly: String(localized: "Die Audioeinstellungen sind geschützt. Bitte Datei und Speicherzugriff prüfen.")
            case .tooLarge: String(localized: "Die Audioeinstellungen überschreiten die zulässige Dateigröße.")
            case .changed: String(localized: "Die Audioeinstellungsdatei wurde außerhalb der App geändert. Bitte die App neu starten.")
            }
        }
    }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuckeBaby", isDirectory: true)
        file = directory.appendingPathComponent("audio-settings.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: file.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil else { return }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024 else {
                throw StoreError.invalid
            }
            let data = try Data(contentsOf: file)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.formatVersion == 1, document.audio.isValid else { throw StoreError.invalid }
            configuration = document.audio; diskData = data
        } catch {
            isReadOnly = true
            notice = String(localized: "Die Audioeinstellungen konnten nicht geladen werden. Die Datei bleibt unverändert; neutrale Einstellungen gelten.")
        }
    }

    func update(_ change: (inout AudioConfiguration) -> Void) throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        var next = configuration
        change(&next)
        guard next.isValid else { throw StoreError.invalid }
        guard next != configuration else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(audio: next))
        guard data.count <= 256 * 1024 else { throw StoreError.tooLarge }
        do {
            // Externe Änderungen und nach dem Laden eingesetzte Links erhalten.
            if FileManager.default.fileExists(atPath: file.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 256 * 1024 else { throw StoreError.readOnly }
                guard try Data(contentsOf: file) == diskData else { throw StoreError.changed }
            } else if diskData != nil { throw StoreError.changed }
            try data.write(to: file, options: .atomic)
            diskData = data; configuration = next; notice = nil
        } catch {
            notice = (error as? StoreError) == .changed ? error.localizedDescription
                : String(localized: "Die Audioeinstellungen konnten nicht gespeichert werden. Die bisherige Einstellung bleibt aktiv.")
            throw error
        }
    }

    func setStationGain(_ value: Double, for id: UUID) throws {
        try update {
            if value == 0 { $0.stationGainDB.removeValue(forKey: id.uuidString) }
            else { $0.stationGainDB[id.uuidString] = value }
        }
    }
}

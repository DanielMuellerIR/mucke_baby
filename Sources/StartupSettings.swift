import Foundation
import Combine

enum StartupMode: String, Codable, CaseIterable, Identifiable {
    case none, lastStation, selectedStation
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return String(localized: "Keine automatische Wiedergabe")
        case .lastStation: return String(localized: "Zuletzt gespielten Sender starten")
        case .selectedStation: return String(localized: "Bestimmten Sender starten")
        }
    }
}

struct StartupConfiguration: Codable, Equatable {
    var formatVersion = 1
    var mode: StartupMode = .none
    var selectedStationID: UUID?
    var lastStationID: UUID?

    func target(in stations: [Station]) -> Station? {
        let id: UUID?
        switch mode {
        case .none: return nil
        case .lastStation: id = lastStationID
        case .selectedStation: id = selectedStationID
        }
        return stations.first { $0.id == id && $0.enabled && StreamURLPolicy.validatedURL($0.url) != nil }
    }
}

@MainActor
final class StartupSettings: ObservableObject {
    @Published private(set) var configuration = StartupConfiguration()
    @Published private(set) var notice: String?
    @Published var showNotice = false
    private(set) var isReadOnly = false
    private let fileURL: URL
    private struct Header: Decodable { let formatVersion: Int }

    init(directory: URL, defaults: UserDefaults = .standard, stations: [Station]) {
        fileURL = directory.appendingPathComponent("startup.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            if let header = try JSONFileRecovery.load(Header.self, from: fileURL) {
                guard header.formatVersion == 1 else {
                    isReadOnly = true
                    report(String(localized: "Die Startauswahl stammt aus einer anderen App-Version. Automatische Wiedergabe bleibt aus."))
                    return
                }
                if let saved = try JSONFileRecovery.load(StartupConfiguration.self, from: fileURL) {
                    configuration = saved
                    return
                }
            }
            // Nur eine erstmalig fehlende Datei übernimmt alte Präferenzen.
            // Nach beschädigten Einstellungen darf keine Wiedergabe überraschend starten.
            if !existed {
                let enabled = stations.filter { $0.enabled && StreamURLPolicy.validatedURL($0.url) != nil }
                let lastID = defaults.string(forKey: "lastStationID").flatMap(UUID.init(uuidString:))
                let target = enabled.first { $0.id == lastID } ?? enabled.first { $0.favorite } ?? enabled.first
                let autoplay = defaults.object(forKey: "autoplayOnLaunch") == nil || defaults.bool(forKey: "autoplayOnLaunch")
                var migrated = StartupConfiguration()
                migrated.mode = autoplay ? .lastStation : .none
                migrated.lastStationID = target?.id
                try persist(migrated)
                configuration = migrated
            } else {
                try persist(configuration)
                report(String(localized: "Die beschädigte Startauswahl wurde gesichert. Automatische Wiedergabe bleibt aus; bitte die Einstellungen prüfen."))
            }
        } catch {
            isReadOnly = true
            report(String(localized: "Die Startauswahl konnte nicht geladen oder gespeichert werden. Automatische Wiedergabe bleibt aus; bitte den Speicherzugriff prüfen."))
        }
    }

    func setMode(_ mode: StartupMode) {
        var next = configuration
        next.mode = mode
        save(next)
    }

    func selectStation(_ id: UUID?) {
        var next = configuration
        next.selectedStationID = id
        save(next)
    }

    func rememberStation(_ id: UUID) {
        guard !isReadOnly, configuration.lastStationID != id else { return }
        var next = configuration
        next.lastStationID = id
        save(next)
    }

    private func save(_ next: StartupConfiguration) {
        guard !isReadOnly else { return }
        do {
            try persist(next)
            configuration = next
            notice = nil
        } catch {
            report(String(localized: "Die Startauswahl konnte nicht gespeichert werden. Die bisherige Auswahl bleibt erhalten."))
        }
    }

    private func persist(_ next: StartupConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
    }

    private func report(_ message: String) { notice = message; showNotice = true }
}

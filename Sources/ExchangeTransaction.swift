import Foundation
import CryptoKit
import Darwin

enum ExchangeDiskError: LocalizedError {
    case invalidJournal, changed, pending, invalidFile
    var errorDescription: String? {
        switch self {
        case .invalidJournal: String(localized: "Die Importwiederherstellung ist beschädigt oder stammt aus einer anderen Version. Bestehende Dateien bleiben geschützt.")
        case .changed: String(localized: "Lokale Dateien wurden seit der Vorschau geändert. Bitte eine neue Vorschau öffnen.")
        case .pending: String(localized: "Ein gespeicherter Import muss zuerst abgeschlossen werden. Bitte die App neu starten.")
        case .invalidFile: String(localized: "Die lokale Datei ist nicht regulär lesbar oder überschreitet die zulässige Größe.")
        }
    }
}

enum ExchangeTransaction {
    static let journalName = ".mucke-library-import.json"
    static let allowedNames: Set<String> = ["stations.json", "bookmarks.json"]
    private static let payloadLimit = 16 * 1024 * 1024
    private static let journalLimit = 96 * 1024 * 1024
    struct Change {
        let name: String
        let before: Data?
        let after: Data
    }
    struct Recovery {
        let values: [String: Data]
        let pending: Bool
        let notice: String?
    }
    enum Phase { case beforeCommit, afterCommit }
    typealias Validator = (String, Data) throws -> Void
    private struct Entry: Codable {
        let name: String
        let before: Data?
        let after: Data
        let beforeHash: String?
        let afterHash: String
    }
    private struct Journal: Codable {
        let formatVersion: Int
        let id: UUID
        let entries: [Entry]
    }

    static func read(_ url: URL, limit: Int = 16 * 1024 * 1024) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard url.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else { throw ExchangeDiskError.invalidFile }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ExchangeDiskError.invalidFile }
        return data
    }

    static func commit(_ changes: [Change], in directory: URL, validate: Validator,
                       phase: (Phase) throws -> Void = { _ in }) throws -> Recovery {
        guard directory.isFileURL, !changes.isEmpty, changes.count <= 2,
              Set(changes.map(\.name)).count == changes.count,
              changes.allSatisfy({ allowedNames.contains($0.name) && $0.after.count <= payloadLimit
                  && ($0.before?.count ?? 0) <= payloadLimit }) else { throw ExchangeDiskError.invalidFile }
        let journalURL = directory.appendingPathComponent(journalName)
        guard try read(journalURL, limit: journalLimit) == nil else { throw ExchangeDiskError.pending }
        for change in changes {
            try validate(change.name, change.after)
            let target = directory.appendingPathComponent(change.name)
            guard try read(target) == change.before else { throw ExchangeDiskError.changed }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
               attributes[.immutable] as? Bool == true || attributes[.appendOnly] as? Bool == true {
                throw ExchangeDiskError.invalidFile
            }
        }
        let entries = changes.map { Entry(name: $0.name, before: $0.before, after: $0.after,
                                         beforeHash: $0.before.map(hash), afterHash: hash($0.after)) }
        let data = try JSONEncoder().encode(Journal(formatVersion: 1, id: UUID(), entries: entries))
        guard data.count <= journalLimit else { throw ExchangeDiskError.invalidFile }
        try phase(.beforeCommit)
        try Task.checkCancellation()
        for change in changes {
            guard try read(directory.appendingPathComponent(change.name)) == change.before else { throw ExchangeDiskError.changed }
        }
        try writeAtomic(data, to: journalURL, exclusive: true)
        // Ab hier ist der vollständige neue Bestand verbindlich. Ein Fehler beim
        // kanonischen Nachschreiben darf keinen fehlgeschlagenen Import vortäuschen.
        do {
            try phase(.afterCommit)
            return try recover(in: directory, validate: validate)!
        } catch {
            return Recovery(values: Dictionary(uniqueKeysWithValues: changes.map { ($0.name, $0.after) }),
                            pending: true, notice: pendingNotice(error))
        }
    }

    static func recover(in directory: URL, requiredNames: Set<String>? = nil, validate: Validator) throws -> Recovery? {
        let journalURL = directory.appendingPathComponent(journalName)
        guard let raw = try read(journalURL, limit: journalLimit) else { return nil }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: raw) }
        catch { throw ExchangeDiskError.invalidJournal }
        guard journal.formatVersion == 1, !journal.entries.isEmpty, journal.entries.count <= 2,
              requiredNames == nil || Set(journal.entries.map(\.name)) == requiredNames,
              Set(journal.entries.map(\.name)).count == journal.entries.count,
              journal.entries.allSatisfy({ allowedNames.contains($0.name) && $0.after.count <= payloadLimit
                  && ($0.before?.count ?? 0) <= payloadLimit && hash($0.after) == $0.afterHash
                  && $0.before.map(hash) == $0.beforeHash }) else { throw ExchangeDiskError.invalidJournal }
        for entry in journal.entries {
            do { try validate(entry.name, entry.after) }
            catch { throw ExchangeDiskError.invalidJournal }
        }
        let values = Dictionary(uniqueKeysWithValues: journal.entries.map { ($0.name, $0.after) })
        do {
            // Vor dem ersten Schreiben alle Ziele prüfen, damit externe Änderungen
            // erhalten bleiben. Ein späterer Schreibfehler lässt das Journal bestehen.
            for entry in journal.entries {
                let current = try read(directory.appendingPathComponent(entry.name))
                guard current == entry.before || current == entry.after else { throw ExchangeDiskError.changed }
            }
            for entry in journal.entries {
                let target = directory.appendingPathComponent(entry.name)
                let current = try read(target)
                guard current == entry.before || current == entry.after else { throw ExchangeDiskError.changed }
                if current != entry.after { try writeAtomic(entry.after, to: target) }
            }
            guard try read(journalURL, limit: journalLimit) == raw else { throw ExchangeDiskError.changed }
            // unlink entfernt kein Verzeichnis, selbst wenn ein Ziel ausgetauscht wurde.
            guard unlink(journalURL.path) == 0 else { throw posixError() }
            return Recovery(values: values, pending: false, notice: nil)
        } catch { return Recovery(values: values, pending: true, notice: pendingNotice(error)) }
    }

    private static func pendingNotice(_ error: Error) -> String {
        String(localized: "Import gespeichert. Der Dateiabschluss steht noch aus; bis zum Neustart sind diese Daten geschützt.")
            + " " + error.localizedDescription
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func writeAtomic(_ data: Data, to destination: URL, exclusive: Bool = false) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".mucke-exchange-" + UUID().uuidString + ".tmp")
        let descriptor = open(staged.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close(); _ = unlink(staged.path) }
        try writer.write(contentsOf: data); try writer.synchronize(); try writer.close()
        let status = exclusive
            ? renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
            : rename(staged.path, destination.path)
        guard status == 0 else { throw posixError() }
    }
}

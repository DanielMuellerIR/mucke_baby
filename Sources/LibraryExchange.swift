import Foundation

struct ExchangeImportRequest: Identifiable {
    let id = UUID()
    let plan: ExchangeMergePlan
    let quickSlots: [UUID?]
    let stationBytes: Data?
    let bookmarkBytes: Data?
}

@MainActor
enum LibraryExchange {
    static func snapshot(store: Store, bookmarks: BookmarkStore) -> ExchangeLibrary {
        ExchangeLibrary(stations: store.stations, groups: store.groups, bookmarks: bookmarks.entries)
    }
    static func prepare(_ data: Data, store: Store, bookmarks: BookmarkStore) throws -> ExchangeImportRequest {
        try writable(store: store, bookmarks: bookmarks)
        let incoming = try ExchangeCodec.decode(data)
        let plan = try ExchangeMergePlan(local: snapshot(store: store, bookmarks: bookmarks), incoming: incoming)
        let stationBytes = try ExchangeTransaction.read(store.stationsURL)
        let bookmarkBytes = try ExchangeTransaction.read(bookmarks.fileURL)
        guard stationBytes == store.diskData, bookmarkBytes == bookmarks.diskData else { throw ExchangeDiskError.changed }
        return ExchangeImportRequest(plan: plan, quickSlots: store.quickSlots, stationBytes: stationBytes, bookmarkBytes: bookmarkBytes)
    }
    @discardableResult
    static func apply(_ request: ExchangeImportRequest, choices: [ExchangeMergePlan.Key: ExchangeMergePlan.Choice],
                      store: Store, bookmarks: BookmarkStore,
                      phase: (ExchangeTransaction.Phase) throws -> Void = { _ in }) throws -> String? {
        try writable(store: store, bookmarks: bookmarks)
        guard snapshot(store: store, bookmarks: bookmarks) == request.plan.local,
              store.quickSlots == request.quickSlots else { throw ExchangeDiskError.changed }
        guard try ExchangeTransaction.read(store.stationsURL) == request.stationBytes,
              try ExchangeTransaction.read(bookmarks.fileURL) == request.bookmarkBytes else { throw ExchangeDiskError.changed }
        let next = try request.plan.resolved(selections: choices)
        guard next != request.plan.local else { return nil }
        let collection = StationCollection(stations: next.stations, groups: next.groups, quickSlots: request.quickSlots)
        let stationData = try ExchangeCodec.dateEncoder().encode(collection)
        let bookmarkData = try ExchangeCodec.dateEncoder().encode(BookmarkDocument(entries: next.bookmarks))
        let storedBookmarks = try ExchangeCodec.dateDecoder().decode(BookmarkDocument.self, from: bookmarkData)
        let result = try ExchangeTransaction.commit([
            .init(name: "stations.json", before: request.stationBytes, after: stationData),
            .init(name: "bookmarks.json", before: request.bookmarkBytes, after: bookmarkData)
        ], in: store.dir, validate: LibraryExchangeStorage.validate, phase: phase)
        store.adoptImport(collection, data: stationData, pending: result.pending, notice: result.notice)
        bookmarks.adoptImport(storedBookmarks.entries, data: bookmarkData, pending: result.pending, notice: result.notice)
        return result.notice
    }
    private static func writable(store: Store, bookmarks: BookmarkStore) throws {
        guard !store.isReadOnly, !bookmarks.isReadOnly,
              bookmarks.fileURL.deletingLastPathComponent().standardizedFileURL == store.dir.standardizedFileURL else {
            throw ExchangeDiskError.invalidFile
        }
    }
    static func export(store: Store, bookmarks: BookmarkStore, to destination: URL, recordingDirectory: URL) throws {
        let data = try ExchangeCodec.encode(snapshot(store: store, bookmarks: bookmarks))
        try writeExport(data, to: destination, protectedDirectories: [store.dir, recordingDirectory])
    }
    static func writeExport(_ data: Data, to destination: URL, protectedDirectories: [URL]) throws {
        guard destination.isFileURL else { throw ExchangeDiskError.invalidFile }
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        for directory in protectedDirectories {
            let protected = directory.resolvingSymlinksInPath().standardizedFileURL
            guard target.path != protected.path, !target.path.hasPrefix(protected.path + "/") else { throw ExchangeDiskError.invalidFile }
            if let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
                let files = FileManager.default.enumerator(at: protected, includingPropertiesForKeys: [.fileResourceIdentifierKey])
                while let file = files?.nextObject() as? URL {
                    if let id = try? file.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
                       (id as? NSObject)?.isEqual(targetID) == true { throw ExchangeDiskError.invalidFile }
                }
            }
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw ExchangeDiskError.invalidFile }
        try data.write(to: destination, options: .atomic)
    }
}

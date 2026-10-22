import Foundation

enum LibraryExchangeStorage {
    static func recover(in directory: URL) throws -> ExchangeTransaction.Recovery? {
        try ExchangeTransaction.recover(in: directory, requiredNames: ExchangeTransaction.allowedNames, validate: validate)
    }
    static func validate(name: String, data: Data) throws {
        switch name {
        case "stations.json":
            struct Header: Decodable { let formatVersion: Int }
            guard try JSONDecoder().decode(Header.self, from: data).formatVersion == 2 else { throw ExchangeFormatError.unsupportedVersion }
            _ = try ExchangeCodec.decode(data)
            let collection = try JSONDecoder().decode(StationCollection.self, from: data)
            guard collection.formatVersion == 2, collection.quickSlots.count == 5 else { throw ExchangeFormatError.invalidData }
        case "bookmarks.json":
            let document = try ExchangeCodec.dateDecoder().decode(BookmarkDocument.self, from: data)
            try ExchangeCodec.validate(ExchangeLibrary(stations: [], groups: [], bookmarks: document.entries))
        default: throw ExchangeDiskError.invalidJournal
        }
    }
}


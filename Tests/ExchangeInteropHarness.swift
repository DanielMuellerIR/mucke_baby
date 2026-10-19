import Foundation

// Derselbe Harness wird getrennt gegen beide Produktions-Codecs kompiliert.
@main
enum ExchangeInteropHarness {
    static func main() throws {
        let args = CommandLine.arguments
        switch args[1] {
        case "generate":
            let version = Int(args[3])!
            let date = Date(timeIntervalSince1970: 1_792_000_000.123)
            let station = Station(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                name: "Eigener Name — Grüße 東京", url: "https://radio.example/Live?x=Case", favorite: true,
                radioBrowserID: UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
            let group = StationGroup(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                name: "Meine Gruppe", stationIDs: [station.id])
            var books = [SongBookmark(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                station: station.name, raw: "Artist - Song (Live)", artist: "Artist", title: "Song (Live)", heardAt: date, savedAt: date)]
            if version >= 2 {
                for (index, mix) in ["Live Mix", "Club Mix"].enumerated() {
                    let id = index == 0 ? "66666666-6666-4666-8666-666666666666" : "77777777-7777-4777-8777-777777777777"
                    let context: RecognitionListeningContext? = version < 3 ? nil : .init(
                        outputID: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                        revision: index == 0 ? 0 : UInt64.max,
                        position: index == 0 ? nil : 123.456789,
                        receivedAt: index == 0 ? nil : date.addingTimeInterval(-90.125))
                    let original = "Artist — Grüße 東京 (" + mix + ")"
                    let origin = SongRecognition(recognizedAt: date.addingTimeInterval(15), stationID: station.id,
                        originalICY: original, shazamID: "catalog-123", appleMusicURL: URL(string: "https://music.apple.com/de/album/track/123?i=456"), listening: context)
                    books.append(SongBookmark(id: UUID(uuidString: id)!, station: station.name, raw: original,
                        artist: "Catalog artist", title: "Catalog title", heardAt: date, savedAt: date.addingTimeInterval(30), recognition: origin))
                }
            }
            try write(ExchangeLibrary(stations: [station], groups: [group], bookmarks: books), to: args[2])
        case "reencode": try write(read(args[2]), to: args[3])
        case "verify":
            let actual = try read(args[2]), expected = try read(args[3])
            precondition(actual == expected, "Austausch verliert Felder")
            let repeatPlan = try ExchangeMergePlan(local: expected, incoming: actual)
            precondition(repeatPlan.rows.allSatisfy { $0.state == .unchanged }, "Wiederholung erzeugt Konflikte")
            let repeated = try repeatPlan.resolved(selections: [:])
            precondition(repeated == expected)
        case "merge":
            let incoming = try read(args[2]), local = try read(args[3])
            let plan = try ExchangeMergePlan(local: local, incoming: incoming)
            try write(plan.resolved(selections: [:]), to: args[4])
        case "reject":
            do { _ = try read(args[2]); fatalError("Ungültige Datei akzeptiert") } catch {}
        case "context-conflict":
            let original = try read(args[2])
            var incoming = original
            let index = incoming.bookmarks.firstIndex { $0.recognition?.listening != nil }!
            let old = incoming.bookmarks[index].recognition!
            incoming.bookmarks[index].recognition = SongRecognition(recognizedAt: old.recognizedAt, stationID: old.stationID,
                originalICY: old.originalICY, shazamID: old.shazamID, appleMusicURL: old.appleMusicURL,
                listening: .init(outputID: UUID(), revision: 42, position: nil, receivedAt: nil))
            let plan = try ExchangeMergePlan(local: original, incoming: incoming)
            let row = plan.rows.first { $0.id.kind == .bookmark && $0.id.id == incoming.bookmarks[index].id }!
            precondition(row.state == .conflict && row.localDescription != row.incomingDescription,
                         "Reiner Hörkontextkonflikt ist unsichtbar")
            let kept = try plan.resolved(selections: [:])
            let adopted = try plan.resolved(selections: [row.id: .useIncoming])
            precondition(kept == original && adopted == incoming)
            let both = try plan.resolved(selections: [row.id: .keepBoth])
            precondition(both.bookmarks.count == original.bookmarks.count + 1)
            var independent = original
            independent.bookmarks = independent.bookmarks.filter { $0.recognition != nil }
            for index in independent.bookmarks.indices { independent.bookmarks[index].id = UUID() }
            let mixPlan = try ExchangeMergePlan(local: original, incoming: independent)
            let mixRows = mixPlan.rows.filter { $0.id.kind == .bookmark }
            precondition(mixRows.count == 2 && mixRows.allSatisfy { $0.state == .unchanged },
                         "Verschiedene Radio-Mixe verlieren ihre eigene Identität")
        default: fatalError("Unbekannter Prüfmodus")
        }
    }
    static func read(_ path: String) throws -> ExchangeLibrary {
        try ExchangeCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }
    static func write(_ library: ExchangeLibrary, to path: String) throws {
        try ExchangeCodec.encode(library, at: Date(timeIntervalSince1970: 1_792_000_000.123))
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

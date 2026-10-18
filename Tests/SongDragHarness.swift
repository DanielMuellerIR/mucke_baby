import Foundation

private final class DragReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var completions = 0
    func receive(_ url: URL?, _ error: Error?) {
        let value: Result<Data, Error>
        if let error { value = .failure(error) }
        else if let url { value = Result { try Data(contentsOf: url) } }
        else { value = .failure(CocoaError(.fileReadUnknown)) }
        lock.lock(); result = value; completions += 1; lock.unlock()
    }
    var snapshot: (Int, Result<Data, Error>?) {
        lock.lock(); defer { lock.unlock() }; return (completions, result)
    }
}
private final class DragState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var mainThread = false
    private var cancelled = false
    func began() { lock.lock(); count += 1; mainThread = Thread.isMainThread; lock.unlock() }
    func didCancel() { lock.lock(); cancelled = true; lock.unlock() }
    var snapshot: (Int, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }; return (count, mainThread, cancelled)
    }
}
@main enum SongDragHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 8)
        while !predicate() {
            check(Date() < deadline, "Dateiprovider hängt")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("MuckeBaby-Drag-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Björk - Grüße (Live Remix).m4a")
        let bytes = Data((0..<8192).map { UInt8($0 % 251) }); try bytes.write(to: source)
        let state = DragState()
        let provider = SongDragProvider.make(fileBase: "Björk - Grüße (Live Remix)") {
            state.began(); return source
        }
        check(state.snapshot.0 == 0, "Provider-Erzeugung rendert vor Abruf")
        check(provider.suggestedName == "Björk - Grüße (Live Remix)", "Unicode/Mix oder Basisname verändert")
        check(provider.hasItemConformingToTypeIdentifier("com.apple.m4a-audio"), "Kein konkreter M4A-Typ")
        let received = DragReceipt()
        _ = provider.loadFileRepresentation(forTypeIdentifier: "com.apple.m4a-audio") { received.receive($0, $1) }
        try await wait { received.snapshot.0 > 0 }
        check(try received.snapshot.1!.get() == bytes, "Übertragene Bytes verändert")
        check(state.snapshot.0 == 1 && !state.snapshot.1, "Rendering läuft auf Main oder mehrfach")
        check(try Data(contentsOf: source) == bytes, "Quelle geändert")

        let failed = DragReceipt()
        let failureProvider = SongDragProvider.make(fileBase: "failure") { throw NSError(domain: "DragFixture", code: 17) }
        _ = failureProvider.loadFileRepresentation(forTypeIdentifier: "com.apple.m4a-audio") { failed.receive($0, $1) }
        try await wait { failed.snapshot.0 > 0 }
        switch failed.snapshot.1! {
        case .success: fatalError("Renderfehler verschluckt")
        case .failure: break
        }

        let cancelled = DragReceipt(), cancellationState = DragState()
        let cancellationProvider = SongDragProvider.make(fileBase: "cancel") {
            cancellationState.began()
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { cancellationState.didCancel(); throw error }
            return source
        }
        let progress = cancellationProvider.loadFileRepresentation(forTypeIdentifier: "com.apple.m4a-audio") { cancelled.receive($0, $1) }
        try await wait { cancellationState.snapshot.0 == 1 }
        progress.cancel()
        try await wait { cancelled.snapshot.0 > 0 && cancellationState.snapshot.2 }
        switch cancelled.snapshot.1! {
        case .success: fatalError("Abgebrochener Dateiprovider liefert Erfolg")
        case .failure: break
        }
        check(try Data(contentsOf: source) == bytes, "Abbruch ändert Quelle")
        print("Song drag: lazily rendered off Main, exact bytes, concrete M4A, errors and cancellation OK")
    }
}

import Foundation

private actor RenderGate {
    private var pending: [URL: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls = 0
    func render(_ url: URL) async {
        calls += 1
        await withCheckedContinuation { pending[url] = $0 }
    }
    func urls() -> Set<URL> { Set(pending.keys) }
    func finish(_ url: URL) throws {
        try Data("prepared \(calls)".utf8).write(to: url)
        pending.removeValue(forKey: url)!.resume()
    }
}

@main struct ExportEditorHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    private static func wait(_ gate: RenderGate, count: Int) async {
        for _ in 0..<2000 {
            if await gate.urls().count == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Renderer nicht gestartet")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuckeBaby-EditorTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav"), original = Data("original".utf8)
        try original.write(to: source)
        let gate = RenderGate()
        let model = ExportEditorModel(source: source, offset: 2, duration: 5,
                                      inspector: { _ in ExportAudioBounds(start: 0, end: 12) },
                                      renderer: { _, _, _, url in await gate.render(url) }, temporaryRoot: root)
        await model.load()
        let first = Task { try await model.prepare() }
        await wait(gate, count: 1)
        let oldURL = await gate.urls().first!
        model.setStart(1)
        let second = Task { try await model.prepare() }
        await wait(gate, count: 2)
        let newURL = await gate.urls().subtracting([oldURL]).first!
        try await gate.finish(newURL)
        let rendered = try await second.value
        try await gate.finish(oldURL)
        do { _ = try await first.value; fatalError("Altes Ergebnis wurde übernommen") } catch is CancellationError {}
        check(model.preparedURL == rendered && model.message == nil && !model.isPreparing, "Alte Antwort ersetzt neue Vorschau")
        check(!FileManager.default.fileExists(atPath: oldURL.path), "Verworfene Datei bleibt liegen")
        check(try await model.prepare() == rendered, "Unveränderte Auswahl wird neu gerendert")
        check(await gate.calls == 2, "Cache erzeugt weitere Audiodatei")
        let folder = model.temporaryDirectory
        model.close()
        check(!FileManager.default.fileExists(atPath: folder.path), "Abgeschlossene Vorschau wird nicht aufgeräumt")

        let closing = ExportEditorModel(source: source, offset: 2, duration: 5,
                                        inspector: { _ in ExportAudioBounds(start: 0, end: 12) },
                                        renderer: { _, _, _, url in await gate.render(url) }, temporaryRoot: root)
        await closing.load()
        let pending = Task { try await closing.prepare() }
        await wait(gate, count: 1)
        let lateURL = await gate.urls().first!
        closing.close()
        try await gate.finish(lateURL)
        do { _ = try await pending.value; fatalError("Schließen akzeptiert späte Ausgabe") } catch is CancellationError {}
        check(closing.preparedURL == nil && !FileManager.default.fileExists(atPath: closing.temporaryDirectory.path), "Später Renderer hinterlässt Dateien")
        check(try Data(contentsOf: source) == original, "Vorschau ändert Original")
        print("ExportEditorHarness: alte Antworten, Cache, Abbruch, Schließen und Temp-Cleanup OK")
    }
}

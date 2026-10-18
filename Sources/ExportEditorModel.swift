import Foundation
import Combine

@MainActor
final class ExportEditorModel: ObservableObject {
    typealias Inspector = @Sendable (URL) async throws -> ExportAudioBounds
    typealias Renderer = @Sendable (URL, ExportCut, SongExporter.Mode, URL) async throws -> Void

    let source: URL
    let temporaryDirectory: URL
    @Published private(set) var range: ExportRange?
    @Published private(set) var isLoading = true
    @Published private(set) var isPreparing = false
    @Published private(set) var startAdjustment = 0.0
    @Published private(set) var endAdjustment = 0.0
    @Published private(set) var faded = false
    @Published private(set) var preparedURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var revision: UInt64 = 0
    private(set) var isClosed = false
    private let offset: Double
    private let duration: Double
    private let inspector: Inspector
    private let renderer: Renderer
    private var didLoad = false
    private var requests = LatestRequestGeneration()
    private var pending: Task<URL, Error>?
    private var workCount = 0

    init(source: URL, offset: Double, duration: Double, metadata: SongExportMetadata? = nil,
         inspector: @escaping Inspector = { try await SongExporter.inspect(source: $0) },
         renderer: Renderer? = nil, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.source = source; self.offset = offset; self.duration = duration
        self.inspector = inspector
        self.renderer = renderer ?? { source, cut, mode, destination in
            try await SongExporter.export(source: source, offset: cut.start, duration: cut.duration,
                                          mode: mode, metadata: metadata, to: destination)
        }
        temporaryDirectory = temporaryRoot.appendingPathComponent("MuckeBaby-ExportPreview-" + UUID().uuidString)
    }

    deinit { try? FileManager.default.removeItem(at: temporaryDirectory) }

    var cut: ExportCut {
        get throws {
            guard let range else { throw SongExporter.ExportError.notReadable }
            return try range.cut(startAdjustment: startAdjustment, endAdjustment: endAdjustment)
        }
    }

    var validationMessage: String? {
        guard range != nil else { return nil }
        do { _ = try cut; return nil }
        catch { return error.localizedDescription }
    }

    var canPrepare: Bool { !isClosed && !isLoading && range != nil && validationMessage == nil }

    func load() async {
        guard !didLoad, !isClosed else { return }
        didLoad = true
        do {
            let audio = try await inspector(source)
            try Task.checkCancellation()
            guard !isClosed else { return }
            range = try ExportRange(offset: offset, duration: duration, audio: audio)
        } catch is CancellationError { }
        catch { if !isClosed { message = error.localizedDescription } }
        if !isClosed { isLoading = false }
    }

    func setStart(_ value: Double) {
        guard !isClosed, startAdjustment != value else { return }
        startAdjustment = value; invalidate()
    }
    func setEnd(_ value: Double) {
        guard !isClosed, endAdjustment != value else { return }
        endAdjustment = value; invalidate()
    }
    func setFaded(_ value: Bool) {
        guard !isClosed, faded != value else { return }
        faded = value; invalidate()
    }
    func reset() {
        guard !isClosed else { return }
        startAdjustment = 0; endAdjustment = 0; invalidate()
    }

    func prepare() async throws -> URL {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let selected = try cut
        if let preparedURL, FileManager.default.isReadableFile(atPath: preparedURL.path) { return preparedURL }
        pending?.cancel()
        let ticket = requests.begin()
        let destination = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let renderer = renderer, source = source, mode: SongExporter.Mode = faded ? .faded : .hardCut
        isPreparing = true; message = nil; workCount += 1
        let task = Task<URL, Error> {
            try await renderer(source, selected, mode, destination)
            try Task.checkCancellation()
            return destination
        }
        pending = task
        defer {
            workCount -= 1
            if isClosed && workCount == 0 { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
        do {
            let url = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !isClosed, requests.accepts(ticket) else { throw CancellationError() }
            preparedURL = url; pending = nil; isPreparing = false
            return url
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if requests.accepts(ticket) {
                pending = nil; isPreparing = false
                if !(error is CancellationError) { message = error.localizedDescription }
            }
            throw error
        }
    }

    func cancelPreparation() { invalidate() }

    func close() {
        guard !isClosed else { return }
        isClosed = true; invalidate()
        if workCount == 0 { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private func invalidate() {
        requests.invalidate(); revision &+= 1
        pending?.cancel(); pending = nil; isPreparing = false; message = nil
        if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) }
        preparedURL = nil
    }
}

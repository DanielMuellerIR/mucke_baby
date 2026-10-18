import Foundation
import Combine

struct ExportJob: Identifiable, Sendable {
    let id: UUID
    let metadata: SongExportMetadata
    let source: URL?
    let offset: Double
    let duration: Double
}

@MainActor
final class ExportQueue: ObservableObject {
    static let limit = 100
    typealias Renderer = @Sendable (ExportJob, URL, SongExporter.Mode) async throws -> URL
    enum Status: Equatable {
        case waiting, exporting, succeeded(URL), failed(String), cancelled
        var finished: Bool {
            switch self { case .waiting, .exporting: return false; default: return true }
        }
    }
    struct Item: Identifiable {
        let job: ExportJob
        var status: Status = .waiting
        var id: UUID { job.id }
    }
    @Published private(set) var items: [Item]
    @Published private(set) var isRunning = false
    @Published private(set) var didStart = false
    private let renderer: Renderer
    private var worker: Task<Void, Never>?
    private var active: Task<URL, Error>?
    private var stopRequested = false

    init(jobs: [ExportJob], renderer: @escaping Renderer = { job, directory, mode in
        guard let source = job.source else { throw SongExporter.ExportError.notReadable }
        return try await SongExporter.exportUnique(source: source, offset: job.offset, duration: job.duration,
                                                  mode: mode, metadata: job.metadata, directory: directory)
    }) {
        let valid = !jobs.isEmpty && jobs.count <= Self.limit && Set(jobs.map(\.id)).count == jobs.count
        items = valid ? jobs.map { Item(job: $0) } : []
        self.renderer = renderer
    }

    var finishedCount: Int { items.filter { $0.status.finished }.count }
    var succeededCount: Int { items.filter { if case .succeeded = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var cancelledCount: Int { items.filter { $0.status == .cancelled }.count }

    func start(directory: URL, mode: SongExporter.Mode) {
        guard !didStart, !items.isEmpty, directory.isFileURL else { return }
        didStart = true; isRunning = true
        worker = Task {
            for index in items.indices {
                guard items[index].status == .waiting, !stopRequested else { continue }
                items[index].status = .exporting
                let job = items[index].job, renderer = renderer
                let task = Task { try await renderer(job, directory, mode) }
                active = task
                do {
                    let url = try await task.value
                    // Ein bereits atomar übernommenes Ergebnis bleibt auch bei spätem Abbruch erfolgreich.
                    items[index].status = .succeeded(url)
                } catch is CancellationError { items[index].status = .cancelled }
                catch { items[index].status = .failed(error.localizedDescription) }
                active = nil
            }
            isRunning = false; worker = nil
        }
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .waiting: items[index].status = .cancelled
        case .exporting: active?.cancel()
        default: break
        }
    }

    func cancelAll() {
        stopRequested = true
        for index in items.indices where items[index].status == .waiting { items[index].status = .cancelled }
        active?.cancel()
    }
}

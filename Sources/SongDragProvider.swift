import Foundation
import UniformTypeIdentifiers

enum SongDragProvider {
    typealias Renderer = @Sendable () async throws -> URL
    static let contentType = UTType(filenameExtension: "m4a", conformingTo: .audio) ?? .mpeg4Audio

    static func make(fileBase: String, renderer: @escaping Renderer) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = ExportFileNaming.safeBase(fileBase)
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            // Recorder-Abfragen und Rendering dürfen die Klickauswahl nicht auf Main blockieren.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let url = try await renderer()
                    try Task.checkCancellation()
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

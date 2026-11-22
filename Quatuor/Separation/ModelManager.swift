import Foundation

nonisolated struct ModelDownloadProgress: Sendable {
    let fileIndex: Int
    let fileCount: Int
    var bytesReceived: Int64 = 0
    var totalBytes: Int64? = nil

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}

@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private static let repo = "iky1e/demucs-mlx"
    private static let modelName = "htdemucs_ft"
    private static let files = [
        "\(modelName).safetensors",
        "\(modelName)_config.json"
    ]

    var modelDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("Quatuor", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Self.modelName, isDirectory: true)
    }

    var isModelDownloaded: Bool {
        let fm = FileManager.default
        return Self.files.allSatisfy { fm.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }
    }

    func ensureModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        if isModelDownloaded { return }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        for (index, filename) in Self.files.enumerated() {
            let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(filename)")!
            let destination = modelDirectory.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }

            progress(ModelDownloadProgress(fileIndex: index + 1, fileCount: Self.files.count))
            try await Self.download(from: url, to: destination, fileIndex: index + 1,
                                    fileCount: Self.files.count, progress: progress)
        }
    }

    nonisolated static func download(
        from url: URL,
        to destination: URL,
        fileIndex: Int,
        fileCount: Int,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(fileIndex: fileIndex, fileCount: fileCount, progress: progress,
                                            destination: destination) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            // The async download convenience API can suppress download progress callbacks.
            // Use the delegate-driven task and move its temporary file inside the callback.
            session.downloadTask(with: url).resume()
        }
    }
}

// URLSession serializes its delegate callbacks; the lock additionally guarantees a single completion.
nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let fileIndex: Int
    let fileCount: Int
    let progress: @Sendable (ModelDownloadProgress) -> Void

    private let destination: URL?
    private let completion: @Sendable (Result<Void, any Swift.Error>) -> Void
    private let lock = NSLock()
    private var finished = false

    init(fileIndex: Int, fileCount: Int, progress: @escaping @Sendable (ModelDownloadProgress) -> Void,
         destination: URL? = nil,
         completion: @escaping @Sendable (Result<Void, any Swift.Error>) -> Void = { _ in }) {
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.progress = progress
        self.destination = destination
        self.completion = completion
    }

    private func finish(_ result: Result<Void, any Swift.Error>) {
        lock.lock()
        let shouldComplete = !finished
        finished = true
        lock.unlock()
        if shouldComplete { completion(result) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(ModelDownloadProgress(fileIndex: fileIndex, fileCount: fileCount,
                                       bytesReceived: totalBytesWritten,
                                       totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let destination else { throw URLError(.cannotCreateFile) }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Swift.Error)?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

}

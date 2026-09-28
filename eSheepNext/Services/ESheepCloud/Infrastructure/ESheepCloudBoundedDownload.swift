import Foundation

/// A separate serial delegate queue receives buffers, never one actor hop per
/// byte. The response cannot allocate beyond the manifest's compressed size.
final class ESheepCloudBoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    // These properties are only accessed on the serial delegate queue.
    private var data = Data()
    private var failure: Error?
    private var continuation: CheckedContinuation<Data, Error>?

    init(expectedBytes: Int, configuration: URLSessionConfiguration = .default) {
        self.expectedBytes = expectedBytes
        self.configuration = configuration
    }

    func receive(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                data.reserveCapacity(expectedBytes)
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: url)
                lock.lock()
                self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = ESheepCloudInfrastructureError.transferFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(expectedBytes) else {
            failure = ESheepCloudCheckpointError.sizeLimit
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive buffer: Data) {
        guard buffer.count <= expectedBytes - data.count else {
            failure = ESheepCloudCheckpointError.sizeLimit
            dataTask.cancel()
            return
        }
        data.append(buffer)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard let continuation else { return }
        self.continuation = nil
        if let failure = failure ?? error { continuation.resume(throwing: failure) }
        else if data.count != expectedBytes { continuation.resume(throwing: ESheepCloudCheckpointError.digestMismatch) }
        else { continuation.resume(returning: data) }
    }
}

import Foundation
import Synchronization

/// Downloads into memory up to a byte limit: a declared length over it is
/// refused at the response, and a body that grows past it is cancelled. Only
/// a 200 response is delivered. Used for media artwork and for OpenSearch
/// descriptions (TASK-288).
///
/// Its callbacks run on the session's own serial queue; the downloads are
/// behind a mutex, read and changed only inside it.
nonisolated final class CappedDataFetcher: NSObject, URLSessionDataDelegate {
    /// Whether a download that started at `original` may follow a redirect
    /// to `target`. A refused redirect delivers nil.
    typealias RedirectPolicy = @Sendable (_ original: URL, _ target: URL) -> Bool

    private let limit: Int
    private let downloads = Mutex<[Int: Download]>([:])
    /// Set once in `init`, before the fetcher is shared, and only read after:
    /// the session needs the fetcher as its delegate, so it cannot be a `let`.
    nonisolated(unsafe) private var session: URLSession!

    private struct Download {
        var data = Data()
        var refused = false
        let allowsRedirect: RedirectPolicy?
        let completion: @Sendable (Data?) -> Void
    }

    init(configuration: URLSessionConfiguration, limit: Int) {
        self.limit = limit
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Starts downloading `url` without cookies; `completion` gets the body,
    /// or nil, on the session's queue. Returns what cancels the download.
    /// `allowsRedirect` nil follows every redirect.
    func start(_ url: URL, allowsRedirect: RedirectPolicy? = nil,
               completion: @escaping @Sendable (Data?) -> Void) -> () -> Void {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        downloads.withLock {
            $0[task.taskIdentifier] = Download(allowsRedirect: allowsRedirect, completion: completion)
        }
        task.resume()
        return { [weak task] in task?.cancel() }
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let id = task.taskIdentifier
        let policy = downloads.withLock { $0[id]?.allowsRedirect }
        guard let policy else {
            completionHandler(request)
            return
        }
        if let original = task.originalRequest?.url, let target = request.url, policy(original, target) {
            completionHandler(request)
            return
        }
        // Not followed: the task goes on to the redirect response itself,
        // which is not a 200 and is refused there; marked here as well.
        downloads.withLock { $0[id]?.refused = true }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        // -1 when the length is not declared: the body is counted instead.
        guard status == 200, response.expectedContentLength <= Int64(limit) else {
            downloads.withLock { $0[dataTask.taskIdentifier]?.refused = true }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = limit
        let id = dataTask.taskIdentifier
        let overLimit = downloads.withLock { downloads -> Bool in
            // In place through the subscript: copying the record out would copy
            // its buffer for every chunk.
            guard downloads[id]?.refused == false else { return false }
            downloads[id]?.data.append(data)
            guard let count = downloads[id]?.data.count, count > limit else { return false }
            downloads[id]?.refused = true
            downloads[id]?.data = Data()
            return true
        }
        if overLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let download = downloads.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        download.completion(error == nil && !download.refused ? download.data : nil)
    }
}

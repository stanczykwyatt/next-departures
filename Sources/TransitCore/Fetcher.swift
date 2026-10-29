import Foundation

/// The one place the app talks to the network. It fetches feed files and nothing else.
///
/// - Only https, and only hosts on the list it's given, which the app builds from your feeds.
/// - A redirect to any other host is refused, so a feed can't send the app somewhere else.
/// - No cookies, no cache on disk, nothing stored between requests. The only header besides the
///   usual ones names the app, so an agency can see who's asking.
/// - Each download has a size limit and is stopped as soon as it passes it.
public final class FeedFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case notAllowed(String)
        case redirectedElsewhere
        case http(Int, retryAfter: TimeInterval?)
        case tooLarge
        case offline
        case network(String)
    }

    public struct Response: Sendable {
        /// Nil when the server said the file hasn't changed.
        public var data: Data?
        public var etag: String?
        public var lastModified: String?
    }

    public static let userAgent = "NextDepartures/0.1 (+https://github.com/stanczykwyatt/next-departures)"

    private struct Load {
        var data = Data()
        var limit: Int
        var host: String
        var response: HTTPURLResponse?
        var failure: Failure?
        var continuation: CheckedContinuation<Response, Error>
    }

    private let lock = NSLock()
    private var loads: [Int: Load] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Fetches `url` if its host is in `allowed`. With `etag` or `lastModified` from last time, a
    /// file that hasn't changed isn't downloaded again.
    public func fetch(_ url: URL, allowed: Set<String>, limit: Int, etag: String? = nil, lastModified: String? = nil) async throws -> Response {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), allowed.contains(host) else {
            throw Failure.notAllowed(url.host ?? url.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { loads[task.taskIdentifier] = Load(limit: limit, host: host, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = lock.withLock { loads[task.taskIdentifier]?.host }
        if request.url?.scheme?.lowercased() == "https", let host, request.url?.host?.lowercased() == host {
            completionHandler(request)
        } else {
            lock.withLock { loads[task.taskIdentifier]?.failure = .redirectedElsewhere }
            completionHandler(nil)
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allow: Bool = lock.withLock {
            guard var load = loads[dataTask.taskIdentifier] else { return false }
            load.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(load.limit) { load.failure = .tooLarge }
            loads[dataTask.taskIdentifier] = load
            return load.failure == nil
        }
        completionHandler(allow ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = lock.withLock {
            let id = dataTask.taskIdentifier
            guard let load = loads[id] else { return true }
            if load.data.count + data.count > load.limit {
                loads[id]?.failure = .tooLarge
                return true
            }
            // Appended in place: copying the load out and back would copy everything so far, each time.
            loads[id]?.data.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let load = lock.withLock({ loads.removeValue(forKey: task.taskIdentifier) }) else { return }
        load.continuation.resume(with: Self.result(load, error: error))
    }

    private static func result(_ load: Load, error: Error?) -> Result<Response, Error> {
        if let failure = load.failure { return .failure(failure) }
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled { return .failure(CancellationError()) }
            if code == .notConnectedToInternet || code == .networkConnectionLost || code == .dataNotAllowed { return .failure(Failure.offline) }
            return .failure(Failure.network(error.localizedDescription))
        }
        guard let response = load.response else { return .failure(Failure.network("no response")) }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let modified = response.value(forHTTPHeaderField: "Last-Modified")
        switch response.statusCode {
        case 200:
            return .success(Response(data: load.data, etag: etag, lastModified: modified))
        case 304:
            return .success(Response(data: nil, etag: etag, lastModified: modified))
        default:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            return .failure(Failure.http(response.statusCode, retryAfter: retry))
        }
    }
}

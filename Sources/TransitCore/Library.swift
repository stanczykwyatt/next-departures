import Foundation

/// Anything that can fetch a feed file. The app uses `FeedFetcher`; tests use made-up feeds.
public protocol Fetching: Sendable {
    func fetch(_ url: URL, allowed: Set<String>, limit: Int, etag: String?, lastModified: String?) async throws -> FeedFetcher.Response
}

extension FeedFetcher: Fetching {}

/// Keeps each feed's schedule on disk and up to date, reads the stop times for the stops you've
/// picked, and fetches live updates when asked.
///
/// Everything it keeps is in one folder: the schedule zip as the agency published it, the index
/// read from it, and the stop times for your stops. Live updates are never written down.
public actor FeedLibrary {
    /// Agencies usually publish a new schedule weekly at most, so checking once a day is plenty.
    /// Checking is one request that comes back empty if nothing changed.
    public static let scheduleCheckInterval: TimeInterval = 24 * 3600
    /// The largest schedule or live file it will download. Metro Transit's schedule is about 27 MB.
    public static let scheduleLimit = 250_000_000
    public static let realtimeLimit = 20_000_000

    public struct Meta: Codable, Sendable, Equatable {
        public var etag: String?
        public var lastModified: String?
        public var checked: Date
        public var downloaded: Date
        /// Where the schedule was downloaded from, so pasting a new address fetches it fresh.
        public var source: URL?
    }

    public struct Live: Sendable {
        public var feed: RealtimeFeed
        public var fetched: Date
        /// Whether live trip updates came in, as some feeds only publish alerts.
        public var hasTripUpdates: Bool
        /// What went wrong, if one of the feed's files couldn't be fetched or read.
        public var failure: Error?
    }

    private struct CallsFile: Codable {
        var key: String
        var calls: StopCalls
    }

    public let folder: URL
    private let fetcher: Fetching
    private let now: @Sendable () -> Date
    private let retryPause: Duration
    private var indexes: [String: FeedIndex] = [:]
    private var zips: [String: ZipArchive] = [:]
    private var callCache: [String: CallsFile] = [:]
    private var scheduleTasks: [String: Task<FeedIndex, Error>] = [:]
    /// The last failed download of each feed's schedule with nothing to fall back on, and how many
    /// in a row, so it isn't tried again on every look.
    private var failures: [String: (date: Date, error: Error, count: Int)] = [:]
    /// After a failed check with a schedule already here, wait this long before checking again.
    public static let retryAfterFailure: TimeInterval = 3600

    public init(folder: URL, fetcher: Fetching, now: @escaping @Sendable () -> Date = Date.init, retryPause: Duration = .seconds(2)) {
        self.folder = folder
        self.fetcher = fetcher
        self.now = now
        self.retryPause = retryPause
    }

    private func directory(_ feed: FeedSource) throws -> URL {
        guard FeedSource.isValidID(feed.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = folder.appendingPathComponent(feed.id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Schedule

    /// The feed's index, downloading the schedule the first time and checking for a new one once a day.
    public func index(for feed: FeedSource, refresh: Bool = false) async throws -> FeedIndex {
        // One download at a time per feed, however many callers ask at once.
        if let running = scheduleTasks[feed.id] { return try await running.value }
        let task = Task { try await loadIndex(feed, refresh: refresh) }
        scheduleTasks[feed.id] = task
        defer { scheduleTasks[feed.id] = nil }
        return try await task.value
    }

    /// The index already on disk, without going to the network.
    public func cachedIndex(for feed: FeedSource) -> FeedIndex? {
        if let index = indexes[feed.id] { return index }
        guard let folder = try? directory(feed), let meta = readMeta(folder), meta.source == feed.schedule || meta.source == nil,
              let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(FeedIndex.self, from: data), index.version == FeedIndex.formatVersion else { return nil }
        indexes[feed.id] = index
        return index
    }

    public func meta(for feed: FeedSource) -> Meta? {
        (try? directory(feed)).flatMap(readMeta)
    }

    private func loadIndex(_ feed: FeedSource, refresh: Bool) async throws -> FeedIndex {
        let folder = try directory(feed)
        let cached = cachedIndex(for: feed)
        let meta = readMeta(folder)
        let due = meta.map { now().timeIntervalSince($0.checked) >= Self.scheduleCheckInterval || $0.source != feed.schedule } ?? true
        if let cached, !refresh, !due { return cached }
        // With nothing to fall back on, a failed first download waits a minute, then two, up to an
        // hour, unless you ask again yourself.
        if cached == nil, !refresh, let failure = failures[feed.id],
           now().timeIntervalSince(failure.date) < min(3600, 60 * pow(2, Double(failure.count - 1))) {
            throw failure.error
        }

        let response: FeedFetcher.Response
        do {
            let sameSource = meta?.source == feed.schedule && cached != nil
            response = try await fetcher.fetch(
                feed.schedule, allowed: feed.hosts, limit: Self.scheduleLimit,
                etag: sameSource ? meta?.etag : nil, lastModified: sameSource ? meta?.lastModified : nil
            )
        } catch {
            // Offline or the agency's server is down: yesterday's schedule is still good, and the
            // check is tried again in an hour rather than on every look.
            if let cached {
                postpone(meta, folder)
                return cached
            }
            remember(error, feed)
            throw error
        }
        guard let data = response.data else {
            var checked = meta ?? Meta(checked: now(), downloaded: now(), source: feed.schedule)
            checked.checked = now()
            writeMeta(checked, folder)
            if let cached { return cached }
            throw ZipArchive.Failure.notAZip
        }
        let zip: ZipArchive
        let index: FeedIndex
        do {
            zip = try ZipArchive(data)
            index = try ScheduleReader.index(zip)
        } catch {
            // A broken new schedule isn't downloaded again until tomorrow, and the old one stays.
            if var checked = meta, let cached {
                checked.checked = now()
                writeMeta(checked, folder)
                return cached
            }
            remember(error, feed)
            throw error
        }
        // Written to a new file and swapped in, so a crash partway leaves the old schedule whole.
        try data.write(to: folder.appendingPathComponent("schedule.zip"), options: .atomic)
        try JSONEncoder().encode(index).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        writeMeta(Meta(etag: response.etag, lastModified: response.lastModified, checked: now(), downloaded: now(), source: feed.schedule), folder)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("calls.json"))
        indexes[feed.id] = index
        zips[feed.id] = zip
        callCache[feed.id] = nil
        failures[feed.id] = nil
        return index
    }

    private func remember(_ error: Error, _ feed: FeedSource) {
        guard !(error is CancellationError) else { return }
        failures[feed.id] = (now(), error, (failures[feed.id]?.count ?? 0) + 1)
    }

    /// Marks the schedule as checked long enough ago that the next check is in an hour.
    private func postpone(_ meta: Meta?, _ folder: URL) {
        guard var meta else { return }
        meta.checked = now().addingTimeInterval(Self.retryAfterFailure - Self.scheduleCheckInterval)
        writeMeta(meta, folder)
    }

    private func zip(for feed: FeedSource) throws -> ZipArchive {
        if let zip = zips[feed.id] { return zip }
        let data = try Data(contentsOf: try directory(feed).appendingPathComponent("schedule.zip"), options: .mappedIfSafe)
        let zip = try ZipArchive(data)
        zips[feed.id] = zip
        return zip
    }

    /// Lets go of the schedule zip in memory once the stop times are read. It's reopened from disk
    /// if you pick another stop.
    public func releaseZips() {
        zips.removeAll()
    }

    /// Scheduled calls at `stopIDs` and their platforms, read from the zip only when the stops or
    /// the schedule change.
    public func calls(for feed: FeedSource, stops stopIDs: Set<String>) async throws -> StopCalls {
        let index = try await self.index(for: feed)
        let family = stopIDs.reduce(into: Set<String>()) { $0.formUnion(index.stopFamily($1)) }
        let meta = readMeta(try directory(feed))
        let key = family.sorted().joined(separator: ",") + "|" + (meta.map { "\($0.downloaded.timeIntervalSince1970)" } ?? "")
        if let cached = callCache[feed.id], cached.key == key { return cached.calls }
        let file = try directory(feed).appendingPathComponent("calls.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(CallsFile.self, from: data), saved.key == key {
            callCache[feed.id] = saved
            return saved.calls
        }
        let calls = try ScheduleReader.calls(try zip(for: feed), at: family)
        let saved = CallsFile(key: key, calls: calls)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
        callCache[feed.id] = saved
        return calls
    }

    // MARK: Live

    /// Fetches the feed's live trip updates and alerts. Neither is kept on disk. If one of the two
    /// fails, the other is still used, and the failure is passed along.
    public func live(for feed: FeedSource) async throws -> Live {
        let urls = Array(Set([feed.tripUpdates, feed.alerts].compactMap { $0 })).sorted { $0.absoluteString < $1.absoluteString }
        var merged = RealtimeFeed()
        var stamps: [Date] = []
        var failure: Error?
        var tripUpdatesRead = false
        for url in urls {
            do {
                guard let data = try await fetchLive(url, feed: feed) else { continue }
                let part = try RealtimeFeed.decode(data)
                if url == feed.tripUpdates {
                    merged.tripUpdates += part.tripUpdates
                    merged.version = part.version
                    tripUpdatesRead = true
                }
                if url == feed.alerts { merged.alerts += part.alerts }
                if let stamp = part.timestamp { stamps.append(stamp) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = failure ?? error
            }
        }
        if let failure, stamps.isEmpty, merged.tripUpdates.isEmpty, merged.alerts.isEmpty { throw failure }
        // The oldest part decides whether the whole is fresh.
        merged.timestamp = stamps.min()
        return Live(feed: merged, fetched: now(), hasTripUpdates: tripUpdatesRead, failure: failure)
    }

    /// Busy agency servers now and then answer with an error for a moment, so one that does is
    /// asked once more, a couple of seconds later, before giving up until the next check.
    private func fetchLive(_ url: URL, feed: FeedSource) async throws -> Data? {
        do {
            return try await fetcher.fetch(url, allowed: feed.hosts, limit: Self.realtimeLimit, etag: nil, lastModified: nil).data
        } catch FeedFetcher.Failure.http(let code, nil) where code == 404 || code >= 500 {
            try await Task.sleep(for: retryPause)
            return try await fetcher.fetch(url, allowed: feed.hosts, limit: Self.realtimeLimit, etag: nil, lastModified: nil).data
        }
    }

    /// Removes everything kept for a feed, when you remove it.
    public func forget(_ feed: FeedSource) {
        indexes[feed.id] = nil
        zips[feed.id] = nil
        callCache[feed.id] = nil
        if FeedSource.isValidID(feed.id) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(feed.id, isDirectory: true))
        }
    }

    // MARK: Files

    private func readMeta(_ folder: URL) -> Meta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeMeta(_ meta: Meta, _ folder: URL) {
        try? JSONEncoder().encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }
}

/// How long to wait before asking a feed again: every 30 seconds while you're looking, longer
/// after each failure, and at least as long as the server asks.
public struct Backoff: Sendable, Equatable {
    public static let interval: TimeInterval = 30
    public static let longest: TimeInterval = 10 * 60

    public private(set) var failures = 0
    private var retryAfter: TimeInterval?

    public init() {}

    public var delay: TimeInterval {
        let backoff = failures == 0 ? Self.interval : min(Self.longest, Self.interval * pow(2, Double(failures)))
        return max(backoff, min(retryAfter ?? 0, 3600))
    }

    public mutating func succeeded() {
        failures = 0
        retryAfter = nil
    }

    public mutating func failed(_ error: Error) {
        failures = min(failures + 1, 10)
        if case FeedFetcher.Failure.http(_, let retry?) = error { retryAfter = retry } else { retryAfter = nil }
    }
}

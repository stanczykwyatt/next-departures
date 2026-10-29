import Foundation
import Observation
import TransitCore

/// Everything the menu and the window show: your stops, each feed's schedule, and the latest
/// live updates. Live updates are fetched only when asked, which the app does while you're looking.
@MainActor
@Observable
final class TransitModel {
    let library: FeedLibrary
    let preferences: Preferences
    var now: () -> Date

    private(set) var saved: [SavedStop]
    private(set) var customFeeds: [FeedSource]
    private(set) var indexes: [String: FeedIndex] = [:]
    private(set) var calls: [String: StopCalls] = [:]
    private(set) var live: [String: FeedLibrary.Live] = [:]
    /// The last thing that went wrong with each feed, in a sentence.
    private(set) var problems: [String: String] = [:]
    /// Feeds whose schedule is downloading or being read.
    private(set) var preparing: Set<String> = []
    private(set) var lastChecked: [String: Date] = [:]
    private var backoff: [String: Backoff] = [:]
    private var refreshing = false

    /// Even when asked again and again, a feed is never fetched more than this often.
    static let minimumGap: TimeInterval = 10

    init(library: FeedLibrary, preferences: Preferences, now: @escaping () -> Date = Date.init) {
        self.library = library
        self.preferences = preferences
        self.now = now
        saved = preferences.stops
        customFeeds = preferences.customFeeds
    }

    var feeds: [FeedSource] { FeedSource.presets + customFeeds }

    func feed(_ id: String) -> FeedSource? {
        feeds.first { $0.id == id }
    }

    /// Feeds with at least one of your stops: the only ones whose live updates are ever fetched.
    var activeFeeds: [FeedSource] {
        let ids = Set(saved.map(\.feedID))
        return feeds.filter { ids.contains($0.id) }
    }

    // MARK: Loading

    /// Reads what's already on disk, with no network: each feed's index and your stops' times.
    func load() async {
        for feed in feeds {
            if let index = await library.cachedIndex(for: feed) { indexes[feed.id] = index }
        }
        for feed in activeFeeds where indexes[feed.id] != nil {
            await loadCalls(feed)
        }
    }

    /// Brings everything up to date for the stops you've picked: the schedule once a day, and the
    /// live feed if it's been 30 seconds, or longer after errors.
    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for feed in activeFeeds {
            if Task.isCancelled { return }
            if indexes[feed.id] == nil || calls[feed.id] == nil {
                await prepare(feed)
            } else {
                // The daily check, without blocking the live update below.
                Task { await self.checkSchedule(feed) }
            }
            guard indexes[feed.id] != nil, feed.tripUpdates != nil || feed.alerts != nil, isDue(feed, force: force) else { continue }
            lastChecked[feed.id] = now()
            do {
                let fresh = try await library.live(for: feed)
                live[feed.id] = fresh
                if let failure = fresh.failure {
                    // Trip updates came in, so only the alerts failed: keep the regular pace, or
                    // working predictions would go stale between slower checks.
                    if fresh.hasTripUpdates {
                        backoff[feed.id, default: Backoff()].succeeded()
                    } else {
                        backoff[feed.id, default: Backoff()].failed(failure)
                    }
                    problems[feed.id] = Describe.problem(failure)
                } else {
                    backoff[feed.id, default: Backoff()].succeeded()
                    problems[feed.id] = nil
                }
            } catch is CancellationError {
                continue
            } catch {
                backoff[feed.id, default: Backoff()].failed(error)
                problems[feed.id] = Describe.problem(error)
            }
        }
    }

    /// Whether the live feed is due another look.
    func isDue(_ feed: FeedSource, force: Bool) -> Bool {
        guard let last = lastChecked[feed.id] else { return true }
        let gap = now().timeIntervalSince(last)
        if force, problems[feed.id] == nil { return gap >= Self.minimumGap }
        return gap >= (backoff[feed.id] ?? Backoff()).delay - 1
    }

    /// When to look again, given what the last look found.
    func nextDelay(_ feed: FeedSource) -> TimeInterval {
        (backoff[feed.id] ?? Backoff()).delay
    }

    /// Downloads and reads a feed's schedule. The window asks first, since it can be tens of megabytes.
    /// `asked` is true when you clicked Download Schedule, which tries again even after a failure.
    func prepare(_ feed: FeedSource, asked: Bool = false) async {
        guard !preparing.contains(feed.id) else { return }
        preparing.insert(feed.id)
        defer { preparing.remove(feed.id) }
        do {
            indexes[feed.id] = try await library.index(for: feed, refresh: asked && indexes[feed.id] == nil)
            if problems[feed.id] != nil, live[feed.id] == nil { problems[feed.id] = nil }
            await loadCalls(feed)
        } catch {
            problems[feed.id] = Describe.problem(error)
        }
    }

    private func checkSchedule(_ feed: FeedSource) async {
        guard let index = try? await library.index(for: feed), index != indexes[feed.id] else { return }
        indexes[feed.id] = index
        await loadCalls(feed)
    }

    private func loadCalls(_ feed: FeedSource) async {
        let stops = Set(saved.filter { $0.feedID == feed.id }.flatMap(\.stopIDs))
        guard !stops.isEmpty else {
            calls[feed.id] = nil
            return
        }
        do {
            calls[feed.id] = try await library.calls(for: feed, stops: stops)
        } catch {
            problems[feed.id] = Describe.problem(error)
        }
        await library.releaseZips()
    }

    // MARK: What to show

    func departures(for stop: SavedStop, limit: Int = 5) -> [Departure] {
        guard let index = indexes[stop.feedID], let calls = calls[stop.feedID] else { return [] }
        return DepartureBoard.departures(
            at: stop.stopIDs, index: index, calls: calls, realtime: currentLive(stop.feedID), now: now(), limit: limit, routes: Set(stop.routes)
        )
    }

    /// The next ride that's really leaving: not canceled, and stopping here.
    func nextDeparture(for stop: SavedStop) -> Departure? {
        departures(for: stop, limit: 8).first { $0.status != .canceled && $0.status != .skipped }
    }

    /// The live feed, if it was fetched recently enough to trust. After you look away, departures
    /// go back to the timetable once it's five minutes old, even if the feed itself had no timestamp.
    private func currentLive(_ feedID: String) -> RealtimeFeed? {
        guard let live = live[feedID], now().timeIntervalSince(live.fetched) < DepartureBoard.staleAfter else { return nil }
        return live.feed
    }

    func alerts(for stop: SavedStop) -> [Alert] {
        guard let index = indexes[stop.feedID] else { return [] }
        let trips = Set(departures(for: stop, limit: 10).compactMap(\.tripID))
        let directions = calls[stop.feedID].flatMap { AlertMatcher.directions(at: stop.stopIDs, index: index, calls: $0) }
        return AlertMatcher.alerts(
            for: stop.stopIDs, index: index, feed: currentLive(stop.feedID), now: now(), tripIDs: trips, onlyRoutes: Set(stop.routes), directions: directions
        )
    }

    /// Whether the departures shown for a feed include live data right now.
    func isLive(_ feedID: String) -> Bool {
        guard let live = live[feedID], live.hasTripUpdates else { return false }
        return DepartureBoard.isFresh(live.feed, now: now()) && now().timeIntervalSince(live.fetched) < DepartureBoard.staleAfter
    }

    func routes(for stop: SavedStop) -> [Route] {
        guard let index = indexes[stop.feedID] else { return [] }
        return Array(Set(stop.stopIDs.flatMap { index.routes(at: $0) })).sorted()
    }

    func timeZone(_ feedID: String) -> TimeZone {
        indexes[feedID]?.timeZone ?? .current
    }

    // MARK: Changing your stops

    func search(_ query: String, feedID: String, route: String?) -> [StopGroup] {
        guard let index = indexes[feedID] else { return [] }
        return StopSearch.find(query, in: index, route: route)
    }

    var isFull: Bool { saved.count >= Preferences.maxStops }

    func add(_ group: StopGroup, feedID: String, routes: [String] = []) async {
        guard !isFull, !saved.contains(where: { $0.feedID == feedID && Set($0.stopIDs) == Set(group.stopIDs) }) else { return }
        saved.append(SavedStop(feedID: feedID, stopIDs: group.stopIDs, name: group.name, routes: routes))
        preferences.stops = saved
        if let feed = feed(feedID) {
            await loadCalls(feed)
            await refresh()
        }
    }

    func remove(_ stop: SavedStop) async {
        saved.removeAll { $0.id == stop.id }
        preferences.stops = saved
        if let feed = feed(stop.feedID) { await loadCalls(feed) }
        if !saved.contains(where: { $0.feedID == stop.feedID }) {
            live[stop.feedID] = nil
            lastChecked[stop.feedID] = nil
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        saved.move(fromOffsets: source, toOffset: destination)
        preferences.stops = saved
    }

    func setRoutes(_ routes: [String], for stop: SavedStop) {
        guard let at = saved.firstIndex(where: { $0.id == stop.id }) else { return }
        saved[at].routes = routes
        preferences.stops = saved
    }

    // MARK: Feeds you add

    enum FeedProblem: Error, Equatable {
        case name, schedule(FeedSource.URLProblem), tripUpdates(FeedSource.URLProblem), alerts(FeedSource.URLProblem), tooMany
    }

    /// Adds a feed from addresses you pasted. Only the schedule is required.
    func addFeed(name: String, schedule: String, tripUpdates: String, alerts: String) -> Result<FeedSource, FeedProblem> {
        guard customFeeds.count < Preferences.maxFeeds else { return .failure(.tooMany) }
        let name = Describe.clean(name, limit: 60)
        func optional(_ text: String, _ wrap: (FeedSource.URLProblem) -> FeedProblem) -> Result<URL?, FeedProblem> {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(nil) }
            return FeedSource.check(text).map { Optional($0) }.mapError(wrap)
        }
        let scheduleURL: URL
        switch FeedSource.check(schedule) {
        case .success(let url): scheduleURL = url
        case .failure(let problem): return .failure(.schedule(problem))
        }
        let trips: URL?, alertsURL: URL?
        switch optional(tripUpdates, FeedProblem.tripUpdates) {
        case .success(let url): trips = url
        case .failure(let problem): return .failure(problem)
        }
        switch optional(alerts, FeedProblem.alerts) {
        case .success(let url): alertsURL = url
        case .failure(let problem): return .failure(problem)
        }
        let feed = FeedSource(
            id: "custom-" + UUID().uuidString.lowercased().prefix(8), name: name.isEmpty ? (scheduleURL.host ?? "Feed") : name,
            area: scheduleURL.host ?? "", schedule: scheduleURL, tripUpdates: trips, alerts: alertsURL
        )
        customFeeds.append(feed)
        preferences.customFeeds = customFeeds
        return .success(feed)
    }

    func removeFeed(_ feed: FeedSource) async {
        guard !feed.isPreset else { return }
        customFeeds.removeAll { $0.id == feed.id }
        preferences.customFeeds = customFeeds
        saved.removeAll { $0.feedID == feed.id }
        preferences.stops = saved
        indexes[feed.id] = nil
        calls[feed.id] = nil
        live[feed.id] = nil
        problems[feed.id] = nil
        await library.forget(feed)
    }
}

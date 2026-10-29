import Foundation
import Testing
@testable import TransitCore

/// A clock the test moves forward by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite("Feed library")
struct LibraryTests {
    let folder = TestFolder()
    let fetcher = FakeFetcher()
    let clock = TestClock(Lakeside.now)
    let feed = Lakeside.feed

    private func library() -> FeedLibrary {
        let clock = clock
        return FeedLibrary(folder: folder.url, fetcher: fetcher, now: { clock.now }, retryPause: .milliseconds(1))
    }

    @Test func downloadsTheScheduleOnceAndKeepsIt() async throws {
        fetcher.set(feed.schedule, Lakeside.zip(), etag: "\"v1\"")
        let library = library()
        let index = try await library.index(for: feed)
        #expect(index.routes.count == 3)
        #expect(fetcher.count == 1)
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 1)
        // A new start reads it from disk, with no network.
        let again = self.library()
        #expect(await again.cachedIndex(for: feed) == index)
        _ = try await again.index(for: feed)
        #expect(fetcher.count == 1)
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("lakeside").path).sorted()
        #expect(saved == ["index.json", "meta.json", "schedule.zip"])
    }

    @Test func checksForANewScheduleOnceADay() async throws {
        fetcher.set(feed.schedule, Lakeside.zip(), etag: "\"v1\"", modified: "Thu, 22 Oct 2026 17:05:34 GMT")
        let library = library()
        _ = try await library.index(for: feed)
        clock.advance(FeedLibrary.scheduleCheckInterval - 60)
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 1)

        // A day on, it asks whether the file changed. It hasn't.
        clock.advance(120)
        fetcher.set(feed.schedule, nil)
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 2)
        #expect(fetcher.requests.last?.etag == "\"v1\"")
        #expect(fetcher.requests.last?.modified == "Thu, 22 Oct 2026 17:05:34 GMT")
        // And doesn't ask again for another day.
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 2)

        // A day later, there's a new one with another route.
        clock.advance(FeedLibrary.scheduleCheckInterval + 1)
        let routes = Lakeside.files["routes.txt"]! + "\nNEW,LT,8,Harbor Express,3,,,"
        fetcher.set(feed.schedule, Lakeside.zip(["routes.txt": routes]), etag: "\"v2\"")
        #expect(try await library.index(for: feed).routes.count == 4)
    }

    @Test func keepsTheOldScheduleWhenOffline() async throws {
        fetcher.set(feed.schedule, Lakeside.zip())
        let library = library()
        _ = try await library.index(for: feed)
        clock.advance(FeedLibrary.scheduleCheckInterval * 3)
        fetcher.fail(feed.schedule, FeedFetcher.Failure.offline)
        #expect(try await library.index(for: feed).routes.count == 3)

        let fresh = FeedSource(id: "other", name: "Other", area: "", schedule: URL(string: "https://feeds.lakeside.example.org/other.zip")!)
        fetcher.fail(fresh.schedule, FeedFetcher.Failure.offline)
        await #expect(throws: FeedFetcher.Failure.offline) { try await library.index(for: fresh) }
    }

    @Test func aFailedCheckWaitsAnHour() async throws {
        fetcher.set(feed.schedule, Lakeside.zip())
        let library = library()
        _ = try await library.index(for: feed)
        clock.advance(FeedLibrary.scheduleCheckInterval + 1)
        fetcher.fail(feed.schedule, FeedFetcher.Failure.http(503, retryAfter: nil))
        _ = try await library.index(for: feed)
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 2)
        clock.advance(FeedLibrary.retryAfterFailure + 1)
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 3)
    }

    @Test func aFailedFirstDownloadBacksOff() async throws {
        fetcher.fail(feed.schedule, FeedFetcher.Failure.offline)
        let library = library()
        await #expect(throws: FeedFetcher.Failure.offline) { try await library.index(for: feed) }
        await #expect(throws: FeedFetcher.Failure.offline) { try await library.index(for: feed) }
        #expect(fetcher.count == 1)
        clock.advance(61)
        await #expect(throws: FeedFetcher.Failure.offline) { try await library.index(for: feed) }
        #expect(fetcher.count == 2)
        // Twice as long now; but asking yourself always tries.
        clock.advance(61)
        await #expect(throws: FeedFetcher.Failure.offline) { try await library.index(for: feed) }
        #expect(fetcher.count == 2)
        fetcher.set(feed.schedule, Lakeside.zip())
        #expect(try await library.index(for: feed, refresh: true).routes.count == 3)
    }

    @Test func aBrokenNewScheduleLeavesTheOldOne() async throws {
        fetcher.set(feed.schedule, Lakeside.zip())
        let library = library()
        _ = try await library.index(for: feed)
        clock.advance(FeedLibrary.scheduleCheckInterval + 1)
        fetcher.set(feed.schedule, Data("<html>maintenance</html>".utf8))
        #expect(try await library.index(for: feed).routes.count == 3)
        #expect(fetcher.count == 2)
        // And the broken one isn't downloaded again until tomorrow.
        _ = try await library.index(for: feed)
        #expect(fetcher.count == 2)
        #expect(await self.library().cachedIndex(for: feed)?.routes.count == 3)
        // With nothing to fall back on, it says why.
        let fresh = FeedSource(id: "other", name: "Other", area: "", schedule: URL(string: "https://feeds.lakeside.example.org/other.zip")!)
        fetcher.set(fresh.schedule, Data("<html>maintenance</html>".utf8))
        await #expect(throws: ZipArchive.Failure.notAZip) { try await library.index(for: fresh) }
    }

    @Test func aNewAddressIsDownloadedFresh() async throws {
        fetcher.set(feed.schedule, Lakeside.zip(), etag: "\"v1\"")
        let library = library()
        _ = try await library.index(for: feed)
        var moved = feed
        moved.schedule = URL(string: "https://feeds.lakeside.example.org/v2/gtfs.zip")!
        fetcher.set(moved.schedule, Lakeside.zip())
        _ = try await library.index(for: moved)
        #expect(fetcher.count == 2)
        // Without the old file's tag, which belongs to the old address.
        #expect(fetcher.requests.last?.etag == nil)
    }

    @Test func readsStopTimesOnceForTheSameStops() async throws {
        fetcher.set(feed.schedule, Lakeside.zip())
        let library = library()
        let calls = try await library.calls(for: feed, stops: ["S1"])
        #expect(Set(calls.calls.map(\.tripID)) == ["B1", "B2", "B3", "N1"])
        await library.releaseZips()
        // Saved, so the next start doesn't read the zip again.
        let again = self.library()
        #expect(try await again.calls(for: feed, stops: ["S1"]) == calls)
        #expect(try await again.calls(for: feed, stops: ["S1", "P1"]).calls.contains { $0.tripID == "L1" })
    }

    @Test func fetchesLiveUpdatesAndAlertsWithoutKeepingThem() async throws {
        fetcher.set(feed.tripUpdates!, FeedBuilder.feed(timestamp: Lakeside.now, updates: [.init(tripID: "B1", delay: 60)]))
        fetcher.set(feed.alerts!, FeedBuilder.feed(timestamp: Lakeside.now.addingTimeInterval(-20), alerts: [.init()]))
        let live = try await library().live(for: feed)
        #expect(live.feed.tripUpdates.count == 1)
        #expect(live.feed.alerts.count == 1)
        #expect(live.feed.timestamp == Lakeside.now.addingTimeInterval(-20))
        #expect(live.hasTripUpdates)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("lakeside").appendingPathComponent("trips.pb").path))
    }

    @Test func asksABusyServerOnceMore() async throws {
        fetcher.set(feed.tripUpdates!, FeedBuilder.feed(timestamp: Lakeside.now, updates: [.init(tripID: "B1")]))
        fetcher.set(feed.alerts!, FeedBuilder.feed(timestamp: Lakeside.now))
        fetcher.failOnce(feed.tripUpdates!, FeedFetcher.Failure.http(503, retryAfter: nil))
        let live = try await library().live(for: feed)
        #expect(live.failure == nil)
        #expect(live.feed.tripUpdates.count == 1)
        #expect(fetcher.requests.filter { $0.url == feed.tripUpdates }.count == 2)
    }

    @Test func keepsTheAlertsWhenTripUpdatesFail() async throws {
        fetcher.fail(feed.tripUpdates!, FeedFetcher.Failure.http(500, retryAfter: nil))
        fetcher.set(feed.alerts!, FeedBuilder.feed(timestamp: Lakeside.now, alerts: [.init()]))
        let live = try await library().live(for: feed)
        #expect(live.feed.alerts.count == 1)
        #expect(!live.hasTripUpdates)
        #expect(live.failure as? FeedFetcher.Failure == .http(500, retryAfter: nil))
        // When nothing comes in at all, it's an error: the first one, in address order.
        fetcher.fail(feed.alerts!, FeedFetcher.Failure.offline)
        await #expect(throws: FeedFetcher.Failure.offline) { try await library().live(for: feed) }
        // A server that asks to wait isn't asked again right away.
        fetcher.fail(feed.tripUpdates!, FeedFetcher.Failure.http(503, retryAfter: 120))
        let before = fetcher.count
        _ = try? await library().live(for: feed)
        #expect(fetcher.count == before + 2)
    }

    @Test func aCombinedFeedIsFetchedOnce() async throws {
        var combined = feed
        combined.alerts = combined.tripUpdates
        fetcher.set(combined.tripUpdates!, FeedBuilder.feed(timestamp: Lakeside.now, updates: [.init(tripID: "B1")], alerts: [.init()]))
        let live = try await library().live(for: combined)
        #expect(fetcher.count == 1)
        #expect(live.feed.tripUpdates.count == 1 && live.feed.alerts.count == 1)
    }

    @Test func onlyTheFeedsOwnHostsAreAsked() async throws {
        var sneaky = feed
        sneaky.alerts = URL(string: "https://tracker.example.com/alerts.pb")
        // The host is in the feed, so it's allowed for that feed, and only that one.
        #expect(sneaky.hosts == ["feeds.lakeside.example.org", "tracker.example.com"])
        #expect(Lakeside.feed.hosts == ["feeds.lakeside.example.org"])
        await #expect(throws: FeedFetcher.Failure.notAllowed("tracker.example.com")) {
            _ = try await FeedFetcher().fetch(sneaky.alerts!, allowed: Lakeside.feed.hosts, limit: 10)
        }
        await #expect(throws: FeedFetcher.Failure.notAllowed("feeds.lakeside.example.org")) {
            _ = try await FeedFetcher().fetch(URL(string: "http://feeds.lakeside.example.org/x")!, allowed: Lakeside.feed.hosts, limit: 10)
        }
    }

    @Test func forgettingAFeedRemovesItsFiles() async throws {
        fetcher.set(feed.schedule, Lakeside.zip())
        let library = library()
        _ = try await library.index(for: feed)
        await library.forget(feed)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("lakeside").path))
        #expect(await library.cachedIndex(for: feed) == nil)
    }

    @Test func refusesAFeedIDThatIsNotAFolderName() async {
        var bad = feed
        bad.id = "../escape"
        await #expect(throws: (any Error).self) { try await library().index(for: bad) }
        #expect(!FeedSource.isValidID("../escape"))
        #expect(!FeedSource.isValidID(""))
        #expect(!FeedSource.isValidID("-x"))
        #expect(FeedSource.isValidID("custom-1a2b3c4d"))
    }
}

@Suite("Backoff")
struct BackoffTests {
    @Test func waitsLongerAfterEachFailure() {
        var backoff = Backoff()
        #expect(backoff.delay == 30)
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            backoff.failed(FeedFetcher.Failure.offline)
            delays.append(backoff.delay)
        }
        #expect(delays == [60, 120, 240, 480, 600, 600, 600, 600])
        backoff.succeeded()
        #expect(backoff.delay == 30)
    }

    @Test func waitsAsLongAsTheServerAsks() {
        var backoff = Backoff()
        backoff.failed(FeedFetcher.Failure.http(429, retryAfter: 900))
        #expect(backoff.delay == 900)
        // But not for days.
        backoff.failed(FeedFetcher.Failure.http(503, retryAfter: 1_000_000))
        #expect(backoff.delay == 3600)
    }
}

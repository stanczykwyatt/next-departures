import AppKit
import Foundation
import Testing
@testable import NextDepartures
@testable import TransitCore

@MainActor
@Suite("Model")
struct ModelTests {
    let folder = TestFolder()

    @Test func showsLiveDeparturesForEachStop() async throws {
        let model = await Gallery.model(in: folder)
        #expect(model.problems.isEmpty)
        #expect(model.isLive(Gallery.feed.id))
        let station = model.departures(for: model.saved[0])
        #expect(station.count == 5)
        #expect(station.contains { $0.status == .live })
        #expect(Set(station.compactMap(\.headsign)) == ["Union Depot", "Riverside"])
        // The bus bay only shows the routes picked for it, and the canceled run.
        let bay = model.departures(for: model.saved[2], limit: 8)
        #expect(Set(bay.map(\.route.id)) == ["3", "16"])
        #expect(bay.contains { $0.status == .canceled })
    }

    @Test func theNextDepartureSkipsCanceledRides() async throws {
        let model = await Gallery.model(in: folder)
        let bay = model.saved[2]
        #expect(model.departures(for: bay, limit: 1).first?.status == .canceled)
        #expect(model.nextDeparture(for: bay)?.status == .live)
    }

    @Test func liveDataGoesBackToTheTimetableOnceItsOld() async {
        let clock = TestClock(Gallery.now)
        let model = await Gallery.model(in: folder, clock: clock)
        #expect(model.departures(for: model.saved[0]).contains { $0.status == .live })
        clock.now += DepartureBoard.staleAfter + 1
        #expect(!model.departures(for: model.saved[0]).contains { $0.status == .live })
        #expect(!model.isLive(Gallery.feed.id))
    }

    @Test func findsAlertsForAStop() async {
        let model = await Gallery.model(in: folder)
        #expect(model.alerts(for: model.saved[1]).count == 1)
        #expect(model.alerts(for: model.saved[0]).isEmpty)
    }

    @Test func fallsBackToTheTimetableWhenOffline() async {
        let model = await Gallery.model(in: folder, live: false)
        #expect(model.problems[Gallery.feed.id] == "You're offline.")
        #expect(!model.isLive(Gallery.feed.id))
        #expect(model.departures(for: model.saved[0]).allSatisfy { $0.status == .scheduled })
    }

    @Test func checksTheLiveFeedNoMoreThanEvery30Seconds() async {
        let clock = TestClock(Gallery.now)
        let model = await Gallery.model(in: folder, clock: clock)
        let feed = Gallery.feed
        #expect(!model.isDue(feed, force: false))
        // Refresh Now still waits a moment between checks.
        clock.now += 5
        #expect(!model.isDue(feed, force: true))
        clock.now += 6
        #expect(model.isDue(feed, force: true))
        #expect(!model.isDue(feed, force: false))
        clock.now += 20
        #expect(model.isDue(feed, force: false))
        #expect(model.nextDelay(feed) == 30)
    }

    @Test func backsOffAfterErrors() async {
        let clock = TestClock(Gallery.now)
        let model = await Gallery.model(in: folder, live: false, clock: clock)
        #expect(model.nextDelay(Gallery.feed) == 60)
        clock.now += 40
        #expect(!model.isDue(Gallery.feed, force: false))
        // While there's a problem, even Refresh Now waits out the backoff.
        #expect(!model.isDue(Gallery.feed, force: true))
        clock.now += 30
        #expect(model.isDue(Gallery.feed, force: false))
        await model.refresh()
        #expect(model.nextDelay(Gallery.feed) == 120)
    }

    @Test func onlyFeedsWithStopsAreFetched() async {
        let model = await Gallery.model(in: folder)
        #expect(model.activeFeeds.map(\.id) == [Gallery.feed.id])
        // Metro Transit is offered, but with no stops picked there, it's never contacted.
        #expect(model.feeds.map(\.id) == ["metro-transit", Gallery.feed.id])
        #expect(model.indexes["metro-transit"] == nil)
    }

    @Test func addsAndRemovesStops() async throws {
        let model = await Gallery.model(in: folder)
        let groups = model.search("science", feedID: Gallery.feed.id, route: nil)
        let science = try #require(groups.first)
        #expect(science.stopIDs == ["SCI"])
        await model.add(science, feedID: Gallery.feed.id)
        #expect(model.saved.count == 4)
        #expect(model.preferences.stops.count == 4)
        #expect(!model.departures(for: model.saved[3]).isEmpty)
        // The same stop twice is ignored.
        await model.add(science, feedID: Gallery.feed.id)
        #expect(model.saved.count == 4)
        await model.remove(model.saved[3])
        #expect(model.saved.map(\.id) == ["a", "b", "c"])
        model.move(from: [2], to: 0)
        #expect(model.preferences.stops.map(\.id) == ["c", "a", "b"])
        model.setRoutes(["3"], for: model.saved[0])
        #expect(model.preferences.stops[0].routes == ["3"])
    }

    @Test func groupsBothPlatformsOfAStation() async throws {
        let model = await Gallery.model(in: folder)
        let station = try #require(model.search("university station", feedID: Gallery.feed.id, route: nil).first { $0.name == "University Station" })
        #expect(Set(station.stopIDs) == ["U2E", "U2W"])
        #expect(model.search("", feedID: Gallery.feed.id, route: "52").flatMap(\.stopIDs).sorted() == ["RIV4", "U2B"])
    }

    @Test func addsAFeedFromPastedAddresses() async throws {
        let model = await Gallery.model(in: folder)
        #expect(model.addFeed(name: "", schedule: "http://x.example.org/gtfs.zip", tripUpdates: "", alerts: "") == .failure(.schedule(.notHTTPS)))
        #expect(model.addFeed(name: "X", schedule: "https://x.example.org/gtfs.zip", tripUpdates: "https://192.168.0.2/t.pb", alerts: "") == .failure(.tripUpdates(.local)))
        let feed = try model.addFeed(name: "  Harbor\u{1B} Ferries ", schedule: " https://ferries.example.org/gtfs.zip ", tripUpdates: "", alerts: "https://ferries.example.org/alerts.pb").get()
        #expect(feed.name == "Harbor Ferries")
        #expect(feed.tripUpdates == nil)
        #expect(FeedSource.isValidID(feed.id) && feed.id.hasPrefix("custom-"))
        #expect(model.preferences.customFeeds.contains(feed))
        await model.removeFeed(feed)
        #expect(!model.preferences.customFeeds.contains(feed))
        // A preset can't be removed.
        await model.removeFeed(FeedSource.presets[0])
        #expect(model.feeds.first?.id == "metro-transit")
    }

    @Test func removingAFeedRemovesItsStopsAndFiles() async {
        let model = await Gallery.model(in: folder)
        let feed = Gallery.feed
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(feed.id).path))
        await model.removeFeed(feed)
        #expect(model.saved.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(feed.id).path))
    }

    @Test func loadsFromDiskWithoutTheNetwork() async {
        _ = await Gallery.model(in: folder)
        let offline = FakeFetcher()
        let preferences = testPreferences()
        preferences.customFeeds = [Gallery.feed]
        preferences.stops = [SavedStop(feedID: Gallery.feed.id, stopIDs: ["LIB"], name: "Library Mall & Elm St")]
        let model = TransitModel(library: FeedLibrary(folder: folder.url, fetcher: offline, now: { Gallery.now }), preferences: preferences, now: { Gallery.now })
        await model.load()
        #expect(model.indexes[Gallery.feed.id] != nil)
        #expect(!model.departures(for: model.saved[0]).isEmpty)
        #expect(offline.count(Gallery.feed.schedule) == 0)
        #expect(offline.count(Gallery.feed.tripUpdates!) == 0)
    }

    @Test func settingsEditedByHandCantAddARefusedAddress() {
        let preferences = testPreferences()
        let sneaky = FeedSource(id: "custom-1", name: "x", area: "", schedule: URL(string: "http://plain.example.org/gtfs.zip")!)
        let local = FeedSource(id: "custom-2", name: "x", area: "", schedule: URL(string: "https://127.0.0.1/gtfs.zip")!)
        let badID = FeedSource(id: "../up", name: "x", area: "", schedule: URL(string: "https://fine.example.org/gtfs.zip")!)
        let fine = FeedSource(id: "custom-3", name: "x", area: "", schedule: URL(string: "https://fine.example.org/gtfs.zip")!)
        preferences.customFeeds = [sneaky, local, badID, fine, FeedSource.presets[0]]
        #expect(preferences.customFeeds == [fine])
    }

    @Test func keepsAtMostAMenusWorthOfStops() {
        let preferences = testPreferences()
        preferences.stops = (0..<30).map { SavedStop(feedID: "x", stopIDs: ["\($0)"], name: "\($0)") }
        #expect(preferences.stops.count == Preferences.maxStops)
    }
}

@MainActor
@Suite("Polling")
struct PollerTests {
    let folder = TestFolder()

    @Test func onlyPollsWhileSomeoneIsLooking() async throws {
        let model = await Gallery.model(in: folder)
        var updates = 0
        let poller = Poller(model: model) { updates += 1 }
        #expect(!poller.isActive)
        poller.setActive(true)
        #expect(poller.isActive)
        for _ in 0..<50 where updates == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(updates == 1)
        poller.setActive(false)
        #expect(!poller.isActive)
        // Looking away twice changes nothing, and a timer that fires late doesn't fetch.
        poller.setActive(false)
        #expect(!poller.isActive)
        poller.refresh(force: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates == 1)
    }
}

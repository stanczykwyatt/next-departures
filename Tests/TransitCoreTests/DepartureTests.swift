import Foundation
import Testing
@testable import TransitCore

@Suite("Departures")
struct DepartureTests {
    let index: FeedIndex
    let calls: StopCalls

    init() throws {
        index = try Lakeside.index()
        calls = try Lakeside.calls(["S1", "P1", "P2", "P3"])
    }

    private func at(_ time: String, day: Int = 20261029) -> Date { Lakeside.date(day, time) }

    private func board(_ stops: [String], now: Date = Lakeside.now, live: Data? = nil, routes: Set<String> = [], limit: Int = 6) throws -> [Departure] {
        DepartureBoard.departures(
            at: stops, index: index, calls: calls, realtime: try live.map(RealtimeFeed.decode), now: now, limit: limit, routes: routes
        )
    }

    private func feed(_ updates: [FeedBuilder.Update], stamp: Date = Lakeside.now) -> Data {
        FeedBuilder.feed(timestamp: stamp, updates: updates)
    }

    @Test func showsTheTimetableWithoutLiveData() throws {
        let departures = try board(["P3"])
        #expect(departures.map(\.tripID) == ["L1", "B3", "L2"])
        #expect(departures.map(\.scheduled) == [at("08:06:00"), at("08:10:00"), at("08:26:00")])
        #expect(departures.allSatisfy { $0.status == .scheduled && $0.predicted == nil })
        #expect(departures[1].headsign == "Downtown")
    }

    @Test func aStationShowsItsPlatforms() throws {
        // B3 and N1 end here, so only the two that leave are shown.
        #expect(try board(["S1"]).map(\.tripID) == ["B1", "B2"])
    }

    @Test func usesTheFeedsTimeForThisStop() throws {
        let live = feed([.init(tripID: "B1", startDate: "20261029", stops: [.init(sequence: 1, stopID: "S1A", departure: (nil, at("08:07:00")))])])
        let first = try #require(try board(["S1"], live: live).first)
        #expect(first.status == .live)
        #expect(first.predicted == at("08:07:00"))
        #expect(first.delay == 120)
        #expect(Describe.status(first) == "2 min late")
    }

    @Test func readsADelayForThisStop() throws {
        let live = feed([.init(tripID: "L1", stops: [.init(stopID: "P1", arrival: (-60, nil))])])
        let first = try #require(try board(["P1"], live: live).first)
        #expect(first.predicted == at("08:01:00"))
        #expect(Describe.status(first) == "1 min early")
    }

    @Test func carriesALateDelayDownTheLine() throws {
        let live = feed([.init(tripID: "L2", stops: [.init(sequence: 1, stopID: "P1", arrival: (180, nil))])])
        let l2 = try #require(try board(["P3"], live: live).first { $0.tripID == "L2" })
        #expect(l2.predicted == at("08:29:00"))
        #expect(l2.status == .live)
    }

    @Test func worksOutTheDelayFromAnEarlierStopsTime() throws {
        // Only a time, and only a stop ID: the trip's own stops say where it is and when it was due.
        let live = feed([.init(tripID: "L2", stops: [.init(stopID: "P1", departure: (nil, at("08:24:00")))])])
        let l2 = try #require(try board(["P3"], live: live).first { $0.tripID == "L2" })
        #expect(l2.predicted == at("08:28:00"))
    }

    @Test func doesNotCarryRunningEarlyDownTheLine() throws {
        let live = feed([.init(tripID: "L2", stops: [.init(sequence: 1, arrival: (-240, nil))])])
        let l2 = try #require(try board(["P3"], live: live).first { $0.tripID == "L2" })
        #expect(l2.predicted == at("08:26:00"))
        #expect(Describe.status(l2) == "On time")
    }

    @Test func usesAWholeTripDelay() throws {
        let live = feed([.init(tripID: "B3", delay: 300)])
        #expect(try board(["P3"], live: live).first { $0.tripID == "B3" }?.predicted == at("08:15:00"))
    }

    @Test func showsCanceledAndSkipped() throws {
        let live = feed([
            .init(tripID: "B3", relationship: 3),
            .init(tripID: "L1", stops: [.init(sequence: 2, stopID: "P3", relationship: 1)]),
        ])
        let departures = try board(["P3"], live: live)
        #expect(departures.first { $0.tripID == "B3" }?.status == .canceled)
        #expect(departures.first { $0.tripID == "L1" }?.status == .skipped)
        #expect(Describe.status(departures.first { $0.tripID == "L1" }!) == "Skips this stop")
    }

    @Test func noDataMeansTheTimetable() throws {
        let live = feed([.init(tripID: "L2", stops: [.init(sequence: 1, arrival: (300, nil)), .init(sequence: 2, relationship: 2)])])
        #expect(try board(["P3"], live: live).first { $0.tripID == "L2" }?.status == .scheduled)
    }

    @Test func anUpdateForAnotherDayIsIgnored() throws {
        let live = feed([.init(tripID: "B1", startDate: "20261028", delay: 600)])
        #expect(try board(["S1"], live: live).first?.status == .scheduled)
    }

    @Test func tripsTheTimetableDoesNotHaveStillShow() throws {
        let live = feed([
            .init(tripID: "EXTRA-1", routeID: "LOOP", relationship: 1, stops: [.init(stopID: "P3", departure: (nil, at("08:15:00")))]),
            // Unknown routes, and stops elsewhere, are left out.
            .init(tripID: "EXTRA-2", routeID: "NOPE", stops: [.init(stopID: "P3", departure: (nil, at("08:16:00")))]),
            .init(tripID: "EXTRA-3", routeID: "LOOP", stops: [.init(stopID: "P4", departure: (nil, at("08:17:00")))]),
        ])
        let extra = try board(["P3"], live: live).filter { $0.scheduled == nil }
        #expect(extra.count == 1)
        #expect(extra.first?.predicted == at("08:15:00"))
        #expect(extra.first?.headsign == "Campus Loop")
        #expect(extra.first?.status == .live)
    }

    @Test func anUnknownTripMarkedScheduledIsNotShownTwice() throws {
        // A trip from a newer timetable than the one here: it isn't extra service.
        let live = feed([.init(tripID: "L1-new", routeID: "LOOP", stops: [.init(stopID: "P3", departure: (nil, at("08:06:00")))])])
        #expect(try board(["P3"], live: live).filter { $0.scheduled == nil }.isEmpty)
    }

    @Test func aStaleFeedIsNotShownAsLive() throws {
        let old = feed([.init(tripID: "B1", delay: 300)], stamp: Lakeside.now.addingTimeInterval(-DepartureBoard.staleAfter - 1))
        #expect(try board(["S1"], live: old).first?.status == .scheduled)
        // A feed that doesn't say when it was made is taken as fresh.
        let unstamped = FeedBuilder.feed(timestamp: nil, updates: [.init(tripID: "B1", delay: 300)])
        #expect(try board(["S1"], live: unstamped).first?.status == .live)
    }

    @Test func tripsPastMidnightBelongToTheDayBefore() throws {
        // N1 leaves Library Mall at 24:30:00 on Thursday's schedule: half past midnight Friday.
        let lateEvening = try board(["P2"], now: at("23:45:00"))
        #expect(lateEvening.map(\.tripID) == ["N1"])
        #expect(lateEvening.first?.scheduled == at("00:30:00", day: 20261030))
        #expect(try board(["P2"], now: at("00:10:00", day: 20261030)).map(\.tripID) == ["N1"])
        // There's no N1 on Saturday's schedule, so early Sunday there's nothing.
        #expect(try board(["P2"], now: at("00:10:00", day: 20261101)).isEmpty)
    }

    @Test func holidaysFollowTheCalendarExceptions() throws {
        let thanksgiving = try board(["P1"], now: at("07:59:00", day: 20261126))
        #expect(thanksgiving.map(\.tripID) == ["L3"])
    }

    @Test func filtersByRouteAndLimits() throws {
        #expect(try board(["P3"], routes: ["BLUE"]).map(\.tripID) == ["B3"])
        #expect(try board(["P3"], limit: 1).map(\.tripID) == ["L1"])
    }

    @Test func aRideJustLeavingStaysAMoment() throws {
        #expect(try board(["P1"], now: at("08:02:30")).first?.tripID == "L1")
        #expect(try board(["P1"], now: at("08:03:30")).first?.tripID == "L2")
    }

    @Test func anUpdateWithoutADayOnlyAppliesNearNow() throws {
        let live = feed([.init(tripID: "N1", delay: 120)], stamp: at("23:45:00"))
        // At 23:45 Thursday, Thursday's N1 is 45 minutes off, so it's live.
        #expect(try board(["P2"], now: at("23:45:00"), live: live).first?.status == .live)
    }

    @Test func sortsByTheTimeItWillReallyLeave() throws {
        // L1 is so late that B3 now leaves first.
        let live = feed([.init(tripID: "L1", stops: [.init(sequence: 2, departure: (nil, at("08:12:00")))])])
        #expect(try board(["P3"], live: live).map(\.tripID) == ["B3", "L1", "L2"])
    }
}

@Suite("Alerts")
struct AlertTests {
    let index: FeedIndex

    init() throws {
        index = try Lakeside.index()
    }

    private func alerts(_ specs: [FeedBuilder.AlertSpec], at stops: [String], trips: Set<String> = [], now: Date = Lakeside.now) throws -> [String] {
        let feed = try RealtimeFeed.decode(FeedBuilder.feed(timestamp: now, alerts: specs))
        return AlertMatcher.alerts(for: stops, index: index, feed: feed, now: now, tripIDs: trips).compactMap { $0.header.first?.value }
    }

    private func spec(_ name: String, agency: String? = nil, route: String? = nil, stop: String? = nil, trip: String? = nil, type: Int? = nil, severity: Int? = nil) -> FeedBuilder.AlertSpec {
        .init(header: [(name, nil)], severity: severity, entities: [(agency, route, stop, trip, type)])
    }

    @Test func matchesTheStopItsStationAndPlatforms() throws {
        #expect(try alerts([spec("station", stop: "S1")], at: ["S1A"]) == ["station"])
        #expect(try alerts([spec("platform", stop: "S1B")], at: ["S1"]) == ["platform"])
        #expect(try alerts([spec("elsewhere", stop: "P4")], at: ["S1"]).isEmpty)
    }

    @Test func matchesRoutesThatCallThere() throws {
        #expect(try alerts([spec("loop", route: "LOOP")], at: ["P1"]) == ["loop"])
        #expect(try alerts([spec("loop", route: "LOOP")], at: ["S1"]).isEmpty)
        #expect(try alerts([spec("rail", type: 0)], at: ["S1"]) == ["rail"])
        #expect(try alerts([spec("rail", type: 0)], at: ["P1"]).isEmpty)
    }

    @Test func aRouteAndStopTogetherMustBothMatch() throws {
        #expect(try alerts([spec("both", route: "LOOP", stop: "P1")], at: ["P1"]) == ["both"])
        #expect(try alerts([spec("both", route: "BLUE", stop: "P1")], at: ["P1"]).isEmpty)
    }

    @Test func matchesTheWholeAgency() throws {
        #expect(try alerts([spec("everywhere", agency: "LT")], at: ["P2"]) == ["everywhere"])
    }

    @Test func matchesATripOnlyWhenItsOnTheBoard() throws {
        #expect(try alerts([spec("trip", trip: "L1")], at: ["P1"], trips: ["L1"]) == ["trip"])
        #expect(try alerts([spec("trip", trip: "L1")], at: ["P1"]).isEmpty)
    }

    @Test func leavesOutAlertsNotInEffect() throws {
        var later = spec("later", stop: "P1")
        later.periods = [(Lakeside.now.addingTimeInterval(3600), nil)]
        var over = spec("over", stop: "P1")
        over.periods = [(nil, Lakeside.now.addingTimeInterval(-1))]
        var now = spec("now", stop: "P1")
        now.periods = [(nil, Lakeside.now.addingTimeInterval(-1)), (Lakeside.now, Lakeside.now.addingTimeInterval(60))]
        #expect(try alerts([later, over, now], at: ["P1"]) == ["now"])
    }

    @Test func aRouteFilterLeavesOutOtherRoutesAlerts() throws {
        let feed = try RealtimeFeed.decode(FeedBuilder.feed(timestamp: Lakeside.now, alerts: [spec("loop", route: "LOOP"), spec("rail", route: "BLUE"), spec("stop", stop: "P3")]))
        let only = AlertMatcher.alerts(for: ["P3"], index: index, feed: feed, now: Lakeside.now, onlyRoutes: ["LOOP"])
        #expect(only.compactMap { $0.header.first?.value } == ["loop", "stop"])
    }

    @Test func anAlertForOneDirectionSkipsStopsOnlyTheOtherServes() throws {
        var one = spec("eastbound", route: "LOOP")
        one.entities = [(nil, "LOOP", nil, nil, nil)]
        var data = FeedBuilder.feed(timestamp: Lakeside.now, alerts: [one])
        // Add direction 1 to the selector by hand: field 6 of the EntitySelector.
        data = FeedBuilder.feed(timestamp: Lakeside.now) { writer in
            writer.message(2) { entity in
                entity.string(1, "dir")
                entity.message(5) { alert in
                    alert.message(5) { selector in
                        selector.string(2, "LOOP")
                        selector.int(6, 1)
                    }
                    alert.message(10) { $0.message(1) { $0.string(1, "eastbound") } }
                }
            }
        }
        let feed = try RealtimeFeed.decode(data)
        let calls = try Lakeside.calls(["P1"])
        let directions = AlertMatcher.directions(at: ["P1"], index: index, calls: calls)
        #expect(directions == [0])
        #expect(AlertMatcher.alerts(for: ["P1"], index: index, feed: feed, now: Lakeside.now, directions: directions).isEmpty)
        #expect(AlertMatcher.alerts(for: ["P1"], index: index, feed: feed, now: Lakeside.now).count == 1)
    }

    @Test func mostSevereFirst() throws {
        let result = try alerts([spec("info", stop: "P1", severity: 2), spec("severe", stop: "P1", severity: 4), spec("plain", stop: "P1")], at: ["P1"])
        #expect(result == ["severe", "info", "plain"])
    }

    @Test func anAlertAboutNothingMatchesNothing() throws {
        #expect(try alerts([spec("empty")], at: ["P1"]).isEmpty)
    }

    @Test func picksTheBestLanguage() {
        let texts = ["en": "Detour", "es": "Desvío", "fr-ca": "Détour"]
        #expect(AlertMatcher.text(texts, languages: ["es-US"]) == "Desvío")
        #expect(AlertMatcher.text(texts, languages: ["fr"]) == "Détour")
        #expect(AlertMatcher.text(texts, languages: ["de"]) == "Detour")
        #expect(AlertMatcher.text(["": "Plain", "es": "Llano"], languages: ["de"]) == "Plain")
        #expect(AlertMatcher.text(["es": "Llano"], languages: ["de"]) == "Llano")
        #expect(AlertMatcher.text([:]) == nil)
    }
}

import Foundation
import Testing
@testable import TransitCore

@Suite("Feeds")
struct FeedTests {
    @Test func thePresetsAreOpenHTTPSFeedsFromOneHost() {
        #expect(FeedSource.presets.map(\.id) == ["metro-transit"])
        for preset in FeedSource.presets {
            #expect(FeedSource.isValidID(preset.id))
            #expect(preset.urls.allSatisfy { $0.scheme == "https" && $0.query == nil })
            #expect(preset.hosts == ["svc.metrotransit.org"])
            #expect(preset.attribution?.isEmpty == false)
            #expect(preset.isPreset)
            #expect(preset.featuredRoutes.contains("902"))
        }
    }

    @Test func checksPastedAddresses() throws {
        #expect(try FeedSource.check("  https://feeds.example.org/gtfs.zip#top \n").get() == URL(string: "https://feeds.example.org/gtfs.zip")!)
        #expect(try FeedSource.check("https://api.example.org/trips.pb?key=abc").get().query == "key=abc")
        #expect(FeedSource.check("") == .failure(.empty))
        #expect(FeedSource.check("http://feeds.example.org/gtfs.zip") == .failure(.notHTTPS))
        #expect(FeedSource.check("ftp://feeds.example.org/gtfs.zip") == .failure(.notHTTPS))
        #expect(FeedSource.check("feeds.example.org/gtfs.zip") == .failure(.notHTTPS))
        #expect(FeedSource.check("https:///gtfs.zip") == .failure(.noHost))
        #expect(FeedSource.check("https://me:secret@feeds.example.org/gtfs.zip") == .failure(.hasPassword))
        #expect(FeedSource.check("https://example.org/" + String(repeating: "a", count: 3000)) == .failure(.tooLong))
    }

    @Test(arguments: ["https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.8/x", "https://192.168.1.1/x", "https://172.20.0.1/x",
                      "https://169.254.169.254/latest", "https://[::1]/x", "https://[fd00::1]/x", "https://printer.local/x", "https://router/x",
                      "https://100.64.0.1/x", "https://0.0.0.0/x", "https://localhost./x", "https://127.1/x", "https://0x7f.0.0.1/x",
                      "https://[::ffff:127.0.0.1]/x", "https://router.lan/x", "https://224.0.0.1/x", "https://2130706433/x", "https://[ff02::1]/x"])
    func refusesAddressesOnYourNetwork(_ address: String) {
        #expect(FeedSource.check(address) == .failure(.local))
    }

    @Test func takesAddressesOnTheInternet() {
        for address in ["https://8.8.8.8/x", "https://172.32.0.1/x", "https://data.example.co.uk/gtfs.zip", "https://[2001:db8::1]/x"] {
            #expect((try? FeedSource.check(address).get()) != nil, "\(address)")
        }
    }
}

@Suite("Wording")
struct DescribeTests {
    let clock = Describe.clock(Lakeside.timeZone, locale: Locale(identifier: "en_US"))

    @Test func saysWhenLikeAStationSign() {
        let now = Lakeside.now
        #expect(Describe.until(now.addingTimeInterval(-30), now: now, clock: clock) == "Now")
        #expect(Describe.until(now.addingTimeInterval(59), now: now, clock: clock) == "Now")
        #expect(Describe.until(now.addingTimeInterval(61), now: now, clock: clock) == "1 min")
        #expect(Describe.until(now.addingTimeInterval(59 * 60 + 59), now: now, clock: clock) == "59 min")
        #expect(Describe.until(now.addingTimeInterval(3600), now: now, clock: clock) == "9:00\u{202F}AM")
    }

    @Test func namesRoutesTheWayRidersDo() throws {
        let index = try Lakeside.index()
        let blue = index.routes["BLUE"]!, loop = index.routes["LOOP"]!
        #expect(Describe.routeName(blue) == "Harbor Line")
        #expect(Describe.routeName(loop) == "7")
        let departure = Departure(id: "x", stopID: "P1", route: loop, headsign: "Gym Loop", status: .scheduled)
        #expect(Describe.line(departure) == "7 to Gym Loop")
        var same = departure
        same.headsign = "Campus Loop"
        #expect(Describe.line(same) == "7 Campus Loop")
        same.headsign = "loop"
        #expect(Describe.line(same) == "7 loop")
        var rail = Departure(id: "y", stopID: "S1", route: blue, headsign: "Harbor Line", status: .scheduled)
        #expect(Describe.line(rail) == "Harbor Line")
        rail.headsign = "Lakefront"
        #expect(Describe.line(rail) == "Harbor Line to Lakefront")
        // Some agencies put the route's full name in its description instead.
        let campus = Route(id: "121", shortName: "121", desc: "U of M - Campus Connector")
        #expect(Describe.line(Departure(id: "z", stopID: "x", route: campus, headsign: "Campus Connector", status: .scheduled)) == "121 Campus Connector")
        same.headsign = nil
        #expect(Describe.line(same) == "7")
        #expect(Describe.stop(index.stop("P1")!) == "Library Mall & Elm St (#2001)")
        #expect(Describe.stop(index.stop("S1")!) == "Harbor Station")
    }

    @Test func cleansTextFromFeeds() {
        #expect(Describe.clean("Detour\u{1B}[31m on\tLake\n\nSt") == "Detour[31m on Lake St")
        #expect(Describe.clean("\u{202E}evil\u{200B}name") == "evil name")
        #expect(Describe.clean("  padded  ") == "padded")
        #expect(Describe.clean(String(repeating: "a", count: 50), limit: 10) == String(repeating: "a", count: 10) + "…")
        #expect(Describe.clean("Café 🚋") == "Café 🚋")
    }

    @Test func explainsProblemsPlainly() {
        #expect(Describe.problem(FeedFetcher.Failure.offline) == "You're offline.")
        #expect(Describe.problem(FeedFetcher.Failure.http(503, retryAfter: nil)).contains("503"))
        #expect(Describe.problem(FeedFetcher.Failure.http(429, retryAfter: 60)).contains("less often"))
        #expect(Describe.problem(ZipArchive.Failure.notAZip).contains("zip"))
        #expect(Describe.problem(ProtoReader.Failure.truncated).contains("timetable"))
        #expect(Describe.problem(FeedFetcher.Failure.redirectedElsewhere).contains("another website"))
    }

    @Test func namesEveryEffect() {
        for raw in 1...11 {
            #expect(!Describe.effect(Alert.Effect(rawValue: raw)!).isEmpty)
        }
    }
}

@Suite("Stop search")
struct SearchTests {
    let index: FeedIndex

    init() throws {
        index = try Lakeside.index()
    }

    @Test func findsByWordsInAnyOrder() {
        #expect(StopSearch.find("elm library", in: index).map(\.name) == ["Library Mall & Elm St"])
        #expect(StopSearch.find("sci", in: index).map(\.name) == ["Science Hall"])
        #expect(StopSearch.find("nothing here", in: index).isEmpty)
    }

    @Test func groupsBothSidesOfTheStreet() throws {
        let group = try #require(StopSearch.find("library", in: index).first)
        #expect(group.stopIDs == ["P1", "P2"])
        #expect(group.routeIDs == ["LOOP", "OWL"])
    }

    @Test func aSignNumberFindsThatOneStop() {
        let result = StopSearch.find("2002", in: index)
        #expect(result.first?.stopIDs == ["P2"])
    }

    @Test func offersStationsRatherThanTheirPlatforms() {
        #expect(StopSearch.find("harbor", in: index).map(\.stopIDs) == [["S1"]])
    }

    @Test func filtersByRoute() {
        let loop = StopSearch.find("", in: index, route: "LOOP")
        #expect(Set(loop.flatMap(\.stopIDs)) == ["P1", "P3", "P4"])
        #expect(StopSearch.find("", in: index, route: "BLUE").flatMap(\.stopIDs).contains("S1"))
    }

    @Test func measuresShortDistances() {
        // About 111 meters per thousandth of a degree of latitude.
        #expect(abs(StopSearch.distance(44.97, -93.23, 44.971, -93.23) - 111) < 1)
    }
}

@Suite("Command line")
struct CommandTests {
    let folder = TestFolder()
    let fetcher = FakeFetcher()
    let lakeside = ["--schedule", "https://feeds.lakeside.example.org/gtfs.zip", "--trip-updates", "https://feeds.lakeside.example.org/trips.pb", "--alerts", "https://feeds.lakeside.example.org/alerts.pb"]

    @Test func parsesCommands() throws {
        #expect(try Command.parse([]).command == .help)
        #expect(try Command.parse(["--version"]).command == .version)
        #expect(try Command.parse(["feeds"]).command == .feeds)
        #expect(try Command.parse(["stops", "east", "bank"]).command == .stops(query: "east bank", route: nil))
        #expect(try Command.parse(["stops", "--route", "902"]).command == .stops(query: "", route: "902"))
        #expect(try Command.parse(["departures", "56042", "--limit", "3", "--json"]).command == .departures(stop: "56042", route: nil, limit: 3, json: true))
        #expect(try Command.parse(["alerts"]).command == .alerts(stop: nil))
        #expect(try Command.parse(["feeds"]).feed.id == "metro-transit")
        let custom = try Command.parse(["feeds"] + lakeside).feed
        #expect(custom.schedule.host == "feeds.lakeside.example.org" && custom.alerts != nil)
        #expect(custom.id == (try Command.parse(["stops", "x"] + lakeside).feed.id))
        #expect(FeedSource.isValidID(custom.id))
    }

    @Test func refusesWhatItDoesNotKnow() {
        #expect(throws: Command.ParseError.self) { try Command.parse(["departures"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["departures", "1", "--limit", "0"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["stops"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["fly"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["feeds", "--loud"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["feeds", "--feed", "nowhere"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["feeds", "--schedule", "http://plain.example.org/gtfs.zip"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["feeds", "--alerts", "https://x.example.org/a.pb"]) }
        #expect(throws: Command.ParseError.self) { try Command.parse(["feeds", "--limit"]) }
    }

    private func run(_ arguments: [String]) async -> (Int32, [String], [String]) {
        fetcher.set(Lakeside.feed.schedule, Lakeside.zip())
        fetcher.set(Lakeside.feed.tripUpdates!, FeedBuilder.feed(timestamp: Lakeside.now, updates: [
            .init(tripID: "L1", stops: [.init(sequence: 2, stopID: "P3", departure: (nil, Lakeside.date(20261029, "08:07:00")))]),
        ]))
        fetcher.set(Lakeside.feed.alerts!, FeedBuilder.feed(timestamp: Lakeside.now, alerts: [
            .init(header: [("Elevator out at Harbor\u{1B}[2J", nil)], details: [("Use the ramp", nil)], effect: 11, entities: [(nil, nil, "S1", nil, nil)]),
        ]))
        let library = FeedLibrary(folder: folder.url, fetcher: fetcher, now: { Lakeside.now })
        var out: [String] = [], err: [String] = []
        let status = await Command.run(arguments + lakeside, library: library, now: Lakeside.now, languages: ["en"], out: { out.append($0) }, err: { err.append($0) })
        return (status, out, err)
    }

    @Test func printsDepartures() async {
        let (status, out, _) = await run(["departures", "2003"])
        #expect(status == 0)
        #expect(out.first == "Science Hall (#2003)")
        #expect(out.count == 4)
        #expect(out[1].contains("7 min") && out[1].contains("7 to Gym Loop") && out[1].contains("1 min late"))
        #expect(out[2].contains("10 min") && out[2].contains("Harbor Line to Downtown") && out[2].contains("Scheduled"))
    }

    @Test func printsDeparturesAsJSON() async throws {
        let (status, out, _) = await run(["departures", "P3", "--json", "--limit", "1"])
        #expect(status == 0)
        let object = try JSONSerialization.jsonObject(with: Data(out.joined().utf8)) as? [String: Any]
        let departures = try #require(object?["departures"] as? [[String: Any]])
        #expect(departures.count == 1)
        #expect(departures[0]["status"] as? String == "live")
        #expect(departures[0]["route"] as? String == "7")
        #expect(departures[0]["predicted"] as? String == "2026-10-29T13:07:00Z")
    }

    @Test func findsStops() async {
        let (status, out, _) = await run(["stops", "library"])
        #expect(status == 0)
        #expect(out == ["2001\tLibrary Mall & Elm St · Nearside N\t7", "2002\tLibrary Mall & Elm St · Nearside S\t99"])
        let (missing, _, err) = await run(["stops", "airport"])
        #expect(missing == 1 && err.first?.contains("No stops") == true)
    }

    @Test func printsAlertsWithoutTerminalEscapes() async {
        let (status, out, _) = await run(["alerts", "S1A"])
        #expect(status == 0)
        #expect(out == ["Accessibility: Elevator out at Harbor[2J", "  Use the ramp"])
        #expect(!out.joined().contains("\u{1B}"))
        let (_, departures, _) = await run(["departures", "S1"])
        #expect(departures.last == "  ! Accessibility: Elevator out at Harbor[2J")
    }

    @Test func saysWhenAStopIsUnknown() async {
        let (status, _, err) = await run(["departures", "nowhere"])
        #expect(status == 1)
        #expect(err.first?.contains("No stop") == true)
    }

    @Test func badArgumentsExitWithUsageStatus() async {
        let library = FeedLibrary(folder: folder.url, fetcher: fetcher)
        var err: [String] = []
        let status = await Command.run(["departures"], library: library, out: { _ in }, err: { err.append($0) })
        #expect(status == 64)
        #expect(err.count == 1)
    }
}

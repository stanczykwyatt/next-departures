import Foundation
import Testing
@testable import TransitCore

@Suite("Schedule")
struct ScheduleTests {
    @Test func readsTheAgencyRoutesAndStops() throws {
        let index = try Lakeside.index()
        #expect(index.timezone == "America/Chicago")
        #expect(index.agencies.map(\.name) == ["Lakeside Transit"])
        #expect(index.routes.count == 3)
        #expect(index.routes["OWL"]?.longName == "Night Owl, Late")
        #expect(index.routes["LOOP"]?.color == "FFCC00")
        #expect(index.routes["OWL"]?.color == nil)
        #expect(index.routes["BLUE"]?.type == 0)
        // The entrance isn't a place to wait, so it's left out.
        #expect(index.stop("E1") == nil)
        #expect(index.stops.count == 7)
        #expect(index.stop("P1")?.desc == "Nearside N")
        #expect(index.stop("S1A")?.platform == "A")
        #expect(index.scheduleVersion == "2026-fall")
        #expect(index.endDate == 20261231)
    }

    @Test func knowsWhichRoutesCallAtEachStop() throws {
        let index = try Lakeside.index()
        #expect(index.stop("P1")?.routeIDs == ["LOOP"])
        #expect(index.stop("S1B")?.routeIDs == ["BLUE", "OWL"])
        // A station is served by whatever calls at its platforms.
        #expect(index.stop("S1")?.routeIDs == ["BLUE", "OWL"])
        #expect(index.stopFamily("S1") == ["S1", "S1A", "S1B"])
        // In the agency's order: sorted ones first, then by name.
        #expect(index.routes(at: "S1").map(\.id) == ["BLUE", "OWL"])
        #expect(index.routes(at: "P3").map(\.id) == ["BLUE", "LOOP"])
    }

    @Test func readsTheCalendar() throws {
        let index = try Lakeside.index()
        let weekday = try #require(index.services["WK"])
        #expect(weekday.runs(on: 20261029, weekday: 3))
        #expect(!weekday.runs(on: 20261031, weekday: 5))
        #expect(!weekday.runs(on: 20261126, weekday: 3))
        #expect(!weekday.runs(on: 20270104, weekday: 0))
        #expect(!weekday.runs(on: 20251229, weekday: 0))
        #expect(try #require(index.services["SA"]).runs(on: 20261126, weekday: 3))
    }

    @Test func readsStopTimesForThePickedStopsOnly() throws {
        let calls = try Lakeside.calls(["S1"])
        #expect(Set(calls.calls.map(\.tripID)) == ["B1", "B2", "B3", "N1"])
        #expect(calls.stopIDs == ["S1", "S1A", "S1B"])
        let b1 = try #require(calls.calls.first { $0.tripID == "B1" })
        #expect(b1.stopID == "S1A" && b1.departure == 8 * 3600 + 5 * 60 && b1.boards)
        // Where a trip ends, nobody boards.
        #expect(calls.calls.first { $0.tripID == "B3" }?.boards == false)
        #expect(calls.calls.first { $0.tripID == "N1" }?.departure == 25 * 3600 + 10 * 60)
        // Each trip keeps all its stops, for placing live updates further up the line.
        #expect(calls.trips["B3"]?.stops.map(\.stopID) == ["P3", "S1B"])
        #expect(calls.trips["B1"]?.headsign == "Lakefront")
        #expect(calls.trips["L1"] == nil)
    }

    @Test func keepsAStopHeadsign() throws {
        let calls = try Lakeside.calls(["P1"])
        #expect(calls.calls.first { $0.tripID == "L2" }?.headsign == "Science Hall only")
        #expect(calls.calls.first { $0.tripID == "L1" }?.headsign == nil)
    }

    @Test func readsStopTimesThatAreNotGroupedByTrip() throws {
        let shuffled = """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            L1,08:02:00,08:02:00,P1,1
            L2,08:22:00,08:22:00,P1,1
            L1,08:06:00,08:06:00,P3,2
            L2,08:26:00,08:26:00,P3,2
            L2,08:32:00,08:32:00,P4,3
            L1,08:12:00,08:12:00,P4,3
            """
        let calls = try ScheduleReader.calls(try ZipArchive(Lakeside.zip(["stop_times.txt": shuffled])), at: ["P1"])
        #expect(calls.trips["L1"]?.stops.map(\.stopID) == ["P1", "P3", "P4"])
        #expect(calls.trips["L2"]?.stops.map(\.sequence) == [1, 2, 3])
    }

    @Test func aScheduleNeedsAgencyTimeZoneAndCalendar() throws {
        #expect(throws: ScheduleReader.Failure.noTimezone) {
            try ScheduleReader.index(try ZipArchive(Lakeside.zip(["agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nLT,Lakeside,https://x.example,Mars/Olympus"])))
        }
        #expect(throws: ScheduleReader.Failure.missingFile("calendar.txt")) {
            try ScheduleReader.index(try ZipArchive(Lakeside.zip(["calendar.txt": nil, "calendar_dates.txt": nil])))
        }
        #expect(throws: ScheduleReader.Failure.missingFile("stop_times.txt")) {
            try ScheduleReader.index(try ZipArchive(Lakeside.zip(["stop_times.txt": nil])))
        }
        // calendar_dates.txt alone is enough, as GTFS allows.
        let index = try ScheduleReader.index(try ZipArchive(Lakeside.zip(["calendar.txt": nil])))
        #expect(index.services["SA"]?.added == [20261126])
        // feed_info.txt is optional.
        #expect(try ScheduleReader.index(try ZipArchive(Lakeside.zip(["feed_info.txt": nil]))).scheduleVersion == nil)
    }

    @Test func readsAScheduleZippedInAFolder() throws {
        let files = Lakeside.files.map { ZipWriter.File(name: "lakeside/" + $0.key, data: Data($0.value.utf8)) }
        let index = try ScheduleReader.index(try ZipArchive(ZipWriter.archive(files)))
        #expect(index.routes.count == 3)
    }

    @Test func aTripWithThousandsOfStopsIsRefused() throws {
        let rows = (0...ScheduleReader.maxTripStops).map { "T,08:00:00,08:00:00,P1,\($0)" }.joined(separator: "\n")
        let zip = try ZipArchive(Lakeside.zip(["stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + rows]))
        #expect(throws: ScheduleReader.Failure.tooLarge("stop_times.txt")) { try ScheduleReader.calls(zip, at: ["P1"]) }
    }

    @Test func readsTimes() {
        #expect(ScheduleReader.seconds("08:05:00") == 29100)
        #expect(ScheduleReader.seconds("7:00:00") == 25200)
        #expect(ScheduleReader.seconds("25:10:30") == 90630)
        #expect(ScheduleReader.seconds("") == nil)
        #expect(ScheduleReader.seconds("8:05") == nil)
        #expect(ScheduleReader.seconds("08:61:00") == nil)
        #expect(ScheduleReader.seconds("-1:00:00") == nil)
        #expect(ScheduleReader.seconds("99:00:00") == nil)
    }

    @Test func theIndexSurvivesBeingSaved() throws {
        let index = try Lakeside.index()
        let copy = try JSONDecoder().decode(FeedIndex.self, from: JSONEncoder().encode(index))
        #expect(copy == index)
        let calls = try Lakeside.calls(["S1", "P1"])
        #expect(try JSONDecoder().decode(StopCalls.self, from: JSONEncoder().encode(calls)) == calls)
    }

    @Test func serviceDaysStartAtNoonMinusTwelveHours() throws {
        let calendar = ServiceCalendar(timeZone: Lakeside.timeZone)
        // An ordinary day starts at midnight, 5:00 UTC in Chicago's summer time.
        #expect(calendar.start(of: 20261029) == ISO8601DateFormatter().date(from: "2026-10-29T05:00:00Z"))
        // On the day clocks fall back, it starts at 1:00 AM, so 08:00:00 is still 8 on the clock.
        let fallBack = try #require(calendar.start(of: 20261101))
        #expect(fallBack == ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z"))
        #expect(fallBack.addingTimeInterval(8 * 3600) == ISO8601DateFormatter().date(from: "2026-11-01T14:00:00Z"))
        #expect(calendar.weekday(of: 20261029) == 3)
        #expect(calendar.weekday(of: 20261101) == 6)
        #expect(calendar.days(around: Lakeside.now) == [20261028, 20261029, 20261030])
    }
}

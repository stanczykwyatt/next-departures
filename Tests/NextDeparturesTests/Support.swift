import AppKit
import Foundation
@testable import NextDepartures
@testable import TransitCore

/// A throwaway folder that's removed when the test ends.
final class TestFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("NextDeparturesTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Settings in a suite of their own, so tests never touch the app's real ones.
func testPreferences() -> Preferences {
    let name = "NextDeparturesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return Preferences(defaults: defaults)
}

/// Answers fetches from a table instead of the network, and counts them.
final class FakeFetcher: Fetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Result<FeedFetcher.Response, Error>] = [:]
    private var asked: [URL] = []

    func set(_ url: URL, _ data: Data?) {
        lock.withLock { responses[url] = .success(FeedFetcher.Response(data: data)) }
    }

    func fail(_ url: URL, _ error: Error) {
        lock.withLock { responses[url] = .failure(error) }
    }

    func count(_ url: URL) -> Int { lock.withLock { asked.filter { $0 == url }.count } }

    func fetch(_ url: URL, allowed: Set<String>, limit: Int, etag: String?, lastModified: String?) async throws -> FeedFetcher.Response {
        try lock.withLock {
            asked.append(url)
            guard allowed.contains(url.host ?? "") else { throw FeedFetcher.Failure.notAllowed(url.host ?? "") }
            guard let response = responses[url] else { throw FeedFetcher.Failure.http(404, retryAfter: nil) }
            return try response.get()
        }
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// A made-up agency for the tests and screenshots, Northfield Transit: a light rail line, a campus
/// loop and two buses, around a made-up university. Every name, stop and time is invented.
enum Gallery {
    static let timeZone = TimeZone(identifier: "America/Chicago")!
    /// Thursday 2026-10-29, 8:00 in the morning.
    static let now = date("08:00:00")

    static func date(_ time: String, day: Int = 20261029) -> Date {
        ServiceCalendar(timeZone: timeZone).start(of: day)!.addingTimeInterval(TimeInterval(ScheduleReader.seconds(time)!))
    }

    static let feed = FeedSource(
        id: "northfield", name: "Northfield Transit", area: "A made-up city and university",
        schedule: URL(string: "https://feeds.northfield.example.org/gtfs.zip")!,
        tripUpdates: URL(string: "https://feeds.northfield.example.org/trip-updates.pb")!,
        alerts: URL(string: "https://feeds.northfield.example.org/alerts.pb")!,
        attribution: "Schedules and live departures from Northfield Transit."
    )

    struct Line {
        var route: String
        var headsign: String
        /// The stops in order, with minutes from the first.
        var stops: [(String, Int)]
        var first: Int
        var every: Int
        var count: Int
    }

    static let lines: [Line] = [
        Line(route: "RIV", headsign: "Union Depot", stops: [("U1W", 0), ("U2E", 3), ("U3E", 7), ("U4E", 12)], first: 7 * 60 + 2, every: 10, count: 14),
        Line(route: "RIV", headsign: "Riverside", stops: [("U4W", 0), ("U3W", 5), ("U2W", 9), ("U1E", 12)], first: 7 * 60 + 1, every: 10, count: 14),
        Line(route: "3", headsign: "St. Anne Campus", stops: [("U2B", 0), ("LIB", 4), ("SCI", 8), ("GYM", 14)], first: 7 * 60 + 5, every: 8, count: 18),
        Line(route: "16", headsign: "Downtown", stops: [("RIV4", 0), ("U2B", 6), ("LIB", 9)], first: 7 * 60 + 9, every: 15, count: 10),
        Line(route: "52", headsign: "Lakeview Park & Ride", stops: [("U2B", 0), ("RIV4", 7)], first: 7 * 60 + 24, every: 30, count: 5),
    ]

    static var files: [String: String] {
        var trips = "route_id,service_id,trip_id,trip_headsign,direction_id\n"
        var times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        for (number, line) in lines.enumerated() {
            for run in 0..<line.count {
                let id = "\(line.route)-\(number)-\(run)"
                trips += "\(line.route),WK,\(id),\(line.headsign),\(number % 2)\n"
                for (sequence, (stop, offset)) in line.stops.enumerated() {
                    let minutes = line.first + run * line.every + offset
                    let time = String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
                    times += "\(id),\(time),\(time),\(stop),\(sequence + 1)\n"
                }
            }
        }
        return [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nNT,Northfield Transit,https://northfield.example.org,America/Chicago\n",
            "routes.txt": """
                route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color,route_sort_order
                RIV,NT,,METRO Riverside Line,0,0E8A6E,FFFFFF,1
                3,NT,3,Campus Loop,3,B3243A,FFFFFF,2
                16,NT,16,University Ave,3,2A5DB0,FFFFFF,3
                52,NT,52,Lakeview Express,3,5B5F66,FFFFFF,4

                """,
            "stops.txt": """
                stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon
                U1E,51001,Riverside Station,Eastbound,44.9700,-93.2600
                U1W,51002,Riverside Station,Westbound,44.9701,-93.2601
                U2E,51003,University Station,Eastbound,44.9740,-93.2300
                U2W,51004,University Station,Westbound,44.9741,-93.2301
                U2B,52010,University Station Bus Bay,,44.9745,-93.2305
                U3E,51005,Market Street Station,Eastbound,44.9600,-93.1900
                U3W,51006,Market Street Station,Westbound,44.9601,-93.1901
                U4E,51007,Union Depot Station,,44.9500,-93.0900
                U4W,51008,Union Depot Station,,44.9501,-93.0901
                LIB,52011,Library Mall & Elm St,,44.9760,-93.2350
                SCI,52012,Science Hall,,44.9790,-93.2380
                GYM,52013,Field House Loop,,44.9850,-93.2420
                RIV4,52014,Riverside Ave & 4th St,,44.9690,-93.2450

                """,
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20260101,20261231\n",
            "trips.txt": trips,
            "stop_times.txt": times,
        ]
    }

    static var zip: Data {
        stored(files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8)) })
    }

    /// The live feed at 8:00: some rides running late, one early, one canceled, and an alert.
    static var live: Data {
        var writer = Proto()
        writer.message(1) { header in
            header.string(1, "2.0")
            header.int(3, Int64(now.timeIntervalSince1970))
        }
        // (trip, stop sequence, delay in seconds, canceled)
        let updates: [(String, Int, Int, Bool)] = [
            ("RIV-0-6", 2, 60, false), ("RIV-0-7", 2, 0, false), ("RIV-0-8", 1, 240, false),
            ("RIV-1-6", 3, 120, false), ("RIV-1-7", 2, -60, false),
            ("3-2-6", 1, 180, false), ("3-2-7", 1, 0, false), ("3-2-8", 1, 120, false), ("3-2-9", 1, 0, false),
            ("16-3-3", 1, 0, true), ("16-3-4", 2, 240, false),
        ]
        for (index, update) in updates.enumerated() {
            writer.message(2) { entity in
                entity.string(1, "tu\(index)")
                entity.message(3) { trip in
                    trip.message(1) { descriptor in
                        descriptor.string(1, update.0)
                        descriptor.string(3, "20261029")
                        if update.3 { descriptor.int(4, 3) }
                    }
                    if !update.3 {
                        trip.message(2) { stop in
                            stop.int(1, Int64(update.1))
                            stop.message(3) { $0.int(1, Int64(update.2)) }
                        }
                    }
                }
            }
        }
        writer.message(2) { entity in
            entity.string(1, "alert1")
            entity.message(5) { alert in
                alert.message(5) { $0.string(2, "3") }
                alert.int(7, 4)
                alert.message(10) { $0.message(1) { $0.string(1, "Campus Loop detoured around Library Mall during the book fair") } }
                alert.message(11) { $0.message(1) { $0.string(1, "Board at Science Hall or the University Station bus bay until 6 PM.") } }
            }
        }
        return writer.data
    }

    /// The model with three of the stops picked, the schedule read and the live feed fetched.
    @MainActor
    static func model(in folder: TestFolder, live: Bool = true, clock: TestClock = TestClock(now)) async -> TransitModel {
        let fetcher = FakeFetcher()
        fetcher.set(feed.schedule, zip)
        fetcher.set(feed.tripUpdates!, self.live)
        fetcher.set(feed.alerts!, self.live)
        if !live {
            fetcher.fail(feed.tripUpdates!, FeedFetcher.Failure.offline)
            fetcher.fail(feed.alerts!, FeedFetcher.Failure.offline)
        }
        let preferences = testPreferences()
        preferences.customFeeds = [feed]
        preferences.stops = [
            SavedStop(id: "a", feedID: feed.id, stopIDs: ["U2E", "U2W"], name: "University Station"),
            SavedStop(id: "b", feedID: feed.id, stopIDs: ["LIB"], name: "Library Mall & Elm St"),
            SavedStop(id: "c", feedID: feed.id, stopIDs: ["U2B"], name: "University Station Bus Bay", routes: ["3", "16"]),
        ]
        let library = FeedLibrary(folder: folder.url, fetcher: fetcher, now: { Gallery.now }, retryPause: .milliseconds(1))
        let model = TransitModel(library: library, preferences: preferences, now: { [clock] in MainActor.assumeIsolated { clock.now } })
        await model.refresh()
        return model
    }

    // MARK: Writing files

    /// A zip archive with every file stored, which is all the reader needs to see.
    static func stored(_ files: [(String, Data)]) -> Data {
        var body = Data(), central = Data()
        for (name, data) in files {
            let offset = body.count, nameBytes = Data(name.utf8), crc = CRC32.of(data)
            body.le(UInt32(0x0403_4B50)); body.le(UInt16(20)); body.le(UInt16(0)); body.le(UInt16(0)); body.le(UInt32(0))
            body.le(crc); body.le(UInt32(data.count)); body.le(UInt32(data.count)); body.le(UInt16(nameBytes.count)); body.le(UInt16(0))
            body.append(nameBytes)
            body.append(data)
            central.le(UInt32(0x0201_4B50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0))
            central.le(crc); central.le(UInt32(data.count)); central.le(UInt32(data.count)); central.le(UInt16(nameBytes.count))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(UInt32(offset))
            central.append(nameBytes)
        }
        var data = body
        let start = data.count
        data.append(central)
        data.le(UInt32(0x0605_4B50)); data.le(UInt16(0)); data.le(UInt16(0)); data.le(UInt16(files.count)); data.le(UInt16(files.count))
        data.le(UInt32(central.count)); data.le(UInt32(start)); data.le(UInt16(0))
        return data
    }

    struct Proto {
        var data = Data()

        mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            data.append(UInt8(value))
        }

        mutating func int(_ field: Int, _ value: Int64) {
            varint(UInt64(field << 3))
            varint(UInt64(bitPattern: value))
        }

        mutating func string(_ field: Int, _ value: String) {
            varint(UInt64(field << 3 | 2))
            varint(UInt64(value.utf8.count))
            data.append(Data(value.utf8))
        }

        mutating func message(_ field: Int, _ build: (inout Proto) -> Void) {
            var inner = Proto()
            build(&inner)
            varint(UInt64(field << 3 | 2))
            varint(UInt64(inner.data.count))
            data.append(inner.data)
        }
    }
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

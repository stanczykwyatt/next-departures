import Compression
import Foundation
@testable import TransitCore

/// Writes protocol buffer messages, for building made-up GTFS-realtime feeds.
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func key(_ field: Int, _ type: Int) {
        varint(UInt64(field << 3 | type))
    }

    mutating func int(_ field: Int, _ value: Int64) {
        key(field, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Builds GTFS-realtime feeds the way agencies' servers do, field by field.
enum FeedBuilder {
    struct StopTime {
        var sequence: Int?
        var stopID: String?
        var arrival: (delay: Int?, time: Date?)?
        var departure: (delay: Int?, time: Date?)?
        var relationship = 0
    }

    struct Update {
        var tripID: String?
        var routeID: String?
        var startDate: String?
        var relationship = 0
        var stops: [StopTime] = []
        var delay: Int?
    }

    struct AlertSpec {
        var header: [(String, String?)] = [("Detour on Lake St", nil)]
        var details: [(String, String?)] = []
        var effect: Int? = 4
        var severity: Int?
        var periods: [(Date?, Date?)] = []
        var entities: [(agency: String?, route: String?, stop: String?, trip: String?, routeType: Int?)] = []
    }

    static func feed(timestamp: Date?, updates: [Update] = [], alerts: [AlertSpec] = [], extra: (inout ProtoWriter) -> Void = { _ in }) -> Data {
        var writer = ProtoWriter()
        writer.message(1) { header in
            header.string(1, "2.0")
            header.int(2, 0)
            if let timestamp { header.int(3, Int64(timestamp.timeIntervalSince1970)) }
        }
        for (index, update) in updates.enumerated() {
            writer.message(2) { entity in
                entity.string(1, "tu-\(index)")
                entity.message(3) { trip in
                    trip.message(1) { descriptor in
                        if let id = update.tripID { descriptor.string(1, id) }
                        if let date = update.startDate { descriptor.string(3, date) }
                        if update.relationship != 0 { descriptor.int(4, Int64(update.relationship)) }
                        if let route = update.routeID { descriptor.string(5, route) }
                    }
                    for stop in update.stops {
                        trip.message(2) { stu in
                            if let sequence = stop.sequence { stu.int(1, Int64(sequence)) }
                            for (field, event) in [(2, stop.arrival), (3, stop.departure)] {
                                guard let event else { continue }
                                stu.message(field) { e in
                                    if let delay = event.delay { e.int(1, Int64(delay)) }
                                    if let time = event.time { e.int(2, Int64(time.timeIntervalSince1970)) }
                                }
                            }
                            if let id = stop.stopID { stu.string(4, id) }
                            if stop.relationship != 0 { stu.int(5, Int64(stop.relationship)) }
                        }
                    }
                    if let delay = update.delay { trip.int(5, Int64(delay)) }
                }
            }
        }
        for (index, alert) in alerts.enumerated() {
            writer.message(2) { entity in
                entity.string(1, "alert-\(index)")
                entity.message(5) { a in
                    for (start, end) in alert.periods {
                        a.message(1) { range in
                            if let start { range.int(1, Int64(start.timeIntervalSince1970)) }
                            if let end { range.int(2, Int64(end.timeIntervalSince1970)) }
                        }
                    }
                    for selector in alert.entities {
                        a.message(5) { e in
                            if let agency = selector.agency { e.string(1, agency) }
                            if let route = selector.route { e.string(2, route) }
                            if let type = selector.routeType { e.int(3, Int64(type)) }
                            if let trip = selector.trip { e.message(4) { $0.string(1, trip) } }
                            if let stop = selector.stop { e.string(5, stop) }
                        }
                    }
                    if let effect = alert.effect { a.int(7, Int64(effect)) }
                    for (field, texts) in [(10, alert.header), (11, alert.details)] where !texts.isEmpty {
                        a.message(field) { translated in
                            for (text, language) in texts {
                                translated.message(1) { t in
                                    t.string(1, text)
                                    if let language { t.string(2, language) }
                                }
                            }
                        }
                    }
                    if let severity = alert.severity { a.int(14, Int64(severity)) }
                }
            }
        }
        extra(&writer)
        return writer.data
    }
}

/// Writes zip archives, stored or deflated, to test the reader against.
enum ZipWriter {
    struct File {
        var name: String
        var data: Data
        var deflate = true
    }

    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0)
        return output.prefix(written)
    }

    static func archive(_ files: [File], comment: String = "", zip64: Bool = false) -> Data {
        var body = Data()
        var central = Data()
        for file in files {
            let compressed = file.deflate ? deflate(file.data) : file.data
            let crc = CRC32.of(file.data)
            let offset = body.count
            let name = Data(file.name.utf8)
            body.u32(0x0403_4B50)
            body.u16(20); body.u16(0x0800); body.u16(file.deflate ? 8 : 0); body.u16(0); body.u16(0)
            body.u32(crc); body.u32(UInt32(compressed.count)); body.u32(UInt32(file.data.count))
            body.u16(UInt16(name.count)); body.u16(0)
            body.append(name)
            body.append(compressed)

            central.u32(0x0201_4B50)
            central.u16(20); central.u16(20); central.u16(0x0800); central.u16(file.deflate ? 8 : 0); central.u16(0); central.u16(0)
            central.u32(crc)
            if zip64 {
                central.u32(0xFFFF_FFFF); central.u32(0xFFFF_FFFF)
            } else {
                central.u32(UInt32(compressed.count)); central.u32(UInt32(file.data.count))
            }
            central.u16(UInt16(name.count)); central.u16(zip64 ? 28 : 0); central.u16(0)
            central.u16(0); central.u16(0); central.u32(0)
            central.u32(zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name)
            if zip64 {
                central.u16(0x0001); central.u16(24)
                central.u64(UInt64(file.data.count)); central.u64(UInt64(compressed.count)); central.u64(UInt64(offset))
            }
        }
        var data = body
        let centralOffset = data.count
        data.append(central)
        if zip64 {
            let record = data.count
            data.u32(0x0606_4B50); data.u64(44); data.u16(45); data.u16(45); data.u32(0); data.u32(0)
            data.u64(UInt64(files.count)); data.u64(UInt64(files.count)); data.u64(UInt64(central.count)); data.u64(UInt64(centralOffset))
            data.u32(0x0706_4B50); data.u32(0); data.u64(UInt64(record)); data.u32(1)
        }
        data.u32(0x0605_4B50)
        data.u16(0); data.u16(0)
        data.u16(zip64 ? 0xFFFF : UInt16(files.count)); data.u16(zip64 ? 0xFFFF : UInt16(files.count))
        data.u32(UInt32(central.count)); data.u32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        let commentBytes = Data(comment.utf8)
        data.u16(UInt16(commentBytes.count))
        data.append(commentBytes)
        return data
    }
}

extension Data {
    mutating func u16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// A made-up agency, Lakeside Transit, in Chicago's time zone: a light rail line with a station of
/// two platforms, a campus loop bus, and a late-night trip past midnight. Every name is invented.
enum Lakeside {
    static let timeZone = TimeZone(identifier: "America/Chicago")!

    /// Thursday 2026-10-29, 8:00 in the morning in Chicago.
    static let now = date(20261029, "08:00:00")

    static func date(_ day: Int, _ time: String) -> Date {
        ServiceCalendar(timeZone: timeZone).start(of: day)!.addingTimeInterval(TimeInterval(ScheduleReader.seconds(time)!))
    }

    static let files: [String: String] = [
        "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone
            LT,Lakeside Transit,https://lakeside.example.org,America/Chicago
            """,
        "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color,route_sort_order
            BLUE,LT,,METRO Harbor Line,0,1F6FB2,FFFFFF,1
            LOOP,LT,7,Campus Loop,3,ffcc00,000000,2
            OWL,LT,99,"Night Owl, Late",3,,,
            """,
        "stops.txt": """
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,location_type,parent_station,platform_code
            S1,,Harbor Station,,44.9700,-93.2300,1,,
            S1A,1001,Harbor Station,Platform A,44.9701,-93.2301,0,S1,A
            S1B,1002,Harbor Station,Platform B,44.9702,-93.2302,0,S1,B
            P1,2001,Library Mall & Elm St,Nearside N,44.9750,-93.2350,0,,
            P2,2002,Library Mall & Elm St,Nearside S,44.9751,-93.2351,0,,
            P3,2003,Science Hall,,44.9800,-93.2400,0,,
            P4,2004,Gym Loop,,44.9900,-93.2500,0,,
            E1,,Harbor Station Entrance,,44.9703,-93.2303,2,S1,
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260101,20261231
            SA,0,0,0,0,0,1,0,20260101,20261231
            """,
        "calendar_dates.txt": """
            service_id,date,exception_type
            WK,20261126,2
            SA,20261126,1
            """,
        "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id
            BLUE,WK,B1,Lakefront,0
            BLUE,WK,B2,Lakefront,0
            BLUE,WK,B3,Downtown,1
            LOOP,WK,L1,Gym Loop,0
            LOOP,WK,L2,Gym Loop,0
            LOOP,SA,L3,Gym Loop,0
            OWL,WK,N1,Downtown,1
            """,
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type
            B1,08:05:00,08:05:00,S1A,1,,
            B1,08:15:00,08:15:00,P3,2,,
            B2,08:25:00,08:25:00,S1A,1,,
            B2,08:35:00,08:35:00,P3,2,,
            B3,08:10:00,08:10:00,P3,1,,
            B3,08:20:00,08:20:00,S1B,2,,
            L1,08:02:00,08:02:00,P1,1,,
            L1,08:06:00,08:06:00,P3,2,,
            L1,08:12:00,08:12:00,P4,3,,
            L2,08:22:00,08:22:00,P1,1,Science Hall only,
            L2,08:26:00,08:26:00,P3,2,,
            L2,08:32:00,08:32:00,P4,3,,
            L3,10:00:00,10:00:00,P1,1,,
            L3,10:04:00,10:04:00,P3,2,,
            N1,24:30:00,24:30:00,P2,1,,
            N1,25:10:00,25:10:00,S1B,2,,
            """,
        "feed_info.txt": """
            feed_publisher_name,feed_publisher_url,feed_lang,feed_version,feed_end_date
            Lakeside Transit,https://lakeside.example.org,en,2026-fall,20261231
            """,
    ]

    static func zip(_ overrides: [String: String?] = [:], deflate: Bool = true) -> Data {
        var files = files
        for (name, value) in overrides { files[name] = value }
        return ZipWriter.archive(files.sorted { $0.key < $1.key }.compactMap { name, text in
            ZipWriter.File(name: name, data: Data(text.replacingOccurrences(of: "\n            ", with: "\n").utf8), deflate: deflate)
        })
    }

    static func index() throws -> FeedIndex {
        try ScheduleReader.index(try ZipArchive(zip()))
    }

    static func calls(_ stops: Set<String>) throws -> StopCalls {
        let index = try index()
        let family = stops.reduce(into: Set<String>()) { $0.formUnion(index.stopFamily($1)) }
        return try ScheduleReader.calls(try ZipArchive(zip()), at: family)
    }

    static let feed = FeedSource(
        id: "lakeside", name: "Lakeside Transit", area: "Made up",
        schedule: URL(string: "https://feeds.lakeside.example.org/gtfs.zip")!,
        tripUpdates: URL(string: "https://feeds.lakeside.example.org/trips.pb")!,
        alerts: URL(string: "https://feeds.lakeside.example.org/alerts.pb")!
    )
}

/// Answers fetches from a table instead of the network, and remembers what was asked.
final class FakeFetcher: Fetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Result<FeedFetcher.Response, Error>] = [:]
    private(set) var requests: [(url: URL, etag: String?, modified: String?)] = []

    func set(_ url: URL, _ data: Data?, etag: String? = nil, modified: String? = nil) {
        lock.withLock { responses[url] = .success(FeedFetcher.Response(data: data, etag: etag, lastModified: modified)) }
    }

    func fail(_ url: URL, _ error: Error) {
        lock.withLock { responses[url] = .failure(error) }
    }

    /// Fails the next request for `url` with `error`, then answers as before.
    func failOnce(_ url: URL, _ error: Error) {
        lock.withLock { once[url] = error }
    }

    private var once: [URL: Error] = [:]

    var count: Int { lock.withLock { requests.count } }

    func fetch(_ url: URL, allowed: Set<String>, limit: Int, etag: String?, lastModified: String?) async throws -> FeedFetcher.Response {
        try lock.withLock {
            requests.append((url, etag, lastModified))
            guard allowed.contains(url.host ?? "") else { throw FeedFetcher.Failure.notAllowed(url.host ?? "") }
            if let error = once.removeValue(forKey: url) { throw error }
            guard let response = responses[url] else { throw FeedFetcher.Failure.http(404, retryAfter: nil) }
            return try response.get()
        }
    }
}

/// A throwaway folder that's removed when the test ends.
final class TestFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("TransitCoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The same pseudo-random bytes on every run, so a fuzz failure can be repeated.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

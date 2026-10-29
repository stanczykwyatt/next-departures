import Foundation

/// An agency's schedule, read from its GTFS zip: who runs it, its routes and stops, which days
/// each service runs, and which routes call at each stop. Small enough to keep and search.
/// The stop times themselves are read only for the stops you pick; see `StopCalls`.
public struct FeedIndex: Codable, Sendable, Equatable {
    public static let formatVersion = 2

    public var version = FeedIndex.formatVersion
    public var timezone: String
    public var agencies: [Agency]
    public var routes: [String: Route]
    public var stops: [Stop]
    public var services: [String: Service]
    /// The agency's own name for this version of the schedule, from feed_info.txt.
    public var scheduleVersion: String?
    /// The last day the schedule covers, as YYYYMMDD, if the agency says.
    public var endDate: Int?

    public init(timezone: String, agencies: [Agency], routes: [String: Route], stops: [Stop], services: [String: Service], scheduleVersion: String? = nil, endDate: Int? = nil) {
        self.timezone = timezone
        self.agencies = agencies
        self.routes = routes
        self.stops = stops
        self.services = services
        self.scheduleVersion = scheduleVersion
        self.endDate = endDate
    }

    public var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    public func stop(_ id: String) -> Stop? {
        stops.first { $0.id == id }
    }

    /// The stop and its platforms, if it's a station with stops inside it.
    public func stopFamily(_ id: String) -> Set<String> {
        var family: Set<String> = [id]
        for stop in stops where stop.parent == id { family.insert(stop.id) }
        return family
    }

    /// Routes that call at a stop or its platforms, in the agency's order.
    public func routes(at id: String) -> [Route] {
        let family = stopFamily(id)
        let ids = Set(stops.filter { family.contains($0.id) }.flatMap(\.routeIDs))
        return ids.compactMap { routes[$0] }.sorted()
    }
}

public struct Agency: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    public var url: String?
    public var timezone: String
}

public struct Route: Codable, Sendable, Hashable, Comparable {
    public var id: String
    public var agencyID: String?
    public var shortName: String?
    public var longName: String?
    /// The route's color as six hex digits, if the agency gives one.
    public var color: String?
    public var textColor: String?
    /// GTFS route_type: 0 tram or light rail, 1 subway, 2 rail, 3 bus, and so on.
    public var type: Int
    public var sortOrder: Int?
    /// The agency's description, which some put the route's full name in.
    public var desc: String?

    public init(id: String, agencyID: String? = nil, shortName: String? = nil, longName: String? = nil, color: String? = nil, textColor: String? = nil, type: Int = 3, sortOrder: Int? = nil, desc: String? = nil) {
        self.id = id
        self.agencyID = agencyID
        self.shortName = shortName
        self.longName = longName
        self.color = color
        self.textColor = textColor
        self.type = type
        self.sortOrder = sortOrder
        self.desc = desc
    }

    /// The short name riders know, like "121", or the long one if there's no short name.
    public var name: String {
        shortName ?? longName ?? id
    }

    public static func < (a: Route, b: Route) -> Bool {
        switch (a.sortOrder, b.sortOrder) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

public struct Stop: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The number on the sign at the stop, which riders often know it by.
    public var code: String?
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    /// The station this stop is a platform of.
    public var parent: String?
    /// GTFS location_type: 0 a stop or platform, 1 a station.
    public var locationType: Int
    public var platform: String?
    /// The agency's note on where the stop is, like "Nearside W".
    public var desc: String?
    public var routeIDs: [String]

    public init(id: String, code: String? = nil, name: String, latitude: Double? = nil, longitude: Double? = nil, parent: String? = nil, locationType: Int = 0, platform: String? = nil, desc: String? = nil, routeIDs: [String] = []) {
        self.id = id
        self.code = code
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.parent = parent
        self.locationType = locationType
        self.platform = platform
        self.desc = desc
        self.routeIDs = routeIDs
    }

    public var isStation: Bool { locationType == 1 }
}

/// Which days a service runs: weekdays between two dates, plus or minus single days.
public struct Service: Codable, Sendable, Equatable {
    /// Monday first.
    public var weekdays: [Bool]
    public var start: Int?
    public var end: Int?
    public var added: Set<Int>
    public var removed: Set<Int>

    public init(weekdays: [Bool] = Array(repeating: false, count: 7), start: Int? = nil, end: Int? = nil, added: Set<Int> = [], removed: Set<Int> = []) {
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.added = added
        self.removed = removed
    }

    /// Whether it runs on a day, given as YYYYMMDD and its weekday, Monday 0.
    public func runs(on day: Int, weekday: Int) -> Bool {
        if removed.contains(day) { return false }
        if added.contains(day) { return true }
        guard weekday >= 0, weekday < weekdays.count, weekdays[weekday] else { return false }
        if let start, day < start { return false }
        if let end, day > end { return false }
        return true
    }
}

// MARK: Stop times for the stops you pick

/// Every scheduled call at the stops you've picked, and enough about each trip to place the live
/// updates for it: its route, headsign and the stops it calls at in order.
public struct StopCalls: Codable, Sendable, Equatable {
    public struct Call: Codable, Sendable, Equatable {
        public var tripID: String
        public var stopID: String
        public var sequence: Int
        /// Seconds from the start of the service day, which can run past 24:00:00.
        public var departure: Int
        /// False at a stop where riders can't board, like the end of the line.
        public var boards: Bool
        public var headsign: String?
    }

    public struct Trip: Codable, Sendable, Equatable {
        public var routeID: String
        public var serviceID: String
        public var headsign: String?
        public var directionID: Int?
        /// Every stop the trip calls at, in order, with its scheduled departure.
        public var stops: [TripStop]
    }

    public struct TripStop: Codable, Sendable, Equatable {
        public var stopID: String
        public var sequence: Int
        public var departure: Int
    }

    public var stopIDs: Set<String>
    public var calls: [Call]
    public var trips: [String: Trip]

    public init(stopIDs: Set<String>, calls: [Call], trips: [String: Trip]) {
        self.stopIDs = stopIDs
        self.calls = calls
        self.trips = trips
    }
}

// MARK: Reading the zip

public enum ScheduleReader {
    public enum Failure: Error, Equatable {
        case missingFile(String)
        case noTimezone
        case tooLarge(String)
    }

    /// No agency has anywhere near this many stops, routes or trips. The limits keep a hostile or
    /// broken file from using up memory.
    static let maxStops = 200_000
    static let maxRoutes = 20_000
    static let maxTrips = 2_000_000
    static let maxCalls = 200_000
    static let maxAgencies = 1_000
    static let maxServices = 100_000
    static let maxServiceDates = 2_000_000
    /// No trip calls at anywhere near this many stops.
    static let maxTripStops = 5_000
    static let maxKeptTripStops = 5_000_000

    /// Reads everything but the stop times' details: agencies, routes, stops, calendars, and which
    /// routes call at each stop.
    public static func index(_ zip: ZipArchive) throws -> FeedIndex {
        var agencies: [Agency] = []
        try rows(zip, "agency.txt") { row in
            guard let name = row("agency_name"), let timezone = row("agency_timezone") else { return }
            guard agencies.count < maxAgencies else { throw Failure.tooLarge("agency.txt") }
            agencies.append(Agency(id: row("agency_id"), name: name, url: row("agency_url"), timezone: timezone))
        }
        guard let timezone = agencies.first?.timezone, TimeZone(identifier: timezone) != nil else { throw Failure.noTimezone }

        var routes: [String: Route] = [:]
        try rows(zip, "routes.txt") { row in
            guard let id = row("route_id") else { return }
            guard routes.count < maxRoutes else { throw Failure.tooLarge("routes.txt") }
            routes[id] = Route(
                id: id, agencyID: row("agency_id"), shortName: row("route_short_name"), longName: row("route_long_name"),
                color: hex(row("route_color")), textColor: hex(row("route_text_color")),
                type: row("route_type").flatMap { Int($0) } ?? 3, sortOrder: row("route_sort_order").flatMap { Int($0) },
                desc: row("route_desc").map { String($0.prefix(200)) }
            )
        }

        var stops: [Stop] = []
        var stopIndex: [String: Int] = [:]
        try rows(zip, "stops.txt") { row in
            guard let id = row("stop_id") else { return }
            let type = row("location_type").flatMap { Int($0) } ?? 0
            // Entrances, generic nodes and boarding areas aren't places to wait for a ride.
            guard type == 0 || type == 1, stopIndex[id] == nil else { return }
            guard stops.count < maxStops else { throw Failure.tooLarge("stops.txt") }
            stopIndex[id] = stops.count
            stops.append(Stop(
                id: id, code: row("stop_code"), name: row("stop_name") ?? id,
                latitude: row("stop_lat").flatMap { Double($0) }, longitude: row("stop_lon").flatMap { Double($0) },
                parent: row("parent_station"), locationType: type, platform: row("platform_code"), desc: row("stop_desc")
            ))
        }

        let services = try readServices(zip)

        // Which routes call at each stop: the trip's route, for each stop it calls at.
        var tripRoutes: [String: Int32] = [:]
        let routeIDs = Array(routes.keys)
        let routeNumbers = Dictionary(uniqueKeysWithValues: routeIDs.enumerated().map { ($1, Int32($0)) })
        try rows(zip, "trips.txt") { row in
            guard let trip = row("trip_id"), let route = row("route_id"), let number = routeNumbers[route] else { return }
            guard tripRoutes.count < maxTrips else { throw Failure.tooLarge("trips.txt") }
            tripRoutes[trip] = number
        }
        var served = Array(repeating: Set<Int32>(), count: stops.count)
        var lastTrip = ""
        var lastRoute: Int32?
        try rows(zip, "stop_times.txt") { row in
            guard let trip = row("trip_id"), let stop = row("stop_id"), let index = stopIndex[stop] else { return }
            // Stop times come grouped by trip, so the last lookup is usually the right one.
            if trip != lastTrip {
                lastTrip = trip
                lastRoute = tripRoutes[trip]
            }
            if let route = lastRoute { served[index].insert(route) }
        }
        // A station has no stop times of its own, so it's served by whatever calls at its platforms.
        for index in stops.indices {
            if let parent = stops[index].parent, let station = stopIndex[parent] { served[station].formUnion(served[index]) }
        }
        for index in stops.indices {
            stops[index].routeIDs = served[index].map { routeIDs[Int($0)] }.sorted()
        }

        var version: String?
        var endDate: Int?
        if zip.entry("feed_info.txt") != nil {
            try rows(zip, "feed_info.txt") { row in
                version = version ?? row("feed_version")
                endDate = endDate ?? row("feed_end_date").flatMap { Int($0) }
            }
        }
        return FeedIndex(timezone: timezone, agencies: agencies, routes: routes, stops: stops, services: services, scheduleVersion: version, endDate: endDate)
    }

    /// Every scheduled call at `stopIDs`, with each trip's route, headsign and stops.
    public static func calls(_ zip: ZipArchive, at stopIDs: Set<String>) throws -> StopCalls {
        guard !stopIDs.isEmpty else { return StopCalls(stopIDs: [], calls: [], trips: [:]) }
        var calls: [StopCalls.Call] = []
        var tripStops: [String: [StopCalls.TripStop]] = [:]

        // Trips are nearly always listed together, so the current one's stops are kept until the
        // next trip starts, and only kept for good if it calls at a picked stop. A trip that shows
        // up again later, in a file that isn't grouped, has its stops filled in on a second pass.
        var current = ""
        var buffer: [StopCalls.TripStop] = []
        var keep = false
        var finished: Set<String> = []
        var regrouped: Set<String> = []
        var kept = 0
        func flush() throws {
            if keep {
                kept += buffer.count
                guard kept <= maxKeptTripStops else { throw Failure.tooLarge("stop_times.txt") }
                tripStops[current, default: []].append(contentsOf: buffer)
            }
            if !current.isEmpty { finished.insert(current) }
            buffer.removeAll(keepingCapacity: true)
            keep = false
        }
        try rows(zip, "stop_times.txt") { row in
            guard let trip = row("trip_id"), let stop = row("stop_id"),
                  let time = (row("departure_time") ?? row("arrival_time")).flatMap(seconds) else { return }
            let sequence = row("stop_sequence").flatMap { Int($0) } ?? buffer.count
            if trip != current {
                try flush()
                current = trip
                if finished.contains(trip) { regrouped.insert(trip) }
            }
            guard buffer.count < maxTripStops else { throw Failure.tooLarge("stop_times.txt") }
            buffer.append(StopCalls.TripStop(stopID: stop, sequence: sequence, departure: time))
            if stopIDs.contains(stop) {
                keep = true
                guard calls.count < maxCalls else { throw Failure.tooLarge("stop_times.txt") }
                calls.append(StopCalls.Call(
                    tripID: trip, stopID: stop, sequence: sequence, departure: time,
                    boards: row("pickup_type") != "1", headsign: row("stop_headsign")
                ))
            }
        }
        try flush()
        let wanted = Set(calls.map(\.tripID))
        if !regrouped.isDisjoint(with: wanted) {
            // Rare: start again for the trips that were split up.
            let split = regrouped.intersection(wanted)
            for trip in split { tripStops[trip] = [] }
            try rows(zip, "stop_times.txt") { row in
                guard let trip = row("trip_id"), split.contains(trip), let stop = row("stop_id"),
                      let time = (row("departure_time") ?? row("arrival_time")).flatMap(seconds) else { return }
                let sequence = row("stop_sequence").flatMap { Int($0) } ?? tripStops[trip]!.count
                guard tripStops[trip]!.count < maxTripStops else { throw Failure.tooLarge("stop_times.txt") }
                tripStops[trip]!.append(StopCalls.TripStop(stopID: stop, sequence: sequence, departure: time))
            }
        }

        var trips: [String: StopCalls.Trip] = [:]
        try rows(zip, "trips.txt") { row in
            guard let id = row("trip_id"), wanted.contains(id), let route = row("route_id"), let service = row("service_id") else { return }
            trips[id] = StopCalls.Trip(
                routeID: route, serviceID: service, headsign: row("trip_headsign"),
                directionID: row("direction_id").flatMap { Int($0) },
                stops: (tripStops[id] ?? []).sorted { $0.sequence < $1.sequence }
            )
        }
        // The last stop of a trip is where it ends, so nobody can board there whatever the file says.
        for index in calls.indices {
            if let trip = trips[calls[index].tripID], trip.stops.last?.sequence == calls[index].sequence {
                calls[index].boards = false
            }
        }
        calls.removeAll { trips[$0.tripID] == nil }
        return StopCalls(stopIDs: stopIDs, calls: calls, trips: trips)
    }

    // MARK: Helpers

    static func readServices(_ zip: ZipArchive) throws -> [String: Service] {
        var services: [String: Service] = [:]
        if zip.entry("calendar.txt") != nil {
            try rows(zip, "calendar.txt") { row in
                guard let id = row("service_id") else { return }
                guard services.count < maxServices else { throw Failure.tooLarge("calendar.txt") }
                let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].map { row($0) == "1" }
                services[id] = Service(weekdays: days, start: row("start_date").flatMap { Int($0) }, end: row("end_date").flatMap { Int($0) })
            }
        }
        if zip.entry("calendar_dates.txt") != nil {
            var dates = 0
            try rows(zip, "calendar_dates.txt") { row in
                guard let id = row("service_id"), let date = row("date").flatMap({ Int($0) }) else { return }
                dates += 1
                guard dates <= maxServiceDates, services.count <= maxServices else { throw Failure.tooLarge("calendar_dates.txt") }
                var service = services[id] ?? Service()
                switch row("exception_type") {
                case "1": service.added.insert(date)
                case "2": service.removed.insert(date)
                default: return
                }
                services[id] = service
            }
        }
        // One or the other is required, so a schedule with neither has nothing that runs.
        guard zip.entry("calendar.txt") != nil || zip.entry("calendar_dates.txt") != nil else { throw Failure.missingFile("calendar.txt") }
        return services
    }

    static func rows(_ zip: ZipArchive, _ file: String, _ body: @escaping (CSVReader.Row) throws -> Void) throws {
        guard let entry = zip.entry(file) else { throw Failure.missingFile(file) }
        var reader = CSVReader(file: file, onRow: body)
        try zip.read(entry) { try reader.feed($0) }
        try reader.finish()
    }

    /// "HH:MM:SS" as seconds. Hours can pass 24 for trips that run after midnight, and some
    /// agencies leave off the leading zero.
    public static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              h >= 0, h < 48, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func hex(_ text: String?) -> String? {
        guard let text, text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return text.uppercased()
    }
}

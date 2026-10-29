import Foundation

/// The parts of a GTFS-realtime feed that departures and alerts need: trip updates and service
/// alerts. Vehicle positions, shapes and the rest are skipped.
///
/// Field numbers are from the GTFS-realtime reference, gtfs-realtime.proto.
public struct RealtimeFeed: Sendable, Equatable {
    public var version = ""
    /// When the feed was made, by the agency's clock.
    public var timestamp: Date?
    /// True if the feed only sends what changed, which this app doesn't support. Almost every feed is full.
    public var isDifferential = false
    public var tripUpdates: [TripUpdate] = []
    public var alerts: [Alert] = []

    public init() {}

    /// A feed can't hold more than this many entities without being something other than a transit
    /// feed. The limit keeps a hostile one from using up memory one tiny entity at a time.
    public static let maxEntities = 200_000
    /// Across the whole feed. A stop update is a couple of bytes on the wire but about a hundred in
    /// memory, so these keep a hostile feed from turning 40 MB into gigabytes. Metro Transit's busiest
    /// feed has well under a tenth of this.
    public static let maxStopUpdates = 400_000
    public static let maxAlertParts = 100_000

    public static func decode(_ data: Data) throws -> RealtimeFeed {
        try ProtoReader.read(data) { reader in
            var feed = RealtimeFeed()
            var entities = 0
            var stopCount = (updates: 0, stops: 0, alerts: 0, parts: 0)
            while let field = try reader.next() {
                switch (field.number, field.wireType) {
                case (1, .lengthDelimited):
                    try reader.message { header in
                        while let field = try header.next() {
                            switch (field.number, field.wireType) {
                            case (1, .lengthDelimited): feed.version = try header.string()
                            case (2, .varint): feed.isDifferential = try header.varint() == 1
                            case (3, .varint): feed.timestamp = date(try header.varint())
                            default: try header.skip(field)
                            }
                        }
                    }
                case (2, .lengthDelimited):
                    entities += 1
                    guard entities <= maxEntities else { throw Failure.tooManyEntities }
                    try reader.message { entity in try readEntity(&entity, into: &feed) }
                    if let update = feed.tripUpdates.last, feed.tripUpdates.count == stopCount.updates + 1 {
                        stopCount.updates += 1
                        stopCount.stops += update.stopTimes.count
                    }
                    if feed.alerts.count == stopCount.alerts + 1, let alert = feed.alerts.last {
                        stopCount.alerts += 1
                        stopCount.parts += alert.entities.count + alert.periods.count + alert.header.count + alert.details.count + alert.url.count
                    }
                    guard stopCount.stops <= maxStopUpdates, stopCount.parts <= maxAlertParts else { throw Failure.tooManyEntities }
                default:
                    try reader.skip(field)
                }
            }
            return feed
        }
    }

    public enum Failure: Error, Equatable {
        case tooManyEntities
    }

    private static func readEntity(_ reader: inout ProtoReader, into feed: inout RealtimeFeed) throws {
        var id = ""
        var deleted = false
        var update: TripUpdate?
        var alert: Alert?
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): id = try reader.string()
            case (2, .varint): deleted = try reader.bool()
            case (3, .lengthDelimited): update = try reader.message(TripUpdate.read)
            case (5, .lengthDelimited): alert = try reader.message(Alert.read)
            default: try reader.skip(field)
            }
        }
        // A deleted entity only means something in a differential feed, which isn't read.
        guard !deleted else { return }
        if var update {
            update.entityID = id
            feed.tripUpdates.append(update)
        }
        if var alert {
            alert.id = id
            feed.alerts.append(alert)
        }
    }

    /// POSIX seconds, kept only if they're a plausible date: anything before 2000 or after 2100 is
    /// treated as missing rather than as a real time.
    static func date(_ seconds: UInt64) -> Date? {
        guard seconds >= 946_684_800, seconds <= 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func date(_ seconds: Int64) -> Date? {
        seconds < 0 ? nil : date(UInt64(seconds))
    }
}

/// Which trip an update or alert is about.
public struct TripDescriptor: Sendable, Equatable, Hashable {
    public enum Relationship: Int, Sendable {
        case scheduled = 0, added = 1, unscheduled = 2, canceled = 3, replacement = 5, duplicated = 6, deleted = 7, new = 8
    }

    public var tripID: String?
    public var routeID: String?
    public var directionID: Int?
    /// The trip's first departure, as "HH:MM:SS", which tells apart runs of a trip that repeats.
    public var startTime: String?
    /// The service day, as "YYYYMMDD".
    public var startDate: String?
    public var relationship: Relationship = .scheduled

    public init(tripID: String? = nil, routeID: String? = nil, directionID: Int? = nil, startTime: String? = nil, startDate: String? = nil, relationship: Relationship = .scheduled) {
        self.tripID = tripID
        self.routeID = routeID
        self.directionID = directionID
        self.startTime = startTime
        self.startDate = startDate
        self.relationship = relationship
    }

    static func read(_ reader: inout ProtoReader) throws -> TripDescriptor {
        var trip = TripDescriptor()
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): trip.tripID = try reader.string()
            case (2, .lengthDelimited): trip.startTime = try reader.string()
            case (3, .lengthDelimited): trip.startDate = try reader.string()
            // Unknown values, from a newer version of the spec, are read as scheduled.
            case (4, .varint): trip.relationship = Relationship(rawValue: Int(try reader.int32())) ?? .scheduled
            case (5, .lengthDelimited): trip.routeID = try reader.string()
            case (6, .varint): trip.directionID = Int(try reader.uint32() & 1)
            default: try reader.skip(field)
            }
        }
        return trip
    }
}

public struct TripUpdate: Sendable, Equatable {
    public var entityID = ""
    public var trip = TripDescriptor()
    public var vehicleLabel: String?
    public var stopTimes: [StopTimeUpdate] = []
    /// When the vehicle's progress was last measured.
    public var timestamp: Date?
    /// A delay for the whole trip, used when no stop has its own.
    public var delay: Int?

    public init(trip: TripDescriptor = TripDescriptor(), stopTimes: [StopTimeUpdate] = [], timestamp: Date? = nil, delay: Int? = nil, vehicleLabel: String? = nil) {
        self.trip = trip
        self.stopTimes = stopTimes
        self.timestamp = timestamp
        self.delay = delay
        self.vehicleLabel = vehicleLabel
    }

    /// No trip calls at more stops than this. More would be a broken or hostile feed.
    static let maxStops = 2_000

    static func read(_ reader: inout ProtoReader) throws -> TripUpdate {
        var update = TripUpdate()
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): update.trip = try reader.message(TripDescriptor.read)
            case (2, .lengthDelimited):
                let stop = try reader.message(StopTimeUpdate.read)
                if update.stopTimes.count < maxStops { update.stopTimes.append(stop) }
            case (3, .lengthDelimited):
                update.vehicleLabel = try reader.message { vehicle in
                    var id: String?, label: String?
                    while let field = try vehicle.next() {
                        switch (field.number, field.wireType) {
                        case (1, .lengthDelimited): id = try vehicle.string()
                        case (2, .lengthDelimited): label = try vehicle.string()
                        default: try vehicle.skip(field)
                        }
                    }
                    return label ?? id
                }
            case (4, .varint): update.timestamp = RealtimeFeed.date(try reader.varint())
            case (5, .varint): update.delay = Int(try reader.int32())
            default: try reader.skip(field)
            }
        }
        return update
    }
}

public struct StopTimeUpdate: Sendable, Equatable {
    public enum Relationship: Int, Sendable {
        case scheduled = 0, skipped = 1, noData = 2, unscheduled = 3
    }

    public struct Event: Sendable, Equatable {
        /// Seconds late, or early if negative.
        public var delay: Int?
        /// The predicted time itself, which wins over `delay` when both are sent.
        public var time: Date?

        public init(delay: Int? = nil, time: Date? = nil) {
            self.delay = delay
            self.time = time
        }

        static func read(_ reader: inout ProtoReader) throws -> Event {
            var event = Event()
            while let field = try reader.next() {
                switch (field.number, field.wireType) {
                case (1, .varint): event.delay = Int(try reader.int32())
                case (2, .varint): event.time = RealtimeFeed.date(try reader.int64())
                default: try reader.skip(field)
                }
            }
            return event
        }

        var isEmpty: Bool { delay == nil && time == nil }
    }

    public var stopSequence: Int?
    public var stopID: String?
    public var arrival: Event?
    public var departure: Event?
    public var relationship: Relationship = .scheduled

    public init(stopSequence: Int? = nil, stopID: String? = nil, arrival: Event? = nil, departure: Event? = nil, relationship: Relationship = .scheduled) {
        self.stopSequence = stopSequence
        self.stopID = stopID
        self.arrival = arrival
        self.departure = departure
        self.relationship = relationship
    }

    static func read(_ reader: inout ProtoReader) throws -> StopTimeUpdate {
        var update = StopTimeUpdate()
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .varint): update.stopSequence = Int(try reader.uint32())
            case (2, .lengthDelimited): update.arrival = try reader.message(Event.read)
            case (3, .lengthDelimited): update.departure = try reader.message(Event.read)
            case (4, .lengthDelimited): update.stopID = try reader.string()
            case (5, .varint): update.relationship = Relationship(rawValue: Int(try reader.int32())) ?? .scheduled
            default: try reader.skip(field)
            }
        }
        return update
    }
}

/// A service alert: a detour, a closed stop, a delay.
public struct Alert: Sendable, Equatable, Identifiable {
    public enum Effect: Int, Sendable {
        case noService = 1, reducedService, significantDelays, detour, additionalService, modifiedService, other, unknown, stopMoved, noEffect, accessibilityIssue
    }

    public enum Severity: Int, Sendable, Comparable {
        case unknown = 1, info, warning, severe
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// What an alert is about. Any field left out matches everything.
    public struct Entity: Sendable, Equatable {
        public var agencyID: String?
        public var routeID: String?
        public var routeType: Int?
        public var tripID: String?
        public var stopID: String?
        public var directionID: Int?

        public init(agencyID: String? = nil, routeID: String? = nil, routeType: Int? = nil, tripID: String? = nil, stopID: String? = nil, directionID: Int? = nil) {
            self.agencyID = agencyID
            self.routeID = routeID
            self.routeType = routeType
            self.tripID = tripID
            self.stopID = stopID
            self.directionID = directionID
        }
    }

    public struct Period: Sendable, Equatable {
        public var start: Date?
        public var end: Date?

        public init(start: Date? = nil, end: Date? = nil) {
            self.start = start
            self.end = end
        }

        public func contains(_ date: Date) -> Bool {
            (start.map { date >= $0 } ?? true) && (end.map { date < $0 } ?? true)
        }
    }

    public var id = ""
    public var periods: [Period] = []
    public var entities: [Entity] = []
    public var effect: Effect = .unknown
    public var severity: Severity = .unknown
    /// Each translation of the headline and the details, keyed by language tag. An empty tag is the
    /// feed's own language.
    public var header: [String: String] = [:]
    public var details: [String: String] = [:]
    public var url: [String: String] = [:]

    public init(id: String = "", periods: [Period] = [], entities: [Entity] = [], effect: Effect = .unknown, severity: Severity = .unknown, header: [String: String] = [:], details: [String: String] = [:], url: [String: String] = [:]) {
        self.id = id
        self.periods = periods
        self.entities = entities
        self.effect = effect
        self.severity = severity
        self.header = header
        self.details = details
        self.url = url
    }

    /// An alert with no periods is in effect for as long as it's in the feed.
    public func isActive(at date: Date) -> Bool {
        periods.isEmpty || periods.contains { $0.contains(date) }
    }

    static let maxEntities = 2_000

    static func read(_ reader: inout ProtoReader) throws -> Alert {
        var alert = Alert()
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let period = try reader.message { range in
                    var period = Period()
                    while let field = try range.next() {
                        switch (field.number, field.wireType) {
                        case (1, .varint): period.start = RealtimeFeed.date(try range.varint())
                        case (2, .varint): period.end = RealtimeFeed.date(try range.varint())
                        default: try range.skip(field)
                        }
                    }
                    return period
                }
                if alert.periods.count < maxEntities { alert.periods.append(period) }
            case (5, .lengthDelimited):
                let entity = try reader.message(readEntity)
                if alert.entities.count < maxEntities { alert.entities.append(entity) }
            case (7, .varint): alert.effect = Effect(rawValue: Int(try reader.int32())) ?? .unknown
            case (8, .lengthDelimited): alert.url = try reader.message(translations)
            case (10, .lengthDelimited): alert.header = try reader.message(translations)
            case (11, .lengthDelimited): alert.details = try reader.message(translations)
            case (14, .varint): alert.severity = Severity(rawValue: Int(try reader.int32())) ?? .unknown
            default: try reader.skip(field)
            }
        }
        return alert
    }

    private static func readEntity(_ reader: inout ProtoReader) throws -> Entity {
        var entity = Entity()
        while let field = try reader.next() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): entity.agencyID = try reader.string()
            case (2, .lengthDelimited): entity.routeID = try reader.string()
            case (3, .varint): entity.routeType = Int(try reader.int32())
            case (4, .lengthDelimited):
                let trip = try reader.message(TripDescriptor.read)
                entity.tripID = trip.tripID
                if entity.routeID == nil { entity.routeID = trip.routeID }
            case (5, .lengthDelimited): entity.stopID = try reader.string()
            case (6, .varint): entity.directionID = Int(try reader.uint32() & 1)
            default: try reader.skip(field)
            }
        }
        return entity
    }

    /// A TranslatedString: one or more texts, each with an optional language tag.
    private static func translations(_ reader: inout ProtoReader) throws -> [String: String] {
        var result: [String: String] = [:]
        while let field = try reader.next() {
            guard field.number == 1, field.wireType == .lengthDelimited else {
                try reader.skip(field)
                continue
            }
            let (text, language) = try reader.message { translation in
                var text = "", language = ""
                while let field = try translation.next() {
                    switch (field.number, field.wireType) {
                    case (1, .lengthDelimited): text = try translation.string()
                    case (2, .lengthDelimited): language = try translation.string()
                    default: try translation.skip(field)
                    }
                }
                return (text, language.lowercased())
            }
            if result.count < 64, result[language] == nil { result[language] = text }
        }
        return result
    }
}

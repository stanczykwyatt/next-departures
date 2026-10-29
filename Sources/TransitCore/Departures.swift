import Foundation

/// One ride leaving a stop: when it's scheduled, when the agency now expects it, and whether it's running.
public struct Departure: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Only the timetable: the feed has nothing live for this trip.
        case scheduled
        /// The feed's prediction for this trip.
        case live
        case canceled
        /// The trip runs, but not past this stop.
        case skipped
    }

    public var id: String
    public var tripID: String?
    public var stopID: String
    public var route: Route
    public var headsign: String?
    public var scheduled: Date?
    public var predicted: Date?
    public var status: Status

    /// The time to show and sort by: the prediction if there is one.
    public var time: Date { predicted ?? scheduled ?? .distantFuture }

    /// Seconds late, or early if negative, when there's both a prediction and a timetable.
    public var delay: TimeInterval? {
        guard let predicted, let scheduled else { return nil }
        return predicted.timeIntervalSince(scheduled)
    }
}

/// The days of service around a moment, in the agency's own time zone.
public struct ServiceCalendar: Sendable {
    public let timeZone: TimeZone
    private let calendar: Calendar

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// GTFS counts a service day's times from noon minus twelve hours, which is midnight except on
    /// the days clocks change, when it keeps times on the timetable lined up with the clock.
    public func start(of day: Int) -> Date? {
        let components = DateComponents(year: day / 10000, month: day / 100 % 100, day: day % 100, hour: 12)
        return calendar.date(from: components).map { $0.addingTimeInterval(-12 * 3600) }
    }

    /// The service day a moment falls on, as YYYYMMDD, plus the days either side.
    public func days(around date: Date) -> [Int] {
        [-1, 0, 1].compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: date).map(day)
        }
    }

    public func day(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year! * 10000 + parts.month! * 100 + parts.day!
    }

    /// Monday 0 to Sunday 6.
    public func weekday(of day: Int) -> Int {
        guard let start = start(of: day) else { return 0 }
        let weekday = calendar.component(.weekday, from: start.addingTimeInterval(12 * 3600))
        return (weekday + 5) % 7
    }
}

public enum DepartureBoard {
    /// Past departures stay on the board for a moment, so one doesn't vanish as it pulls in.
    public static let grace: TimeInterval = 60
    /// Live data older than this is treated as missing. A stuck feed shouldn't look live.
    public static let staleAfter: TimeInterval = 5 * 60

    /// The next departures from a stop and its platforms, live where the feed has them and from
    /// the timetable otherwise.
    public static func departures(
        at stopIDs: [String], index: FeedIndex, calls: StopCalls, realtime: RealtimeFeed?, now: Date,
        horizon: TimeInterval = 3 * 3600, limit: Int = 6, routes onlyRoutes: Set<String> = []
    ) -> [Departure] {
        let family = stopIDs.reduce(into: Set<String>()) { $0.formUnion(index.stopFamily($1)) }
        let calendar = ServiceCalendar(timeZone: index.timeZone)
        let live = realtime.flatMap { isFresh($0, now: now) ? $0 : nil }
        let updates = live.map(updatesByTrip) ?? [:]
        let window = (now.addingTimeInterval(-grace), now.addingTimeInterval(horizon))

        var departures: [Departure] = []
        var placed: Set<String> = []
        for day in calendar.days(around: now) {
            guard let start = calendar.start(of: day) else { continue }
            let weekday = calendar.weekday(of: day)
            let dayText = String(day)
            for call in calls.calls where family.contains(call.stopID) && call.boards {
                guard let trip = calls.trips[call.tripID], let route = index.routes[trip.routeID],
                      onlyRoutes.isEmpty || onlyRoutes.contains(route.id),
                      index.services[trip.serviceID]?.runs(on: day, weekday: weekday) == true else { continue }
                let scheduled = start.addingTimeInterval(TimeInterval(call.departure))
                // Anything far outside the window can't be pulled into it by a delay.
                guard scheduled > window.0.addingTimeInterval(-3 * 3600), scheduled < window.1.addingTimeInterval(3600) else { continue }
                var departure = Departure(
                    id: "\(call.tripID)|\(dayText)|\(call.sequence)", tripID: call.tripID, stopID: call.stopID, route: route,
                    headsign: call.headsign ?? trip.headsign ?? route.longName, scheduled: scheduled, predicted: nil, status: .scheduled
                )
                if let update = match(updates[call.tripID], day: dayText, call: call, start: start, now: now) {
                    placed.insert(update.entityID + "|" + call.tripID)
                    apply(update, to: &departure, call: call, trip: trip, start: start)
                }
                departures.append(departure)
            }
        }

        // Trips the timetable doesn't have, like extra service, when the feed gives a time at this stop.
        if let live {
            for update in live.tripUpdates where !placed.contains(update.entityID + "|" + (update.trip.tripID ?? "")) {
                if let tripID = update.trip.tripID, calls.trips[tripID] != nil { continue }
                // Only trips the feed says are extra. An unknown trip marked scheduled is usually one
                // from a newer timetable than the one here, which would otherwise show twice.
                guard [.added, .new, .duplicated, .unscheduled, .replacement].contains(update.trip.relationship),
                      let routeID = update.trip.routeID, let route = index.routes[routeID],
                      onlyRoutes.isEmpty || onlyRoutes.contains(routeID) else { continue }
                for stop in update.stopTimes where stop.stopID.map(family.contains) == true && stop.relationship != .skipped {
                    guard let time = stop.departure?.time ?? stop.arrival?.time else { continue }
                    departures.append(Departure(
                        id: "rt|\(update.entityID)|\(stop.stopSequence ?? 0)|\(stop.stopID ?? "")", tripID: update.trip.tripID,
                        stopID: stop.stopID ?? stopIDs.first ?? "", route: route, headsign: route.longName, scheduled: nil, predicted: time, status: .live
                    ))
                }
            }
        }

        return departures
            .filter { $0.time >= window.0 && $0.time <= window.1 }
            .sorted { $0.time == $1.time ? $0.route < $1.route : $0.time < $1.time }
            .prefix(limit)
            .map { $0 }
    }

    public static func isFresh(_ feed: RealtimeFeed, now: Date) -> Bool {
        // A feed without a timestamp can't be judged, so it's trusted as just fetched.
        guard let stamp = feed.timestamp else { return true }
        return now.timeIntervalSince(stamp) < staleAfter
    }

    static func updatesByTrip(_ feed: RealtimeFeed) -> [String: [TripUpdate]] {
        var result: [String: [TripUpdate]] = [:]
        for update in feed.tripUpdates {
            guard let id = update.trip.tripID else { continue }
            result[id, default: []].append(update)
        }
        return result
    }

    /// The update for this run of the trip. When a feed names the service day, it must match.
    /// Without a day, an update is taken to be for the run nearest now, so yesterday's or
    /// tomorrow's run of the same trip doesn't borrow today's prediction.
    static func match(_ updates: [TripUpdate]?, day: String, call: StopCalls.Call, start: Date, now: Date) -> TripUpdate? {
        guard let updates, !updates.isEmpty else { return nil }
        if let dated = updates.first(where: { $0.trip.startDate == day }) { return dated }
        let scheduled = start.addingTimeInterval(TimeInterval(call.departure))
        guard abs(scheduled.timeIntervalSince(now)) < 12 * 3600 else { return nil }
        return updates.first { $0.trip.startDate == nil }
    }

    static func apply(_ update: TripUpdate, to departure: inout Departure, call: StopCalls.Call, trip: StopCalls.Trip, start: Date) {
        if update.trip.relationship == .canceled || update.trip.relationship == .deleted {
            departure.status = .canceled
            return
        }
        let sequences = Dictionary(trip.stops.map { ($0.stopID, $0.sequence) }, uniquingKeysWith: { first, _ in first })
        let scheduledAt = Dictionary(trip.stops.map { ($0.sequence, $0.departure) }, uniquingKeysWith: { first, _ in first })
        func sequence(_ stop: StopTimeUpdate) -> Int? {
            stop.stopSequence ?? stop.stopID.flatMap { sequences[$0] }
        }

        // This stop's own update, if the feed has one.
        if let own = update.stopTimes.first(where: { sequence($0) == call.sequence || ($0.stopSequence == nil && $0.stopID == call.stopID) }) {
            switch own.relationship {
            case .skipped:
                departure.status = .skipped
                return
            case .noData:
                return
            default:
                if let time = predicted(own, scheduled: departure.scheduled) {
                    departure.predicted = time
                    departure.status = .live
                    return
                }
            }
        }
        // Otherwise the last update before this stop carries its delay down the line, as the spec says.
        let earlier = update.stopTimes
            .compactMap { stop in sequence(stop).map { (stop, $0) } }
            .filter { $0.1 < call.sequence }
            .max { $0.1 < $1.1 }
        if let (stop, seq) = earlier {
            if stop.relationship == .noData { return }
            var delay: TimeInterval?
            if let seconds = (stop.departure?.delay ?? stop.arrival?.delay) {
                delay = TimeInterval(seconds)
            } else if let time = stop.departure?.time ?? stop.arrival?.time, let planned = scheduledAt[seq] {
                delay = time.timeIntervalSince(start.addingTimeInterval(TimeInterval(planned)))
            }
            if let delay, let scheduled = departure.scheduled {
                // A bus running early catches up at timepoints, so only lateness carries forward.
                departure.predicted = scheduled.addingTimeInterval(max(0, delay))
                departure.status = .live
                return
            }
        }
        if let delay = update.delay, let scheduled = departure.scheduled {
            departure.predicted = scheduled.addingTimeInterval(TimeInterval(delay))
            departure.status = .live
        }
    }

    static func predicted(_ stop: StopTimeUpdate, scheduled: Date?) -> Date? {
        for event in [stop.departure, stop.arrival].compactMap({ $0 }) {
            if let time = event.time { return time }
            if let delay = event.delay, let scheduled { return scheduled.addingTimeInterval(TimeInterval(delay)) }
        }
        return nil
    }
}

public enum AlertMatcher {
    /// The directions trips leave these stops in, from the timetable, or nil if it doesn't say.
    public static func directions(at stopIDs: [String], index: FeedIndex, calls: StopCalls) -> Set<Int>? {
        let family = stopIDs.reduce(into: Set<String>()) { $0.formUnion(index.stopFamily($1)) }
        let found = Set(calls.calls.filter { family.contains($0.stopID) }.compactMap { calls.trips[$0.tripID]?.directionID })
        return found.isEmpty ? nil : found
    }

    /// Alerts in effect now that touch a stop: the stop itself, a route that calls there, or the
    /// whole agency. Most severe first.
    /// With `onlyRoutes`, alerts about other routes are left out, as they are from the board.
    /// With `directions`, the directions trips leave the stop in, an alert for one direction of a
    /// route is left out at a stop only the other direction serves.
    public static func alerts(for stopIDs: [String], index: FeedIndex, feed: RealtimeFeed?, now: Date, tripIDs: Set<String> = [], onlyRoutes: Set<String> = [], directions: Set<Int>? = nil) -> [Alert] {
        guard let feed else { return [] }
        let family = stopIDs.reduce(into: Set<String>()) { $0.formUnion(index.stopFamily($1)) }
        let parents = Set(stopIDs.compactMap { index.stop($0)?.parent })
        let routes = Array(Set(stopIDs.flatMap { index.routes(at: $0) })).sorted().filter { onlyRoutes.isEmpty || onlyRoutes.contains($0.id) }
        let routeIDs = Set(routes.map(\.id))
        let routeTypes = Set(routes.map(\.type))
        let agencyIDs = Set(routes.compactMap(\.agencyID))
        return feed.alerts
            .filter { $0.isActive(at: now) && $0.entities.contains { matches($0) } }
            .sorted { $0.severity > $1.severity }

        func matches(_ entity: Alert.Entity) -> Bool {
            if let stop = entity.stopID, !(family.contains(stop) || parents.contains(stop)) { return false }
            if let route = entity.routeID, !routeIDs.contains(route) { return false }
            if let trip = entity.tripID, !tripIDs.contains(trip) { return false }
            if let type = entity.routeType, !routeTypes.contains(type) { return false }
            if let direction = entity.directionID, let directions, !directions.contains(direction) { return false }
            // An agency named alone means all of its service; with only one agency, an ID may be left out.
            if let agency = entity.agencyID, !agencyIDs.isEmpty, !agencyIDs.contains(agency), index.agencies.count > 1 { return false }
            return entity.stopID != nil || entity.routeID != nil || entity.tripID != nil || entity.routeType != nil || entity.agencyID != nil
        }
    }

    /// The translation that best fits the languages you use: your own, then the feed's untagged
    /// text, then English, then whatever there is.
    public static func text(_ translations: [String: String], languages: [String] = Locale.preferredLanguages) -> String? {
        for language in languages.map({ $0.lowercased() }) {
            if let exact = translations[language] { return exact }
            let base = String(language.prefix { $0 != "-" })
            if let match = translations.first(where: { $0.key == base || $0.key.hasPrefix(base + "-") }) { return match.value }
        }
        return translations[""] ?? translations["en"] ?? translations.sorted { $0.key < $1.key }.first?.value
    }
}

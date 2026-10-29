import Foundation

/// The wording shown in the menu, the window and the command line.
public enum Describe {
    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// When a departure leaves, the way a station sign says it: "Now", "4 min", or the clock time
    /// once it's an hour or more away.
    public static func until(_ date: Date, now: Date, clock: DateFormatter) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return clock.string(from: date)
    }

    /// A clock in the agency's time zone, like "4:05 PM", so times match the stop's signs even when
    /// your Mac is set to another zone.
    public static func clock(_ timeZone: TimeZone, locale: Locale = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    /// How a departure is running: "Live", "3 min late", "Scheduled", "Canceled".
    public static func status(_ departure: Departure) -> String {
        switch departure.status {
        case .scheduled: return "Scheduled"
        case .canceled: return "Canceled"
        case .skipped: return "Skips this stop"
        case .live:
            guard let delay = departure.delay else { return "Live" }
            if abs(delay) < 60 { return "On time" }
            let minutes = Int((abs(delay) / 60).rounded())
            return delay > 0 ? "\(minutes) min late" : "\(minutes) min early"
        }
    }

    /// A route and where it's headed, like "16 to Downtown" or "Green Line to Union Depot". When
    /// the headsign is just the route's own name, like a campus loop's, it's "121 Campus Connector".
    public static func line(_ departure: Departure) -> String {
        let route = routeName(departure.route)
        guard let headsign = departure.headsign.map({ clean($0) }), !headsign.isEmpty, headsign != route else { return route }
        let names = [departure.route.longName, departure.route.desc].compactMap { $0.map { clean($0) } }
        if names.contains(where: { $0.localizedCaseInsensitiveContains(headsign) }) {
            return departure.route.shortName == nil ? route : "\(route) \(headsign)"
        }
        return "\(route) to \(headsign)"
    }

    /// The short name riders know. "METRO Green Line" is shortened to "Green Line", as on the signs.
    public static func routeName(_ route: Route) -> String {
        var name = clean(route.shortName ?? route.longName ?? route.id)
        if name.hasPrefix("METRO ") { name.removeFirst(6) }
        return name
    }

    public static func effect(_ effect: Alert.Effect) -> String {
        switch effect {
        case .noService: return "No service"
        case .reducedService: return "Reduced service"
        case .significantDelays: return "Delays"
        case .detour: return "Detour"
        case .additionalService: return "Extra service"
        case .modifiedService: return "Service change"
        case .stopMoved: return "Stop moved"
        case .accessibilityIssue: return "Accessibility"
        case .noEffect, .other, .unknown: return "Alert"
        }
    }

    /// A stop as riders know it: its name, with its sign number if it has one.
    public static func stop(_ stop: Stop) -> String {
        let name = clean(stop.name)
        if let code = stop.code.map({ clean($0) }), !code.isEmpty, code != name { return "\(name) (#\(code))" }
        return name
    }

    /// Text from a feed is the agency's, but it reaches the menu and your terminal, so control
    /// characters and invisible marks are taken out, whitespace is collapsed, and it's cut to a
    /// sensible length.
    public static func clean(_ text: String, limit: Int = 400) -> String {
        var result = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            let space = CharacterSet.whitespacesAndNewlines.contains(scalar) || category == .lineSeparator || category == .paragraphSeparator
            // Escape codes and invisible marks, like the ones that flip text right to left, are dropped.
            if !space, category == .format || category == .control || category == .privateUse || category == .unassigned { continue }
            if space {
                if !lastWasSpace, !result.isEmpty { result.append(" ") }
                lastWasSpace = true
                continue
            }
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
            if result.count >= limit {
                return result + "…"
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Why something went wrong, in a sentence.
    public static func problem(_ error: Error) -> String {
        switch error {
        case FeedFetcher.Failure.offline: return "You're offline."
        case FeedFetcher.Failure.http(let code, _) where code == 429: return "The feed asked to be checked less often. Trying again later."
        case FeedFetcher.Failure.http(let code, _) where code == 404: return "The feed's server couldn't find its file (404). Trying again soon."
        case FeedFetcher.Failure.http(let code, _) where code >= 500: return "The agency's server isn't answering right now (\(code))."
        case FeedFetcher.Failure.http(let code, _): return "The feed's server refused the request (\(code))."
        case FeedFetcher.Failure.tooLarge: return "The feed's file is far larger than any real one, so it wasn't downloaded."
        case FeedFetcher.Failure.redirectedElsewhere: return "The feed tried to send the app to another website, which it never follows."
        case FeedFetcher.Failure.notAllowed: return "That address isn't one of your feeds."
        case FeedFetcher.Failure.network(let message): return "Couldn't reach the feed: \(clean(message, limit: 120))"
        case is ZipArchive.Failure: return "The schedule isn't a zip file the app can read."
        case ScheduleReader.Failure.missingFile(let file): return "The schedule has no \(file)."
        case ScheduleReader.Failure.noTimezone: return "The schedule doesn't say which time zone it's in."
        case is ScheduleReader.Failure: return "The schedule is far larger than any real one, so it wasn't read."
        case is ProtoReader.Failure, is RealtimeFeed.Failure: return "The live feed couldn't be read. Showing the timetable."
        case is CSVReader.Failure: return "A file in the schedule is damaged."
        default: return "Something went wrong: \(clean(error.localizedDescription, limit: 120))"
        }
    }
}

/// A place to wait: one stop, or stops with the same name a short walk apart, like the two sides
/// of a street or a station's two platforms. Picking it shows rides in both directions.
public struct StopGroup: Sendable, Equatable, Identifiable {
    public var name: String
    public var stops: [Stop]
    public var routeIDs: [String]

    public var id: String { stops.map(\.id).joined(separator: "+") }
    public var stopIDs: [String] { stops.map(\.id) }
    public var codes: [String] { stops.compactMap(\.code) }
}

/// Finds stops by name, sign number or route.
public enum StopSearch {
    /// Stops this close together with the same name are offered as one place.
    public static let groupDistance = 250.0

    /// Stops whose name or sign number has every word you typed, best matches first. Platforms are
    /// left out when their station can be picked instead.
    public static func find(_ query: String, in index: FeedIndex, route: String? = nil, limit: Int = 60) -> [StopGroup] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let stations = Set(index.stops.filter(\.isStation).map(\.id))
        var results: [(Stop, Int)] = []
        for stop in index.stops {
            if stop.routeIDs.isEmpty { continue }
            if let route, !stop.routeIDs.contains(route) { continue }
            if let parent = stop.parent, stations.contains(parent) { continue }
            let name = stop.name.lowercased()
            var score = 0
            var matched = true
            for word in words {
                if stop.code?.lowercased() == word || stop.id.lowercased() == word { score += 100 }
                else if name.hasPrefix(word) { score += 20 }
                else if name.contains(" " + word) || name.contains("&" + word) || name.contains("/" + word) || name.contains("(" + word) { score += 10 }
                else if name.contains(word) { score += 2 }
                else { matched = false; break }
            }
            if matched { results.append((stop, score)) }
        }
        results.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }

        var groups: [StopGroup] = []
        var scores: [Int] = []
        for (stop, score) in results {
            if let at = groups.firstIndex(where: { $0.name == stop.name && $0.stops.contains { near($0, stop) } }) {
                groups[at].stops.append(stop)
                groups[at].routeIDs = Array(Set(groups[at].routeIDs + stop.routeIDs)).sorted()
                scores[at] = max(scores[at], score)
            } else {
                // A sign number names one stop exactly, so it isn't grouped with the other side of the street.
                groups.append(StopGroup(name: stop.name, stops: [stop], routeIDs: stop.routeIDs))
                scores.append(score)
            }
            if groups.count > limit * 2 { break }
        }
        let exact = words.count == 1 ? words[0] : nil
        if let exact, let at = groups.firstIndex(where: { $0.codes.contains { $0.lowercased() == exact } }) {
            let group = groups[at]
            if let only = group.stops.first(where: { $0.code?.lowercased() == exact }) {
                groups[at] = StopGroup(name: only.name, stops: [only], routeIDs: only.routeIDs)
            }
        }
        return Array(groups.prefix(limit))
    }

    static func near(_ a: Stop, _ b: Stop) -> Bool {
        guard let lat1 = a.latitude, let lon1 = a.longitude, let lat2 = b.latitude, let lon2 = b.longitude else { return false }
        return distance(lat1, lon1, lat2, lon2) <= groupDistance
    }

    /// Meters between two points, close enough for a few hundred meters.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let x = (lon2 - lon1) * radians * cos((lat1 + lat2) / 2 * radians)
        let y = (lat2 - lat1) * radians
        return (x * x + y * y).squareRoot() * 6_371_000
    }
}

import Foundation

/// The `next-departures` command line tool: find stops and print the next departures and alerts,
/// for scripts, a terminal status line or Shortcuts. It uses the same feeds and code as the app.
public enum Command: Equatable {
    case feeds
    case stops(query: String, route: String?)
    case departures(stop: String, route: String?, limit: Int, json: Bool)
    case alerts(stop: String?)
    case help
    case version

    public static let toolVersion = "0.1.0"

    public static let usage = """
        next-departures \(toolVersion): the next departures from any stop, live where the feed has it.

        Usage:
          next-departures feeds                          The feeds you can use
          next-departures stops <words> [--route <id>]   Find stops by name or sign number
          next-departures departures <stop> [--limit <n>] [--route <id>] [--json]
          next-departures alerts [<stop>]                Service alerts, for one stop or all

        Feed options:
          --feed <id>              One of the feeds listed by `next-departures feeds` (default metro-transit)
          --schedule <url>         Or any agency's GTFS schedule zip, with:
          --trip-updates <url>     its GTFS-realtime trip updates, and
          --alerts <url>           its GTFS-realtime service alerts
          --help, --version

        <stop> is a stop ID or the number on the stop's sign. Schedules are kept in
        ~/Library/Caches/next-departures and checked for updates once a day.
        """

    public enum ParseError: Error, Equatable {
        case message(String)
    }

    public struct Parsed: Equatable {
        public var command: Command
        public var feed: FeedSource
    }

    static let valued: Set<String> = ["--feed", "--schedule", "--trip-updates", "--alerts", "--route", "--limit"]

    public static func parse(_ arguments: [String], presets: [FeedSource] = FeedSource.presets) throws -> Parsed {
        var rest: [String] = []
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw ParseError.message("\(argument) needs a value.") }
                values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") { flags.insert(argument) } else if argument == "-h" { flags.insert("--help") } else { rest.append(argument) }
            index += 1
        }

        let feed = try feed(values, presets: presets)
        if flags.contains("--help") { return Parsed(command: .help, feed: feed) }
        if flags.contains("--version") { return Parsed(command: .version, feed: feed) }
        guard let name = rest.first else { return Parsed(command: .help, feed: feed) }
        if let unknown = flags.subtracting(["--json"]).sorted().first {
            throw ParseError.message("Unknown option \(unknown). See next-departures --help.")
        }
        let limit: Int
        if let text = values["--limit"] {
            guard let number = Int(text), number > 0, number <= 100 else { throw ParseError.message("--limit needs a number from 1 to 100.") }
            limit = number
        } else {
            limit = 8
        }
        let route = values["--route"]
        switch name {
        case "feeds":
            return Parsed(command: .feeds, feed: feed)
        case "stops":
            let query = rest.dropFirst().joined(separator: " ")
            guard !query.isEmpty || route != nil else { throw ParseError.message("stops needs words to look for, like: next-departures stops east bank") }
            return Parsed(command: .stops(query: query, route: route), feed: feed)
        case "departures":
            guard rest.count == 2 else { throw ParseError.message("departures needs one stop, like: next-departures departures 56042") }
            return Parsed(command: .departures(stop: rest[1], route: route, limit: limit, json: flags.contains("--json")), feed: feed)
        case "alerts":
            guard rest.count <= 2 else { throw ParseError.message("alerts takes at most one stop.") }
            return Parsed(command: .alerts(stop: rest.count == 2 ? rest[1] : nil), feed: feed)
        default:
            throw ParseError.message("Unknown command \(name). See next-departures --help.")
        }
    }

    static func feed(_ values: [String: String], presets: [FeedSource]) throws -> FeedSource {
        if let schedule = values["--schedule"] {
            guard values["--feed"] == nil else { throw ParseError.message("Use --feed or --schedule, not both.") }
            func url(_ flag: String) throws -> URL? {
                guard let text = values[flag] else { return nil }
                switch FeedSource.check(text) {
                case .success(let url): return url
                case .failure: throw ParseError.message("\(flag) needs an https address on the internet.")
                }
            }
            guard let scheduleURL = try url("--schedule") else { throw ParseError.message("--schedule needs an address.") }
            _ = schedule
            return FeedSource(
                id: "custom-" + String(format: "%08x", stableHash(scheduleURL.absoluteString)), name: scheduleURL.host ?? "Custom feed", area: "",
                schedule: scheduleURL, tripUpdates: try url("--trip-updates"), alerts: try url("--alerts")
            )
        }
        if values["--trip-updates"] != nil || values["--alerts"] != nil {
            throw ParseError.message("--trip-updates and --alerts go with --schedule.")
        }
        let id = values["--feed"] ?? presets.first?.id ?? ""
        guard let feed = presets.first(where: { $0.id == id }) else { throw ParseError.message("No feed called \(id). See next-departures feeds.") }
        return feed
    }

    /// The same number for the same address on every run, unlike Swift's own hash.
    static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }

    // MARK: Running

    public static func run(
        _ arguments: [String], library: FeedLibrary, now: Date = Date(), languages: [String] = Locale.preferredLanguages,
        out: (String) -> Void, err: (String) -> Void
    ) async -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(arguments)
        } catch ParseError.message(let message) {
            err(message)
            return 64
        } catch {
            return 64
        }
        let feed = parsed.feed
        do {
            switch parsed.command {
            case .help:
                out(usage)
            case .version:
                out(toolVersion)
            case .feeds:
                for preset in FeedSource.presets {
                    out("\(preset.id)\t\(preset.name): \(preset.area)")
                }
                out("\nOr use any agency's feed with --schedule, --trip-updates and --alerts.")
            case .stops(let query, let route):
                let index = try await library.index(for: feed)
                let groups = StopSearch.find(query, in: index, route: route, limit: 30)
                if groups.isEmpty { err("No stops match \"\(Describe.clean(query))\".") ; return 1 }
                for group in groups {
                    for stop in group.stops {
                        let routes = stop.routeIDs.compactMap { index.routes[$0] }.sorted().map(Describe.routeName).joined(separator: ", ")
                        let where_ = stop.desc.map { " · " + Describe.clean($0, limit: 40) } ?? ""
                        out("\(stop.code ?? stop.id)\t\(Describe.clean(stop.name))\(where_)\t\(routes)")
                    }
                }
            case .departures(let stopText, let route, let limit, let json):
                let index = try await library.index(for: feed)
                guard let stop = find(stopText, in: index) else { err("No stop with ID or number \(Describe.clean(stopText)). Try: next-departures stops <words>"); return 1 }
                let calls = try await library.calls(for: feed, stops: [stop.id])
                var live: FeedLibrary.Live?
                var liveProblem: String?
                if feed.tripUpdates != nil || feed.alerts != nil {
                    do { live = try await library.live(for: feed) } catch { liveProblem = Describe.problem(error) }
                }
                let departures = DepartureBoard.departures(
                    at: [stop.id], index: index, calls: calls, realtime: live?.feed, now: now, limit: limit, routes: route.map { [$0] } ?? []
                )
                if json {
                    out(Self.json(departures, stop: stop))
                    return 0
                }
                let clock = Describe.clock(index.timeZone)
                out(Describe.stop(stop))
                if departures.isEmpty { out("  No departures in the next three hours.") }
                for departure in departures {
                    let when = Describe.until(departure.time, now: now, clock: clock)
                    out("  \(when.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Describe.line(departure))  ·  \(Describe.status(departure))")
                }
                if let liveProblem { err(liveProblem) }
                let trips = Set(departures.compactMap(\.tripID))
                let directions = AlertMatcher.directions(at: [stop.id], index: index, calls: calls)
                for alert in AlertMatcher.alerts(for: [stop.id], index: index, feed: live?.feed, now: now, tripIDs: trips, onlyRoutes: route.map { [$0] } ?? [], directions: directions) {
                    out("  ! \(Describe.effect(alert.effect)): \(Describe.clean(AlertMatcher.text(alert.header, languages: languages) ?? ""))")
                }
            case .alerts(let stopText):
                let index = try await library.index(for: feed)
                let live = try await library.live(for: feed)
                var alerts = live.feed.alerts.filter { $0.isActive(at: now) }
                if let stopText {
                    guard let stop = find(stopText, in: index) else { err("No stop with ID or number \(Describe.clean(stopText))."); return 1 }
                    alerts = AlertMatcher.alerts(for: [stop.id], index: index, feed: live.feed, now: now)
                }
                if alerts.isEmpty { out("No alerts.") }
                for alert in alerts {
                    out("\(Describe.effect(alert.effect)): \(Describe.clean(AlertMatcher.text(alert.header, languages: languages) ?? ""))")
                    if let details = AlertMatcher.text(alert.details, languages: languages), !details.isEmpty {
                        out("  " + Describe.clean(details, limit: 600))
                    }
                }
            }
            return 0
        } catch {
            err(Describe.problem(error))
            return 1
        }
    }

    /// A stop by its ID or the number on its sign.
    static func find(_ text: String, in index: FeedIndex) -> Stop? {
        index.stop(text) ?? index.stops.first { $0.code == text }
    }

    static func json(_ departures: [Departure], stop: Stop) -> String {
        let formatter = ISO8601DateFormatter()
        let items: [[String: Any]] = departures.map { departure in
            var item: [String: Any] = [
                "route": Describe.routeName(departure.route), "routeID": departure.route.id,
                "status": "\(departure.status)", "time": formatter.string(from: departure.time),
            ]
            if let headsign = departure.headsign { item["headsign"] = Describe.clean(headsign) }
            if let scheduled = departure.scheduled { item["scheduled"] = formatter.string(from: scheduled) }
            if let predicted = departure.predicted { item["predicted"] = formatter.string(from: predicted) }
            if let tripID = departure.tripID { item["tripID"] = tripID }
            return item
        }
        let object: [String: Any] = ["stop": ["id": stop.id, "code": stop.code ?? "", "name": Describe.clean(stop.name)], "departures": items]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

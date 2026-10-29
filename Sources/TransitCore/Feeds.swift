import Foundation

/// Where an agency publishes its data: a schedule zip, and optionally live trip updates and alerts.
public struct FeedSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Where it runs, in a few words.
    public var area: String
    public var schedule: URL
    public var tripUpdates: URL?
    public var alerts: URL?
    /// Credit the agency asks for, shown wherever its data is.
    public var attribution: String?
    /// Routes to offer first when picking a stop, by route_id.
    public var featuredRoutes: [String]

    public init(id: String, name: String, area: String, schedule: URL, tripUpdates: URL? = nil, alerts: URL? = nil, attribution: String? = nil, featuredRoutes: [String] = []) {
        self.id = id
        self.name = name
        self.area = area
        self.schedule = schedule
        self.tripUpdates = tripUpdates
        self.alerts = alerts
        self.attribution = attribution
        self.featuredRoutes = featuredRoutes
    }

    /// The only feeds that come with the app. Metro Transit publishes them openly for anyone to
    /// use, with no key. Its schedule also covers the University of Minnesota's campus buses.
    public static let presets: [FeedSource] = [
        FeedSource(
            id: "metro-transit", name: "Metro Transit",
            area: "Minneapolis and Saint Paul: METRO light rail, buses, and University of Minnesota campus buses",
            schedule: URL(string: "https://svc.metrotransit.org/mtgtfs/gtfs.zip")!,
            tripUpdates: URL(string: "https://svc.metrotransit.org/mtgtfs/tripupdates.pb")!,
            alerts: URL(string: "https://svc.metrotransit.org/mtgtfs/alerts.pb")!,
            attribution: "Schedules, live departures and alerts from Metro Transit, a service of the Metropolitan Council.",
            // The Green Line, then the campus buses: Connector, the circulators and the Dinkytown route.
            featuredRoutes: ["902", "121", "120", "122", "123", "124", "125", "901"]
        ),
    ]

    /// Every address this feed is fetched from. The app connects to these hosts and no others.
    public var urls: [URL] {
        [schedule, tripUpdates, alerts].compactMap { $0 }
    }

    public var hosts: Set<String> {
        Set(urls.compactMap { $0.host?.lowercased() })
    }

    public var isPreset: Bool {
        Self.presets.contains { $0.id == id }
    }

    /// Whether an id is safe to use as a folder name.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } && !id.hasPrefix("-")
    }

    public enum URLProblem: Error, Equatable {
        case empty, notHTTPS, noHost, hasPassword, tooLong, local
    }

    /// Checks an address someone pasted. Only plain https addresses on the internet are taken, with
    /// no sign-in details in them: the app never sends a feed anything it didn't ask for.
    public static func check(_ text: String) -> Result<URL, URLProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= 2048 else { return .failure(.tooLong) }
        guard let components = URLComponents(string: trimmed), let url = components.url else { return .failure(.notHTTPS) }
        guard components.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.noHost) }
        guard components.user == nil, components.password == nil else { return .failure(.hasPassword) }
        if isLocal(host) { return .failure(.local) }
        var clean = components
        clean.fragment = nil
        return .success(clean.url ?? url)
    }

    /// Names and addresses on this Mac or the local network. A feed someone pastes is meant to be an
    /// agency's, so these are refused. IP addresses are read the way the system reads them, so
    /// shorthand like 127.1 or 0x7f.0.0.1 is caught too. A public name that the network's own DNS
    /// points at a private address can't be told apart here.
    static func isLocal(_ text: String) -> Bool {
        var host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || !host.contains(".") && !host.contains(":") { return true }
        let suffixes = ["localhost", ".local", ".internal", ".lan", ".home", ".localdomain", ".home.arpa", ".corp", ".intranet"]
        if host == "localhost" || suffixes.contains(where: { host.hasSuffix($0) }) { return true }
        if let v4 = ipv4(host) { return isPrivate(v4) }
        var v6 = in6_addr()
        if host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            // An IPv4 address written as IPv6, like ::ffff:127.0.0.1.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPrivate(UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
            }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) { return true } // :: and ::1
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true } // link-local
            if bytes[0] & 0xFE == 0xFC { return true } // unique local
            if bytes[0] == 0xFF { return true } // multicast
            return false
        }
        return false
    }

    /// The address if `host` is an IPv4 address in any form the system accepts.
    static func ipv4(_ host: String) -> UInt32? {
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), host.first?.isNumber == true else { return nil }
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        let a = ip >> 24, b = ip >> 16 & 0xFF
        switch (a, b) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31), (100, 64...127), (198, 18...19): return true
        case (224..., _): return true // multicast and reserved
        default: return false
        }
    }
}

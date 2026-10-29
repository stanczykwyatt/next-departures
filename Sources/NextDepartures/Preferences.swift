import Foundation
import TransitCore

/// A stop you've picked: one stop, or both sides of a street or a station's platforms.
struct SavedStop: Codable, Hashable, Identifiable {
    var id: String
    var feedID: String
    var stopIDs: [String]
    var name: String
    /// Only these routes, or every route if empty.
    var routes: [String] = []

    init(id: String = UUID().uuidString, feedID: String, stopIDs: [String], name: String, routes: [String] = []) {
        self.id = id
        self.feedID = feedID
        self.stopIDs = stopIDs
        self.name = name
        self.routes = routes
    }
}

/// Settings, kept in the app's sandbox container.
struct Preferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let stops = "savedStops"
        static let feeds = "customFeeds"
        static let menuBarTime = "showsNextDepartureInMenuBar"
        static let launchedBefore = "launchedBefore"
    }

    /// No one needs more stops than fit in a menu.
    static let maxStops = 12
    static let maxFeeds = 20

    var stops: [SavedStop] {
        get { decode(Key.stops) ?? [] }
        nonmutating set { encode(Array(newValue.prefix(Self.maxStops)), Key.stops) }
    }

    /// Feeds you've added. Each one's addresses are checked again when read, so a settings file
    /// edited by hand can't add an address the app would refuse.
    var customFeeds: [FeedSource] {
        get {
            (decode(Key.feeds) as [FeedSource]? ?? []).filter { feed in
                FeedSource.isValidID(feed.id) && !feed.isPreset
                    && feed.urls.allSatisfy { (try? FeedSource.check($0.absoluteString).get()) != nil }
            }
        }
        nonmutating set { encode(Array(newValue.prefix(Self.maxFeeds)), Key.feeds) }
    }

    /// The first stop's next departure next to the icon. Off until turned on: it comes from the
    /// timetable unless the menu was open in the last few minutes, since the app only checks the
    /// live feed while you're looking.
    var showsNextDeparture: Bool {
        get { defaults.bool(forKey: Key.menuBarTime) }
        nonmutating set { defaults.set(newValue, forKey: Key.menuBarTime) }
    }

    var launchedBefore: Bool {
        get { defaults.bool(forKey: Key.launchedBefore) }
        nonmutating set { defaults.set(newValue, forKey: Key.launchedBefore) }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

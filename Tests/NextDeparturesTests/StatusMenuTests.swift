import AppKit
import Foundation
import Testing
@testable import NextDepartures
@testable import TransitCore

/// Records what the menu asks the app to do.
@MainActor
final class RecordingActions: StatusMenuActions {
    var calls: [String] = []
    func refreshNow() { calls.append("refresh") }
    func openWindow() { calls.append("window") }
    func openStop(_ id: String) { calls.append("stop:\(id)") }
    func toggleMenuBarTime() { calls.append("time") }
    func toggleOpenAtLogin() { calls.append("login") }
    func showAbout() { calls.append("about") }
}

@MainActor
@Suite("Status menu")
struct StatusMenuTests {
    let folder = TestFolder()
    let actions = RecordingActions()

    private func menu(_ model: TransitModel) -> (NSMenu, StatusMenu) {
        let status = StatusMenu(model: model, actions: actions)
        status.opensAtLogin = { false }
        status.locale = Locale(identifier: "en_US")
        let menu = NSMenu()
        status.build(into: menu)
        return (menu, status)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : ($0.attributedTitle?.string ?? $0.title) }
    }

    @Test func listsEachStopsNextDepartures() async {
        let model = await Gallery.model(in: folder)
        let (menu, _) = menu(model)
        let lines = titles(menu)
        #expect(lines.first == "University Station")
        #expect(lines.contains("Library Mall & Elm St"))
        // Four rides for each stop, with the time first.
        let station = lines.drop { $0 != "University Station" }.dropFirst().prefix(4)
        #expect(station.count == 4)
        #expect(station.allSatisfy { $0.contains(" min\t") || $0.hasPrefix("Now\t") })
        #expect(station.contains { $0.contains("Riverside Line to Union Depot") })
        #expect(lines.contains { $0.hasPrefix("Detour: Campus Loop detoured") })
        #expect(lines.contains { $0.hasPrefix("Live from Northfield Transit, checked") })
        #expect(lines.contains("Refresh Now") && lines.contains("Choose Stops…") && lines.contains("Quit Next Departures"))
    }

    @Test func departuresAreReadableNotGreyedOut() async throws {
        let model = await Gallery.model(in: folder)
        let (menu, _) = menu(model)
        let row = try #require(menu.items.first { $0.attributedTitle?.string.contains("\t") == true })
        #expect(row.isEnabled)
        #expect(row.action == nil)
        #expect(row.image != nil)
        #expect(row.toolTip?.contains("Scheduled") == true)
    }

    @Test func showsCanceledRidesWithoutLosingRunningOnes() async throws {
        let model = await Gallery.model(in: folder)
        let (menu, _) = menu(model)
        #expect(menu.items.contains { $0.attributedTitle?.string.contains("Canceled") == true })
        let lines = titles(menu)
        let bay = lines.drop { $0 != "University Station Bus Bay" }.dropFirst().prefix { $0.contains("\t") }
        #expect(bay.filter { !$0.contains("Canceled") }.count == StatusMenu.perStop)
    }

    @Test func aStopHeaderOpensItsBoard() async throws {
        let model = await Gallery.model(in: folder)
        let (menu, status) = menu(model)
        let header = try #require(menu.items.first { $0.title == "Library Mall & Elm St" })
        _ = header.target?.perform(header.action, with: header)
        #expect(actions.calls == ["stop:b"])
        withExtendedLifetime(status) {}
    }

    @Test func everyActionReachesTheApp() async throws {
        let model = await Gallery.model(in: folder)
        // Items point at the menu builder weakly, so it's kept for the test, as the app keeps it.
        let (menu, status) = menu(model)
        defer { withExtendedLifetime(status) {} }
        for title in ["Refresh Now", "Choose Stops…", "Show Next Departure in Menu Bar", "Open at Login", "About Next Departures"] {
            let item = try #require(menu.items.first { $0.title == title }, "\(title)")
            _ = item.target?.perform(item.action, with: item)
        }
        #expect(actions.calls == ["refresh", "window", "time", "login", "about"])
        #expect(menu.items.first { $0.title == "Refresh Now" }?.keyEquivalent == "r")
    }

    @Test func saysHowToStartWithNoStops() async {
        let preferences = testPreferences()
        let model = TransitModel(library: FeedLibrary(folder: folder.url, fetcher: FakeFetcher()), preferences: preferences)
        let (menu, _) = menu(model)
        let lines = titles(menu)
        #expect(lines.prefix(3) == ["No stops yet", "Pick the stops you use, and their next departures show up here.", "Choose Stops…"])
        #expect(!lines.contains("Refresh Now"))
        #expect(menu.items.first { $0.title == "Show Next Departure in Menu Bar" }?.isEnabled == false)
    }

    @Test func saysWhenItsOffline() async {
        let model = await Gallery.model(in: folder, live: false)
        let (menu, _) = menu(model)
        #expect(titles(menu).contains("You're offline. Showing the timetable."))
        #expect(titles(menu).contains { $0.contains("Scheduled") })
    }

    @Test func saysWhileTheScheduleIsComing() async {
        let preferences = testPreferences()
        preferences.customFeeds = [Gallery.feed]
        preferences.stops = [SavedStop(feedID: Gallery.feed.id, stopIDs: ["LIB"], name: "Library Mall & Elm St")]
        let model = TransitModel(library: FeedLibrary(folder: folder.url, fetcher: FakeFetcher()), preferences: preferences)
        #expect(titles(menu(model).0).contains("Getting the schedule…"))
    }
}

import AppKit
import SwiftUI
import TransitCore

/// The window: your stops down the side, and the one you pick as a departure board, or the
/// stop picker when you're adding one.
struct BoardView: View {
    @Bindable var model: TransitModel
    var refresh: () -> Void = {}
    var locale = Locale.current
    /// The selected stop's highlight. Your accent color in the app; a fixed blue in the screenshots.
    var tint = Color.accentColor
    @State var selection: String?
    @State var adding = false
    /// The picker's state, kept here so the screenshots can show a search.
    @State var feedID = FeedSource.presets[0].id
    @State var query = ""
    @State var route: String?
    @State private var addingFeed = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            Group {
                if adding || model.saved.isEmpty {
                    StopPicker(model: model, feedID: $feedID, query: $query, route: $route, addFeed: { addingFeed = true }) { group in
                        Task {
                            await model.add(group, feedID: feedID, routes: route.map { [$0] } ?? [])
                            selection = model.saved.last?.id
                            adding = false
                        }
                    }
                } else if let stop = model.saved.first(where: { $0.id == selection }) ?? model.saved.first {
                    // Redrawn every 15 seconds so the minutes count down even when nothing new comes in.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        StopBoard(model: model, stop: stop, locale: locale, refresh: refresh)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        // The window draws this anyway; drawing it here too keeps off-screen renders right in dark mode.
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $addingFeed) {
            AddFeedSheet(model: model) { feed in
                if let feed { feedID = feed.id }
                addingFeed = false
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your Stops")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.saved) { stop in
                        let selected = !adding && (selection ?? model.saved.first?.id) == stop.id
                        Button {
                            selection = stop.id
                            adding = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Describe.clean(stop.name, limit: 60)).lineLimit(1)
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                Text(subtitle(stop)).font(.caption).lineLimit(1)
                                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Move Up") { move(stop, by: -1) }.disabled(stop.id == model.saved.first?.id)
                            Button("Move Down") { move(stop, by: 1) }.disabled(stop.id == model.saved.last?.id)
                            Divider()
                            Button("Remove Stop") { Task { await model.remove(stop) } }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            Button {
                adding = true
            } label: {
                Label("Add Stop", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.isFull)
            .help(model.isFull ? "That's as many stops as fit in the menu." : "Find a stop by name or the number on its sign.")
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func move(_ stop: SavedStop, by offset: Int) {
        guard let at = model.saved.firstIndex(of: stop) else { return }
        let to = max(0, min(model.saved.count, at + offset + (offset > 0 ? 1 : 0)))
        model.move(from: [at], to: to)
    }

    private func subtitle(_ stop: SavedStop) -> String {
        let routes = model.routes(for: stop).filter { stop.routes.isEmpty || stop.routes.contains($0.id) }.map(Describe.routeName)
        let feed = model.feed(stop.feedID)?.name ?? ""
        return routes.isEmpty ? feed : routes.prefix(4).joined(separator: ", ") + (routes.count > 4 ? "…" : "")
    }
}

/// One stop's next departures, as big as a station sign, with its alerts below.
struct StopBoard: View {
    @Bindable var model: TransitModel
    let stop: SavedStop
    var locale = Locale.current
    var refresh: () -> Void = {}

    var body: some View {
        let departures = model.departures(for: stop, limit: 8)
        let alerts = model.alerts(for: stop)
        let now = model.now()
        let clock = Describe.clock(model.timeZone(stop.feedID), locale: locale)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Describe.clean(stop.name, limit: 80)).font(.title2.weight(.semibold))
                    Text(codes).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                routeFilter
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help("Check the live feed now")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    // Alerts first: a detour matters more than the fifth bus.
                    ForEach(alerts) { alert in
                        AlertRow(alert: alert, languages: [locale.identifier] + Locale.preferredLanguages)
                    }
                    if model.calls[stop.feedID] == nil {
                        ProgressView(model.problems[stop.feedID] ?? "Getting the schedule…").padding(40)
                    } else if departures.isEmpty {
                        ContentUnavailableView("No departures in the next three hours", systemImage: "moon.zzz", description: Text("Service may have ended for the day, or the routes you picked don't stop here now."))
                            .padding(.top, 30)
                    }
                    ForEach(departures) { departure in
                        DepartureRow(departure: departure, now: now, clock: clock)
                        Divider().padding(.leading, 20)
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var codes: String {
        guard let index = model.indexes[stop.feedID] else { return model.feed(stop.feedID)?.name ?? "" }
        let signs = stop.stopIDs.compactMap { index.stop($0)?.code }.map { "#" + Describe.clean($0, limit: 12) }
        let feed = model.feed(stop.feedID)?.name ?? ""
        return ([feed] + (signs.isEmpty ? [] : ["Stop " + signs.joined(separator: ", ")])).joined(separator: " · ")
    }

    @ViewBuilder private var routeFilter: some View {
        let routes = model.routes(for: stop)
        if routes.count > 1 {
            Menu(stop.routes.isEmpty ? "All Routes" : stop.routes.compactMap { id in routes.first { $0.id == id } }.map(Describe.routeName).joined(separator: ", ")) {
                Button("All Routes") { model.setRoutes([], for: stop) }
                Divider()
                ForEach(routes, id: \.id) { route in
                    Toggle(Describe.routeName(route), isOn: Binding(
                        get: { stop.routes.contains(route.id) },
                        set: { on in model.setRoutes(on ? stop.routes + [route.id] : stop.routes.filter { $0 != route.id }, for: stop) }
                    ))
                }
            }
            .fixedSize()
        }
    }

    private var footer: some View {
        let feed = model.feed(stop.feedID)
        return HStack(spacing: 6) {
            Circle().fill(model.isLive(stop.feedID) ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(status).foregroundStyle(model.problems[stop.feedID] == nil ? Color.secondary : Color.orange)
            Spacer()
            if let attribution = feed?.attribution { Text(attribution).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var status: String {
        if let problem = model.problems[stop.feedID] { return problem }
        guard let feed = model.feed(stop.feedID) else { return "" }
        if feed.tripUpdates == nil { return "Timetable only: this feed has no live updates" }
        return model.isLive(stop.feedID) ? "Live" : "Timetable, until the live feed answers"
    }
}

struct DepartureRow: View {
    let departure: Departure
    let now: Date
    let clock: DateFormatter

    var body: some View {
        let gone = departure.status == .canceled || departure.status == .skipped
        HStack(spacing: 14) {
            RouteBadge(route: departure.route)
            VStack(alignment: .leading, spacing: 2) {
                Text(Describe.clean(departure.headsign ?? Describe.routeName(departure.route), limit: 60))
                    .font(.title3)
                    .strikethrough(gone)
                    .lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(gone ? Color.red : (departure.delay ?? 0) >= 180 ? Color.orange : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Describe.until(departure.time, now: now, clock: clock))
                    .font(.title2.monospacedDigit().weight(departure.status == .live ? .semibold : .regular))
                    .foregroundStyle(departure.status == .live ? Color.primary : Color.secondary)
                    .strikethrough(gone)
                if departure.status == .live {
                    Label("Live", systemImage: "dot.radiowaves.up.forward").font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var detail: String {
        var parts = [Describe.status(departure)]
        if let scheduled = departure.scheduled, departure.status == .live, abs(departure.delay ?? 0) >= 60 {
            parts.append("due \(clock.string(from: scheduled))")
        } else if departure.status == .scheduled, departure.time.timeIntervalSince(now) < 3600 {
            parts.append(clock.string(from: departure.time))
        }
        return parts.joined(separator: " · ")
    }
}

/// A route's name on its own color, as on the agency's maps and signs.
struct RouteBadge: View {
    let route: Route

    var body: some View {
        let background = route.color.flatMap(StatusIcon.color).map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.3)
        let foreground = route.textColor.flatMap(StatusIcon.color).map { Color(nsColor: $0) } ?? Color.primary
        Text(Describe.routeName(route))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(width: 104, height: 28)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AlertRow: View {
    let alert: TransitCore.Alert
    let languages: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Describe.effect(alert.effect)): \(Describe.clean(AlertMatcher.text(alert.header, languages: languages) ?? "", limit: 200))")
                    .font(.callout.weight(.medium))
                if let details = AlertMatcher.text(alert.details, languages: languages), !details.isEmpty {
                    Text(Describe.clean(details, limit: 900)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

// MARK: Picking stops

struct StopPicker: View {
    @Bindable var model: TransitModel
    @Binding var feedID: String
    @Binding var query: String
    @Binding var route: String?
    var addFeed: () -> Void
    var add: (StopGroup) -> Void

    var body: some View {
        let feed = model.feed(feedID) ?? FeedSource.presets[0]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.saved.isEmpty ? "Pick your first stop" : "Add a stop").font(.title2.weight(.semibold))
                HStack {
                    Picker("Feed", selection: $feedID) {
                        ForEach(model.feeds) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: feedID) { route = nil }
                    Button("Add a Feed…", action: addFeed)
                    if !feed.isPreset {
                        Button("Remove Feed") { Task { await model.removeFeed(feed); feedID = FeedSource.presets[0].id } }
                    }
                }
                Text(Describe.clean(feed.area, limit: 140)).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if let index = model.indexes[feed.id] {
                search(index, feed: feed)
            } else {
                download(feed)
            }
        }
    }

    private func download(_ feed: FeedSource) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "tram.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Get \(feed.name)'s schedule").font(.headline)
            Text("It's downloaded once from \(feed.schedule.host ?? "the agency") and checked for updates once a day. Large agencies' schedules are tens of megabytes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if let problem = model.problems[feed.id], !model.preparing.contains(feed.id) {
                Text(problem).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if model.preparing.contains(feed.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Download Schedule") { Task { await model.prepare(feed, asked: true) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func search(_ index: FeedIndex, feed: FeedSource) -> some View {
        let featured = feed.featuredRoutes.compactMap { index.routes[$0] }
        let others = index.routes.values.filter { !feed.featuredRoutes.contains($0.id) }.sorted()
        let results = (query.isEmpty && route == nil) ? [] : StopSearch.find(query, in: index, route: route)
        return VStack(spacing: 0) {
            HStack {
                TextField("Stop name or the number on its sign", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Route", selection: $route) {
                    Text("Any Route").tag(String?.none)
                    if !featured.isEmpty {
                        Divider()
                        ForEach(featured, id: \.id) { Text(routeLabel($0)).tag(Optional($0.id)) }
                    }
                    Divider()
                    ForEach(others, id: \.id) { Text(routeLabel($0)).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if results.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty && route == nil ? "Find a stop" : "No stops match", systemImage: "magnifyingglass")
                } description: {
                    Text(query.isEmpty && route == nil ? "Type part of a stop's name, like a cross street or a station, or pick a route to see all of its stops." : "Try fewer words, or the number on the stop's sign.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { group in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Describe.clean(group.name, limit: 80))
                            Text(detail(group, index: index)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        let added = model.saved.contains { $0.feedID == feed.id && Set($0.stopIDs) == Set(group.stopIDs) }
                        Button(added ? "Added" : "Add") { add(group) }
                            .disabled(added || model.isFull)
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden)
            }
            if let attribution = feed.attribution {
                Divider()
                Text(attribution).font(.caption).foregroundStyle(.tertiary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func routeLabel(_ route: Route) -> String {
        let name = Describe.routeName(route)
        guard let long = route.longName.map({ Describe.clean($0, limit: 40) }), long != name, !long.hasSuffix(name) else { return name }
        return "\(name): \(long)"
    }

    private func detail(_ group: StopGroup, index: FeedIndex) -> String {
        let routes = group.routeIDs.compactMap { index.routes[$0] }.sorted().map(Describe.routeName)
        var parts: [String] = []
        if !routes.isEmpty { parts.append(routes.prefix(6).joined(separator: ", ") + (routes.count > 6 ? "…" : "")) }
        if group.stops.count > 1 { parts.append("both directions") }
        if !group.codes.isEmpty { parts.append("Stop " + group.codes.map { "#" + Describe.clean($0, limit: 12) }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

struct AddFeedSheet: View {
    @Bindable var model: TransitModel
    var done: (FeedSource?) -> Void
    @State private var name = ""
    @State private var schedule = ""
    @State private var tripUpdates = ""
    @State private var alerts = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Feed").font(.title2.weight(.semibold))
            Text("Paste the addresses an agency publishes. The Mobility Database (mobilitydatabase.org) lists over a thousand. Next Departures only ever connects to the addresses you add here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Like the agency's name"))
                TextField("Schedule (GTFS zip)", text: $schedule, prompt: Text("https://…/gtfs.zip"))
                TextField("Live trip updates", text: $tripUpdates, prompt: Text("Optional: https://…/TripUpdates.pb"))
                TextField("Service alerts", text: $alerts, prompt: Text("Optional: https://…/Alerts.pb"))
            }
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Add Feed") {
                    switch model.addFeed(name: name, schedule: schedule, tripUpdates: tripUpdates, alerts: alerts) {
                    case .success(let feed): done(feed)
                    case .failure(let failure): problem = Self.describe(failure)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    static func describe(_ problem: TransitModel.FeedProblem) -> String {
        func url(_ field: String, _ problem: FeedSource.URLProblem) -> String {
            switch problem {
            case .empty: return "Paste the \(field) address."
            case .notHTTPS: return "The \(field) address must start with https://."
            case .noHost: return "The \(field) address has no website in it."
            case .hasPassword: return "The \(field) address has a name and password in it, which the app never sends."
            case .tooLong: return "The \(field) address is too long."
            case .local: return "The \(field) address is on your own network. Feeds have to be on the internet."
            }
        }
        switch problem {
        case .name: return "Give the feed a name."
        case .tooMany: return "That's as many feeds as the app keeps. Remove one first."
        case .schedule(let problem): return url("schedule", problem)
        case .tripUpdates(let problem): return url("trip updates", problem)
        case .alerts(let problem): return url("alerts", problem)
        }
    }
}

/// Keeps the window across openings and tells the app when it's on screen, so the live feed is
/// only checked while you can see it.
@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: (_ selection: String?) -> BoardView
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?

    init(makeView: @escaping (_ selection: String?) -> BoardView) {
        self.makeView = makeView
    }

    /// True while the window is closing, when AppKit still reports it as on screen.
    private var closing = false

    var isVisible: Bool {
        guard let window, !closing else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Shows the window, starting on `stop` if one's given.
    func show(selecting stop: String? = nil) {
        if let stop, let window {
            window.contentViewController = NSHostingController(rootView: makeView(stop))
        }
        let window = self.window ?? makeWindow(stop)
        self.window = window
        closing = false
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        onShow?()
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        onHide?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isVisible { onShow?() } else { onHide?() }
    }

    private func makeWindow(_ stop: String?) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: makeView(stop)))
        window.title = "Next Departures"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 600))
        if !window.setFrameUsingName("BoardWindow") {
            window.center()
        }
        window.setFrameAutosaveName("BoardWindow")
        return window
    }
}

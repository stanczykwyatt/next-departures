import AppKit
import ServiceManagement
import TransitCore

/// What the menu's items do. The app delegate does them; tests record them.
@MainActor
protocol StatusMenuActions: AnyObject {
    func refreshNow()
    func openWindow()
    func openStop(_ id: String)
    func toggleMenuBarTime()
    func toggleOpenAtLogin()
    func showAbout()
}

/// Builds the menu bar menu fresh each time it opens, and again each time new departures come in
/// while it's open.
@MainActor
final class StatusMenu: NSObject {
    private let model: TransitModel
    private weak var actions: StatusMenuActions?
    var opensAtLogin: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var locale = Locale.current

    static let perStop = 4

    init(model: TransitModel, actions: StatusMenuActions) {
        self.model = model
        self.actions = actions
    }

    func build(into menu: NSMenu) {
        menu.removeAllItems()
        // Departures are there to read, not to click, so they're shown in full color.
        menu.autoenablesItems = false
        let now = model.now()

        if model.saved.isEmpty {
            menu.addItem(disabled("No stops yet"))
            menu.addItem(disabled("Pick the stops you use, and their next departures show up here.", small: true))
            menu.addItem(item("Choose Stops…", #selector(openWindow), key: ","))
        }
        for stop in model.saved {
            addStop(stop, to: menu, now: now)
            menu.addItem(.separator())
        }

        if !model.saved.isEmpty {
            for line in footer(now: now) { menu.addItem(disabled(line.text, small: true, warning: line.warning)) }
            menu.addItem(item("Refresh Now", #selector(refreshNow), key: "r"))
            menu.addItem(item("Choose Stops…", #selector(openWindow), key: ","))
        }

        menu.addItem(.separator())
        let time = item("Show Next Departure in Menu Bar", #selector(toggleMenuBarTime))
        time.state = model.preferences.showsNextDeparture ? .on : .off
        time.toolTip = "Shows when your first stop's next ride leaves. It's live while you have the menu or window open, and from the timetable otherwise."
        time.isEnabled = !model.saved.isEmpty
        menu.addItem(time)
        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = opensAtLogin() ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("About Next Departures", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Quit Next Departures", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Parts

    private func addStop(_ stop: SavedStop, to menu: NSMenu, now: Date) {
        let header = item(Describe.clean(stop.name, limit: 60), #selector(openStop(_:)))
        header.representedObject = stop.id
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        header.toolTip = "Open this stop's board"
        menu.addItem(header)

        guard model.indexes[stop.feedID] != nil, model.calls[stop.feedID] != nil else {
            let waiting = model.preparing.contains(stop.feedID) ? "Getting the schedule…" : model.problems[stop.feedID] ?? "Getting the schedule…"
            menu.addItem(disabled(waiting, small: true, warning: model.problems[stop.feedID] != nil && !model.preparing.contains(stop.feedID)))
            return
        }
        // Canceled and skipped rides are shown, but don't take the place of ones that are running.
        var departures: [Departure] = []
        var running = 0
        for departure in model.departures(for: stop, limit: Self.perStop + 3) where running < Self.perStop {
            departures.append(departure)
            if departure.status != .canceled && departure.status != .skipped { running += 1 }
        }
        if departures.isEmpty {
            menu.addItem(disabled("No departures in the next three hours", small: true))
        }
        let clock = Describe.clock(model.timeZone(stop.feedID), locale: locale)
        for departure in departures {
            menu.addItem(row(departure, now: now, clock: clock))
        }
        for alert in model.alerts(for: stop).prefix(2) {
            menu.addItem(alertItem(alert))
        }
    }

    /// "4 min   Green Line to Union Depot   Live", in columns.
    func row(_ departure: Departure, now: Date, clock: DateFormatter) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 68)]
        let gone = departure.status == .canceled || departure.status == .skipped
        let live = departure.status == .live
        var timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: live ? .semibold : .regular),
            .foregroundColor: live ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        if gone { timeAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let text = NSMutableAttributedString(string: Describe.until(departure.time, now: now, clock: clock), attributes: timeAttributes)
        var lineAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        if gone { lineAttributes[.foregroundColor] = NSColor.secondaryLabelColor }
        text.append(NSAttributedString(string: "\t" + Describe.clean(Describe.line(departure), limit: 48), attributes: lineAttributes))
        let status = Describe.status(departure)
        text.append(NSAttributedString(string: "  " + status, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: departure.status == .canceled || departure.status == .skipped ? NSColor.systemRed
                : (departure.delay ?? 0) >= 180 ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        item.attributedTitle = text
        item.image = StatusIcon.routeDot(departure.route.color)
        item.toolTip = tip(departure, clock: clock)
        return item
    }

    private func tip(_ departure: Departure, clock: DateFormatter) -> String {
        var parts = [Describe.line(departure)]
        if let scheduled = departure.scheduled { parts.append("Scheduled \(clock.string(from: scheduled))") }
        if let predicted = departure.predicted, departure.status == .live { parts.append("Expected \(clock.string(from: predicted))") }
        return parts.joined(separator: " · ")
    }

    private func alertItem(_ alert: TransitCore.Alert) -> NSMenuItem {
        let headline = Describe.clean(AlertMatcher.text(alert.header, languages: [locale.identifier] + Locale.preferredLanguages) ?? "", limit: 120)
        let title = "\(Describe.effect(alert.effect)): \(headline)"
        let item = disabled(title, small: true, warning: true)
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Alert")
        if let details = AlertMatcher.text(alert.details, languages: [locale.identifier] + Locale.preferredLanguages), !details.isEmpty {
            let submenu = NSMenu()
            submenu.addItem(disabled(Describe.clean(details, limit: 900), small: true))
            item.submenu = submenu
            item.isEnabled = true
        }
        return item
    }

    /// When the board was last checked, and from where, or why it couldn't be.
    func footer(now: Date) -> [(text: String, warning: Bool)] {
        var lines: [(String, Bool)] = []
        for feed in model.activeFeeds {
            if let problem = model.problems[feed.id] {
                lines.append((problem + (model.indexes[feed.id] != nil ? " Showing the timetable." : ""), true))
            } else if let live = model.live[feed.id] {
                let ago = Int(now.timeIntervalSince(live.fetched))
                let when = ago < 5 ? "just now" : ago < 60 ? "\(ago) s ago" : "\(ago / 60) min ago"
                let kind = model.isLive(feed.id) ? "Live" : live.hasTripUpdates ? "The live feed is behind, so this is the timetable" : "Timetable and alerts"
                lines.append(("\(kind) from \(feed.name), checked \(when)", false))
            } else if feed.tripUpdates == nil {
                lines.append(("Timetable from \(feed.name). It has no live feed.", false))
            }
        }
        return lines
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String, small: Bool = false, warning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small || warning {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            if title.count > 50 { item.view = wrapping(item.attributedTitle!) }
        }
        return item
    }

    /// Long notes in the menu wrap instead of making it as wide as the screen.
    private func wrapping(_ text: NSAttributedString) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = 300
        label.frame.size = label.fittingSize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: label.frame.height + 6))
        label.frame.origin = NSPoint(x: 14, y: 3)
        view.addSubview(label)
        return view
    }

    // MARK: Actions

    @objc private func refreshNow() { actions?.refreshNow() }
    @objc private func openWindow() { actions?.openWindow() }
    @objc private func openStop(_ sender: NSMenuItem) { (sender.representedObject as? String).map { actions?.openStop($0) } }
    @objc private func toggleMenuBarTime() { actions?.toggleMenuBarTime() }
    @objc private func toggleOpenAtLogin() { actions?.toggleOpenAtLogin() }
    @objc private func showAbout() { actions?.showAbout() }
}

extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}

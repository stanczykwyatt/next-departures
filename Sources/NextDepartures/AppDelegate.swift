import AppKit
import ServiceManagement
import TransitCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, StatusMenuActions {
    private let preferences = Preferences()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private lazy var model = TransitModel(library: FeedLibrary(folder: Self.dataFolder, fetcher: FeedFetcher()), preferences: preferences)
    private lazy var statusMenu = StatusMenu(model: model, actions: self)
    private lazy var window = BoardWindowController { [unowned self] selection in
        BoardView(model: model, refresh: { [unowned self] in refreshNow() }, selection: selection)
    }
    private lazy var poller = Poller(model: model) { [weak self] in self?.updated() }
    /// Keeps the menu bar's countdown current. It only reads what's already here, never the network.
    private var clock: Timer?
    private var menuOpen = false

    /// Schedules live in the app's sandbox container. Live updates are never written down.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Feeds", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        window.onShow = { [weak self] in self?.lookingChanged() }
        window.onHide = { [weak self] in self?.lookingChanged() }

        Task {
            // Only what's already on disk: nothing is fetched until you open the menu or the window.
            await model.load()
            updateStatusItem()
        }
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock

        // The first time, open at login like most menu bar utilities, and show the window to pick a
        // stop. Turn off login in the menu.
        if !preferences.launchedBefore {
            preferences.launchedBefore = true
            try? SMAppService.mainApp.register()
            openWindow()
        }
    }

    private var looking: Bool { menuOpen || window.isVisible }

    private func lookingChanged() {
        poller.setActive(looking)
    }

    private func updated() {
        updateStatusItem()
        if menuOpen { statusMenu.build(into: menu) }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let alerts = model.saved.contains { !model.alerts(for: $0).isEmpty }
        button.image = StatusIcon.image(alert: alerts)
        button.imagePosition = .imageLeading
        var tip = "Next Departures"
        if let first = model.saved.first, let next = model.nextDeparture(for: first) {
            let clock = Describe.clock(model.timeZone(first.feedID))
            let when = Describe.until(next.time, now: model.now(), clock: clock)
            tip += "\n\(Describe.clean(first.name, limit: 50)): \(Describe.line(next)), \(when)"
            button.title = preferences.showsNextDeparture ? " " + when : ""
        } else {
            button.title = ""
        }
        if alerts { tip += "\nThere's a service alert for one of your stops." }
        button.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu.build(into: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        lookingChanged()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        lookingChanged()
    }

    // MARK: StatusMenuActions

    func refreshNow() {
        poller.refresh(force: true)
    }

    func openWindow() {
        window.show()
    }

    func openStop(_ id: String) {
        window.show(selecting: id)
    }

    func toggleMenuBarTime() {
        preferences.showsNextDeparture.toggle()
        updateStatusItem()
    }

    func toggleOpenAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    func showAbout() {
        NSApp.activate()
        var credits = "Free and open source. Connects only to the transit feeds you use, with no analytics.\ngithub.com/stanczykwyatt/next-departures"
        for feed in model.activeFeeds.isEmpty ? FeedSource.presets : model.activeFeeds {
            if let attribution = feed.attribution { credits += "\n\n" + attribution }
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: credits,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}

/// Checks the live feed every 30 seconds while you're looking at the menu or the window, waits
/// longer after errors, and stops the moment you look away.
@MainActor
final class Poller {
    private let model: TransitModel
    private let onUpdate: () -> Void
    private var timer: Timer?
    private var running: Task<Void, Never>?
    private(set) var isActive = false

    init(model: TransitModel, onUpdate: @escaping () -> Void) {
        self.model = model
        self.onUpdate = onUpdate
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            refresh(force: false)
        } else {
            timer?.invalidate()
            timer = nil
            // Stops what's being fetched. A schedule download already under way finishes on its own.
            running?.cancel()
        }
    }

    /// Checks now, if it's been long enough, then waits for the next check.
    func refresh(force: Bool) {
        guard isActive || force else { return }
        // A check already under way schedules the next one when it's done.
        guard running == nil else { return }
        timer?.invalidate()
        timer = nil
        running = Task {
            await model.refresh(force: force)
            let cancelled = Task.isCancelled
            running = nil
            onUpdate()
            // Looked away and back while it was being stopped: check again now, not in 30 seconds.
            if cancelled, isActive { refresh(force: false) } else { scheduleNext() }
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = nil
        guard isActive else { return }
        let delay = model.activeFeeds.map(model.nextDelay).min() ?? Backoff.interval
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        timer.tolerance = 2
        // Common mode, so it keeps firing while the menu is open and tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

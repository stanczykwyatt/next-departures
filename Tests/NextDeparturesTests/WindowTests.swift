import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NextDepartures
@testable import TransitCore

/// Renders the window into a bitmap from a window that's never shown, so nothing appears on screen
/// or takes focus. Set SCREENSHOT_DIR to also save the renders as the README screenshots:
///
///   SCREENSHOT_DIR=docs swift test --filter "Window"
@MainActor
@Suite("Window")
struct WindowTests {
    let folder = TestFolder()
    static let size = NSSize(width: 940, height: 600)

    private func view(_ model: TransitModel, selection: String? = "c", adding: Bool = false, query: String = "", feedID: String = Gallery.feed.id) -> BoardView {
        BoardView(model: model, locale: Locale(identifier: "en_US"), tint: Color(red: 0.24, green: 0.47, blue: 0.86), selection: selection, adding: adding, feedID: feedID, query: query)
    }

    @Test func rendersTheBoard() async throws {
        let model = await Gallery.model(in: folder)
        let image = render(view(model), name: "screenshot-light", dark: false)
        #expect(image.pixelsWide >= Int(Self.size.width))
        #expect(colors(in: image) > 30)
    }

    @Test func rendersInDarkMode() async throws {
        let model = await Gallery.model(in: folder)
        #expect(colors(in: render(view(model), name: "screenshot-dark", dark: true)) > 20)
    }

    @Test func rendersAStation() async throws {
        let model = await Gallery.model(in: folder)
        #expect(colors(in: render(view(model, selection: "a"), name: "screenshot-station", dark: false)) > 20)
    }

    @Test func rendersThePicker() async throws {
        let model = await Gallery.model(in: folder)
        #expect(colors(in: render(view(model, adding: true, query: "university"), name: "screenshot-picker", dark: false)) > 20)
    }

    @Test func rendersTheOtherStates() async throws {
        let offline = await Gallery.model(in: folder, live: false)
        #expect(colors(in: render(view(offline), name: nil, dark: true)) > 4)
        // The first run, with nothing picked: the picker, asking to download Metro Transit's schedule.
        let empty = TransitModel(library: FeedLibrary(folder: folder.url, fetcher: FakeFetcher()), preferences: testPreferences())
        #expect(colors(in: render(view(empty, selection: nil, feedID: "metro-transit"), name: "screenshot-start", dark: false, size: NSSize(width: 820, height: 480))) > 4)
        #expect(colors(in: render(AddFeedSheet(model: empty) { _ in }, name: nil, dark: false, size: NSSize(width: 520, height: 330))) > 4)
    }

    @Test func everySymbolExists() {
        for symbol in ["plus", "arrow.clockwise", "moon.zzz", "dot.radiowaves.up.forward", "exclamationmark.triangle.fill", "tram.fill", "magnifyingglass"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing symbol \(symbol)")
        }
    }

    @Test func theMenuBarIconIsATemplate() {
        for alert in [false, true] {
            let image = StatusIcon.image(alert: alert)
            #expect(image.isTemplate && image.size == NSSize(width: 18, height: 18))
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
        #expect(StatusIcon.color("0E8A6E") != nil)
        #expect(StatusIcon.color("nope!!") == nil)
        #expect(StatusIcon.routeDot(nil).size == NSSize(width: 10, height: 10))
    }

    @Test func describesFeedProblemsPlainly() {
        #expect(AddFeedSheet.describe(.schedule(.notHTTPS)) == "The schedule address must start with https://.")
        #expect(AddFeedSheet.describe(.alerts(.local)).contains("your own network"))
        #expect(AddFeedSheet.describe(.tooMany).contains("Remove one"))
    }

    // MARK: Rendering

    private func render(_ view: some View, name: String?, dark: Bool, size: NSSize = WindowTests.size) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Never ordered front: it only gives the view a backing to draw into.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: image)
        if let name, let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            try? image.representation(using: .png, properties: [:])?.write(to: url)
        }
        return image
    }

    /// Distinct colors in a coarse grid: a blank or broken render has only a few.
    private func colors(in image: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: image.pixelsWide, by: 7) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 7) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = UInt32(color.redComponent * 31), g = UInt32(color.greenComponent * 31), b = UInt32(color.blueComponent * 31)
                seen.insert(r << 10 | g << 5 | b)
            }
        }
        return seen.count
    }
}

/// The app's entitlements, checked against what the code expects.
@Suite("Entitlements")
struct EntitlementTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func onlyTheSandboxAndOutgoingConnections() throws {
        let file = Self.root.appendingPathComponent("Resources/NextDepartures.entitlements")
        let entitlements = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(Set(entitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.network.client"])
        #expect(entitlements.values.allSatisfy { $0 as? Bool == true })
    }

    @Test func theInfoPlistDoesNotLoosenTransportSecurity() throws {
        let info = try #require(NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist")) as? [String: Any])
        #expect(info["NSAppTransportSecurity"] == nil)
        #expect(info["CFBundleIdentifier"] as? String == "com.stanczykwyatt.NextDepartures")
        #expect(info["LSUIElement"] as? Bool == true)
    }
}

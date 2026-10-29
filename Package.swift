// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NextDepartures",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NextDepartures", targets: ["NextDepartures"]),
        .executable(name: "next-departures", targets: ["NextDeparturesCLI"]),
    ],
    targets: [
        // Reading GTFS schedules and GTFS-realtime feeds, with its own zip, CSV and protocol buffer
        // readers, and working out the next departures, with nothing tied to the app's windows, so
        // it can be tested with made-up feeds and no network.
        .target(name: "TransitCore"),
        .executableTarget(name: "NextDepartures", dependencies: ["TransitCore"]),
        .executableTarget(name: "NextDeparturesCLI", dependencies: ["TransitCore"]),
        .testTarget(name: "TransitCoreTests", dependencies: ["TransitCore"]),
        // The app's glue, tested with a made-up agency and windows that are never shown.
        .testTarget(name: "NextDeparturesTests", dependencies: ["NextDepartures", "TransitCore"]),
    ]
)

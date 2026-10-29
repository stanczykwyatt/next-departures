import Foundation
import Testing
@testable import TransitCore

@Suite("GTFS-realtime")
struct RealtimeTests {
    @Test func readsTheHeader() throws {
        let feed = try RealtimeFeed.decode(FeedBuilder.feed(timestamp: Lakeside.now))
        #expect(feed.version == "2.0")
        #expect(feed.timestamp == Lakeside.now)
        #expect(!feed.isDifferential)
        #expect(feed.tripUpdates.isEmpty && feed.alerts.isEmpty)
    }

    /// The exact bytes a real feed sent with no trips running yet: a header and nothing else.
    @Test func readsAnEmptyFeedFromAnAgency() throws {
        let feed = try RealtimeFeed.decode(Data([0x0A, 0x0D, 0x0A, 0x03, 0x32, 0x2E, 0x30, 0x10, 0x00, 0x18, 0xA1, 0xCF, 0x8C, 0xD7, 0x06]))
        #expect(feed.version == "2.0")
        #expect(feed.timestamp == Date(timeIntervalSince1970: 1_793_271_713))
        #expect(feed.tripUpdates.isEmpty)
    }

    @Test func readsTripUpdates() throws {
        let data = FeedBuilder.feed(timestamp: Lakeside.now, updates: [
            .init(tripID: "B1", routeID: "BLUE", startDate: "20261029", stops: [
                .init(sequence: 1, stopID: "S1A", arrival: (delay: 120, time: nil), departure: (delay: nil, time: Lakeside.now)),
                .init(sequence: 2, stopID: "P3", relationship: 1),
            ], delay: -30),
            .init(tripID: "B2", relationship: 3),
        ])
        let feed = try RealtimeFeed.decode(data)
        #expect(feed.tripUpdates.count == 2)
        let first = feed.tripUpdates[0]
        #expect(first.entityID == "tu-0")
        #expect(first.trip == TripDescriptor(tripID: "B1", routeID: "BLUE", startDate: "20261029"))
        #expect(first.delay == -30)
        #expect(first.stopTimes[0].arrival == .init(delay: 120))
        #expect(first.stopTimes[0].departure == .init(time: Lakeside.now))
        #expect(first.stopTimes[1].relationship == .skipped)
        #expect(feed.tripUpdates[1].trip.relationship == .canceled)
    }

    @Test func readsAlerts() throws {
        let start = Lakeside.now.addingTimeInterval(-3600), end = Lakeside.now.addingTimeInterval(3600)
        let data = FeedBuilder.feed(timestamp: Lakeside.now, alerts: [
            .init(header: [("Elevator out", "en"), ("Ascensor fuera", "es")], details: [("Use the ramp", nil)], effect: 11, severity: 4,
                  periods: [(start, end)], entities: [(agency: "LT", route: nil, stop: "S1", trip: nil, routeType: nil), (nil, "LOOP", nil, "L1", nil)]),
        ])
        let alert = try #require(try RealtimeFeed.decode(data).alerts.first)
        #expect(alert.id == "alert-0")
        #expect(alert.effect == .accessibilityIssue)
        #expect(alert.severity == .severe)
        #expect(alert.header == ["en": "Elevator out", "es": "Ascensor fuera"])
        #expect(alert.details == ["": "Use the ramp"])
        #expect(alert.periods == [.init(start: start, end: end)])
        #expect(alert.entities == [.init(agencyID: "LT", stopID: "S1"), .init(routeID: "LOOP", tripID: "L1")])
        #expect(alert.isActive(at: Lakeside.now))
        #expect(!alert.isActive(at: end))
        #expect(!alert.isActive(at: start.addingTimeInterval(-1)))
    }

    @Test func fieldsWithTheWrongWireTypeAreSkipped() throws {
        let data = FeedBuilder.feed(timestamp: Lakeside.now) { writer in
            writer.message(2) { entity in
                entity.int(1, 5) // id should be a string
                entity.message(3) { trip in
                    trip.string(5, "not a number") // delay should be a varint
                    trip.message(1) { $0.string(1, "B1") }
                    trip.fixed64(99, 1) // a field from a future version
                }
            }
        }
        let feed = try RealtimeFeed.decode(data)
        #expect(feed.tripUpdates.first?.trip.tripID == "B1")
        #expect(feed.tripUpdates.first?.delay == nil)
        #expect(feed.tripUpdates.first?.entityID == "")
    }

    @Test func deletedEntitiesAndVehiclePositionsAreLeftOut() throws {
        let data = FeedBuilder.feed(timestamp: Lakeside.now) { writer in
            writer.message(2) { entity in
                entity.string(1, "gone")
                entity.int(2, 1)
                entity.message(3) { $0.message(1) { $0.string(1, "B1") } }
            }
            writer.message(2) { entity in
                entity.string(1, "bus")
                entity.message(4) { $0.message(1) { $0.string(1, "L1") } }
            }
        }
        let feed = try RealtimeFeed.decode(data)
        #expect(feed.tripUpdates.isEmpty && feed.alerts.isEmpty)
    }

    @Test func implausibleTimesAreTreatedAsMissing() throws {
        #expect(RealtimeFeed.date(UInt64(0)) == nil)
        #expect(RealtimeFeed.date(UInt64(UInt32.max) * 4) == nil)
        #expect(RealtimeFeed.date(Int64(-5)) == nil)
        #expect(RealtimeFeed.date(UInt64(1_793_271_713)) != nil)
        let data = FeedBuilder.feed(timestamp: Date(timeIntervalSince1970: 12))
        #expect(try RealtimeFeed.decode(data).timestamp == nil)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let data = FeedBuilder.feed(timestamp: Lakeside.now,
            updates: [.init(tripID: "B1", relationship: 42, stops: [.init(sequence: 1, relationship: 9)])],
            alerts: [.init(effect: 77, severity: 9)])
        let feed = try RealtimeFeed.decode(data)
        #expect(feed.tripUpdates[0].trip.relationship == .scheduled)
        #expect(feed.tripUpdates[0].stopTimes[0].relationship == .scheduled)
        #expect(feed.alerts[0].effect == .unknown)
        #expect(feed.alerts[0].severity == .unknown)
    }

    @Test func readsTheVehicleLabelAndDifferentialFlag() throws {
        var writer = ProtoWriter()
        writer.message(1) { header in
            header.string(1, "2.0")
            header.int(2, 1)
        }
        writer.message(2) { entity in
            entity.string(1, "x")
            entity.message(3) { trip in
                trip.message(1) { $0.string(1, "B1") }
                trip.message(3) { vehicle in
                    vehicle.string(1, "1407")
                    vehicle.string(2, "Car 14")
                }
            }
        }
        let feed = try RealtimeFeed.decode(writer.data)
        #expect(feed.isDifferential)
        #expect(feed.tripUpdates[0].vehicleLabel == "Car 14")
    }

    @Test func aTripWithThousandsOfStopsIsCut() throws {
        let stops = (0..<(TripUpdate.maxStops + 50)).map { FeedBuilder.StopTime(sequence: $0) }
        let feed = try RealtimeFeed.decode(FeedBuilder.feed(timestamp: nil, updates: [.init(tripID: "B1", stops: stops)]))
        #expect(feed.tripUpdates[0].stopTimes.count == TripUpdate.maxStops)
    }
}

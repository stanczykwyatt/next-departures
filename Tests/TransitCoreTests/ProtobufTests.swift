import Foundation
import Testing
@testable import TransitCore

@Suite("Protocol buffers")
struct ProtobufTests {
    private func varint(_ bytes: [UInt8]) throws -> UInt64 {
        try ProtoReader.read(Data(bytes)) { try $0.varint() }
    }

    @Test func readsVarints() throws {
        #expect(try varint([0x00]) == 0)
        #expect(try varint([0x01]) == 1)
        #expect(try varint([0x96, 0x01]) == 150)
        #expect(try varint([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]) == 0xFFFF_FFFF)
        #expect(try varint([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]) == UInt64.max)
    }

    @Test func refusesBrokenVarints() {
        #expect(throws: ProtoReader.Failure.truncated) { try varint([0x96]) }
        #expect(throws: ProtoReader.Failure.truncated) { try varint([]) }
        #expect(throws: ProtoReader.Failure.overlongVarint) { try varint([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02]) }
        #expect(throws: ProtoReader.Failure.overlongVarint) { try varint(Array(repeating: 0x80, count: 11) + [0x00]) }
    }

    @Test func negativeNumbersComeAsTenBytes() throws {
        var writer = ProtoWriter()
        writer.int(1, -90)
        #expect(writer.data.count == 11)
        let value = try ProtoReader.read(writer.data) { reader -> Int32 in
            _ = try reader.next()
            return try reader.int32()
        }
        #expect(value == -90)
    }

    @Test func readsEveryWireTypeAndSkipsWhatIsNotAsked() throws {
        var writer = ProtoWriter()
        writer.fixed32(7, 0xDEAD_BEEF)
        writer.fixed64(8, 0x0102_0304_0506_0708)
        writer.string(9, "skip me")
        writer.int(10, 5)
        writer.string(1, "kept")
        let kept = try ProtoReader.read(writer.data) { reader -> String? in
            var found: String?
            while let field = try reader.next() {
                if field.number == 1 { found = try reader.string() } else { try reader.skip(field) }
            }
            return found
        }
        #expect(kept == "kept")

        let numbers = try ProtoReader.read(writer.data) { reader -> (UInt32, UInt64) in
            _ = try reader.next()
            let a = try reader.fixed32()
            _ = try reader.next()
            return (a, try reader.fixed64())
        }
        #expect(numbers.0 == 0xDEAD_BEEF && numbers.1 == 0x0102_0304_0506_0708)
    }

    @Test func refusesGroupsAndFieldZero() {
        #expect(throws: ProtoReader.Failure.unsupportedWireType(3)) {
            try ProtoReader.read(Data([0x0B])) { try $0.next() }
        }
        #expect(throws: ProtoReader.Failure.unsupportedWireType(7)) {
            try ProtoReader.read(Data([0x0F])) { try $0.next() }
        }
        #expect(throws: ProtoReader.Failure.badFieldNumber) {
            try ProtoReader.read(Data([0x02, 0x00])) { try $0.next() }
        }
    }

    @Test func lengthsCanNotRunPastTheEnd() {
        // A string claiming 100 bytes with 3 left.
        #expect(throws: ProtoReader.Failure.truncated) {
            try ProtoReader.read(Data([0x0A, 0x64, 0x61, 0x62, 0x63])) { reader in
                _ = try reader.next()
                return try reader.string()
            }
        }
        // A length near 2^64 can't wrap around.
        #expect(throws: ProtoReader.Failure.truncated) {
            try ProtoReader.read(Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00])) { reader in
                _ = try reader.next()
                return try reader.bytesField()
            }
        }
        #expect(throws: ProtoReader.Failure.truncated) {
            try ProtoReader.read(Data([0x0D, 0x01, 0x02])) { reader in
                _ = try reader.next()
                return try reader.fixed32()
            }
        }
    }

    @Test func anEmbeddedMessageIsReadOnlyToItsEnd() throws {
        var writer = ProtoWriter()
        writer.message(1) { $0.string(1, "inner") }
        writer.string(2, "outer")
        let result = try ProtoReader.read(writer.data) { reader -> [String] in
            var seen: [String] = []
            while let field = try reader.next() {
                if field.number == 1 {
                    try reader.message { inner in
                        while let field = try inner.next() {
                            if field.number == 1 { seen.append(try inner.string()) } else { try inner.skip(field) }
                        }
                        // The outer field never leaks in.
                        #expect(inner.isAtEnd)
                    }
                } else {
                    seen.append(try reader.string())
                }
            }
            return seen
        }
        #expect(result == ["inner", "outer"])
    }

    @Test func nestingIsLimited() {
        var data = Data()
        for _ in 0..<40 {
            var writer = ProtoWriter()
            writer.bytes(1, data)
            data = writer.data
        }
        func dive(_ reader: inout ProtoReader) throws {
            while let field = try reader.next() {
                if field.wireType == .lengthDelimited { try reader.message(dive) } else { try reader.skip(field) }
            }
        }
        #expect(throws: ProtoReader.Failure.tooDeep) { try ProtoReader.read(data) { try dive(&$0) } }
    }

    @Test func aStringThatIsNotUTF8KeepsTheRest() throws {
        let text = try ProtoReader.read(Data([0x0A, 0x02, 0xC3, 0x28])) { reader in
            _ = try reader.next()
            return try reader.string()
        }
        #expect(text == "\u{FFFD}(")
    }

    @Test func emptyDataIsAnEmptyMessage() throws {
        let feed = try RealtimeFeed.decode(Data())
        #expect(feed == RealtimeFeed())
    }

    // MARK: Fuzzing

    /// Random bytes, and real feeds with bytes changed, cut short or spliced, must only ever be read
    /// or refused. Never a crash, a hang, or an out-of-bounds read.
    @Test func randomBytesNeverCrash() {
        var random = SeededRandom(state: 1)
        for round in 0..<4000 {
            let count = Int.random(in: 0...(round % 10 == 0 ? 2000 : 80), using: &random)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
            _ = try? RealtimeFeed.decode(data)
        }
    }

    @Test func damagedFeedsNeverCrash() throws {
        let valid = FeedBuilder.feed(
            timestamp: Lakeside.now,
            updates: [
                .init(tripID: "B1", routeID: "BLUE", startDate: "20261029", stops: [
                    .init(sequence: 1, stopID: "S1A", arrival: (60, nil), departure: (nil, Lakeside.now)),
                    .init(sequence: 2, stopID: "P3", relationship: 1),
                ], delay: 30),
            ],
            alerts: [.init(details: [("Use Elm St", "en"), ("Usa Elm St", "es")], severity: 3, periods: [(Lakeside.now, nil)], entities: [(nil, "BLUE", "S1", "B1", 0)])]
        )
        #expect(try RealtimeFeed.decode(valid).tripUpdates.count == 1)
        var random = SeededRandom(state: 2)
        for length in 0..<valid.count {
            _ = try? RealtimeFeed.decode(valid.prefix(length))
        }
        for _ in 0..<6000 {
            var data = valid
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                let at = Int.random(in: 0..<data.count, using: &random)
                switch Int.random(in: 0...3, using: &random) {
                case 0: data[at] = UInt8.random(in: 0...255, using: &random)
                case 1: data[at] ^= 1 << UInt8.random(in: 0...7, using: &random)
                case 2: data.insert(UInt8.random(in: 0...255, using: &random), at: at)
                default: data.remove(at: at)
                }
                if data.isEmpty { break }
            }
            _ = try? RealtimeFeed.decode(data)
        }
        // Spliced halves of two feeds.
        for cut in stride(from: 0, to: valid.count, by: 7) {
            _ = try? RealtimeFeed.decode(valid.prefix(cut) + valid.suffix(from: valid.count - cut))
        }
    }

    @Test func manyEmptyStopUpdatesAreRefused() {
        // Thousands of two-byte stop updates in each of many trips: tiny on the wire, huge in memory.
        let stops = (0..<TripUpdate.maxStops).map { _ in FeedBuilder.StopTime() }
        let updates = (0..<(RealtimeFeed.maxStopUpdates / TripUpdate.maxStops + 2)).map { FeedBuilder.Update(tripID: "T\($0)", stops: stops) }
        #expect(throws: RealtimeFeed.Failure.tooManyEntities) { try RealtimeFeed.decode(FeedBuilder.feed(timestamp: nil, updates: updates)) }
    }

    @Test func manyTinyEntitiesAreRefused() {
        // Each entity is two bytes, so a few hundred kilobytes would otherwise make a huge array.
        let data = Data(repeating: 0, count: (RealtimeFeed.maxEntities + 1) * 2).enumerated().map { $0.offset % 2 == 0 ? UInt8(0x12) : 0 }
        #expect(throws: RealtimeFeed.Failure.tooManyEntities) { try RealtimeFeed.decode(Data(data)) }
    }
}

import Foundation

/// A reader for the protocol buffer wire format, just enough of it for GTFS-realtime.
///
/// It reads fields one at a time and never trusts a length it's given: every length is checked
/// against what's left, nesting is limited, and anything it doesn't understand is an error rather
/// than a guess. Fields it isn't asked about are skipped, so newer feeds with more fields still read.
public struct ProtoReader {
    public enum Failure: Error, Equatable {
        /// The data ended partway through a field.
        case truncated
        /// A varint ran longer than ten bytes.
        case overlongVarint
        /// A wire type this reader doesn't know, or the old group types, which GTFS-realtime never uses.
        case unsupportedWireType(Int)
        /// Field number zero, which no message can have.
        case badFieldNumber
        /// Messages nested deeper than any feed needs.
        case tooDeep
    }

    public enum WireType: Int {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5
    }

    public struct Field {
        public let number: Int
        public let wireType: WireType
    }

    /// No real feed nests anywhere near this deep. The limit keeps a hostile one from using up the stack.
    public static let maxDepth = 16

    private let bytes: UnsafeRawBufferPointer
    private var position: Int
    private let end: Int
    let depth: Int

    init(bytes: UnsafeRawBufferPointer, start: Int, end: Int, depth: Int) {
        self.bytes = bytes
        self.position = start
        self.end = end
        self.depth = depth
    }

    /// Reads a whole message from `data`, handing `body` a reader positioned at its first field.
    public static func read<T>(_ data: Data, _ body: (inout ProtoReader) throws -> T) throws -> T {
        try data.withUnsafeBytes { raw in
            var reader = ProtoReader(bytes: raw, start: 0, end: raw.count, depth: 0)
            return try body(&reader)
        }
    }

    public var isAtEnd: Bool { position >= end }

    /// The next field's number and wire type, or nil at the end of the message.
    public mutating func next() throws -> Field? {
        guard position < end else { return nil }
        let key = try varint()
        let number = key >> 3
        guard number > 0, number <= 0x1FFF_FFFF else { throw Failure.badFieldNumber }
        let type = Int(key & 7)
        guard let wireType = WireType(rawValue: type) else { throw Failure.unsupportedWireType(type) }
        return Field(number: Int(number), wireType: wireType)
    }

    public mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for index in 0..<10 {
            guard position < end else { throw Failure.truncated }
            let byte = bytes[position]
            position += 1
            // The tenth byte can only hold the top bit.
            if index == 9, byte > 1 { throw Failure.overlongVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw Failure.overlongVarint
    }

    public mutating func fixed32() throws -> UInt32 {
        guard end - position >= 4 else { throw Failure.truncated }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[position + index]) << (8 * UInt32(index)) }
        position += 4
        return value
    }

    public mutating func fixed64() throws -> UInt64 {
        guard end - position >= 8 else { throw Failure.truncated }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[position + index]) << (8 * UInt64(index)) }
        position += 8
        return value
    }

    /// An `int32` or `int64` field: negative numbers are sent as ten-byte two's complement.
    public mutating func int64() throws -> Int64 {
        Int64(bitPattern: try varint())
    }

    public mutating func int32() throws -> Int32 {
        Int32(truncatingIfNeeded: Int64(bitPattern: try varint()))
    }

    public mutating func uint32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try varint())
    }

    public mutating func bool() throws -> Bool {
        try varint() != 0
    }

    private mutating func length() throws -> Int {
        let length = try varint()
        guard length <= UInt64(end - position) else { throw Failure.truncated }
        return Int(length)
    }

    public mutating func bytesField() throws -> Data {
        let count = try length()
        guard count > 0, let base = bytes.baseAddress else { return Data() }
        let data = Data(bytes: base + position, count: count)
        position += count
        return data
    }

    public mutating func string() throws -> String {
        let count = try length()
        let slice = UnsafeRawBufferPointer(rebasing: bytes[position..<(position + count)])
        position += count
        // A stray byte that isn't UTF-8 becomes a replacement mark rather than costing the whole feed.
        return String(decoding: slice, as: UTF8.self)
    }

    /// Reads an embedded message, handing `body` a reader limited to it.
    public mutating func message<T>(_ body: (inout ProtoReader) throws -> T) throws -> T {
        guard depth + 1 < Self.maxDepth else { throw Failure.tooDeep }
        let count = try length()
        var inner = ProtoReader(bytes: bytes, start: position, end: position + count, depth: depth + 1)
        position += count
        return try body(&inner)
    }

    /// Steps over a field that isn't needed.
    public mutating func skip(_ field: Field) throws {
        switch field.wireType {
        case .varint: _ = try varint()
        case .fixed64: _ = try fixed64()
        case .fixed32: _ = try fixed32()
        case .lengthDelimited: position += try length()
        }
    }
}

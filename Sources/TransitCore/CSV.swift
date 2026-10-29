import Foundation

/// Reads GTFS's comma-separated files, a piece at a time, as they come out of the zip.
///
/// It follows RFC 4180, as GTFS asks: quoted fields can hold commas, quotes ("" for one) and line
/// breaks, and lines end in LF or CRLF. A byte-order mark at the start is dropped, and spaces around
/// a field are trimmed, since some agencies pad them. Fields are only turned into strings when
/// asked for, which keeps a 90 MB stop_times.txt quick.
public struct CSVReader {
    public enum Failure: Error, Equatable {
        /// A line longer than any real GTFS line, usually a quote that's never closed.
        case lineTooLong(String)
        case noHeader(String)
    }

    /// No GTFS line comes near this. A quote that's never closed would otherwise swallow the file.
    public static let maxLine = 1 << 20

    public let file: String
    private let onRow: (Row) throws -> Void
    private var header: [String: Int]?
    private var line: [UInt8] = []
    private var fields: [(start: Int, end: Int, quoted: Bool)] = []
    private var fieldStart = 0
    private var inQuotes = false
    private var fieldQuoted = false
    /// A quote just closed, so another one right after it is an escaped quote.
    private var justClosed = false
    /// The first bytes, held until there are three to compare with a byte-order mark.
    private var opening: [UInt8]? = []
    private var sawCR = false

    /// A row, read by column name through the header.
    public struct Row {
        let line: [UInt8]
        let fields: [(start: Int, end: Int, quoted: Bool)]
        let header: [String: Int]

        public func callAsFunction(_ column: String) -> String? {
            guard let index = header[column], index < fields.count else { return nil }
            let value = string(index)
            return value.isEmpty ? nil : value
        }

        public var count: Int { fields.count }

        func string(_ index: Int) -> String {
            var (start, end, quoted) = fields[index]
            while start < end, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
            while end > start, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
            guard quoted else { return String(decoding: line[start..<end], as: UTF8.self) }
            // Quoted: drop the outer quotes and turn each "" back into ".
            if end - start >= 2, line[start] == 0x22 {
                start += 1
                if line[end - 1] == 0x22 { end -= 1 }
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(end - start)
            var index = start
            while index < end {
                bytes.append(line[index])
                if line[index] == 0x22, index + 1 < end, line[index + 1] == 0x22 { index += 1 }
                index += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public init(file: String, onRow: @escaping (Row) throws -> Void) {
        self.file = file
        self.onRow = onRow
    }

    /// Reads a whole file at once.
    public static func read(_ data: Data, file: String, onRow: @escaping (Row) throws -> Void) throws {
        var reader = CSVReader(file: file, onRow: onRow)
        try data.withUnsafeBytes { try reader.feed($0) }
        try reader.finish()
    }

    public mutating func feed(_ bytes: UnsafeRawBufferPointer) throws {
        guard var held = opening else { return try consume(bytes) }
        let taken = min(3 - held.count, bytes.count)
        held.append(contentsOf: bytes.prefix(taken))
        guard held.count == 3 else {
            opening = held
            return
        }
        opening = nil
        let start = held == [0xEF, 0xBB, 0xBF] ? 3 : 0
        try Array(held[start...]).withUnsafeBytes { try consume($0) }
        try consume(UnsafeRawBufferPointer(rebasing: bytes[taken...]))
    }

    private mutating func consume(_ bytes: UnsafeRawBufferPointer) throws {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inQuotes {
                line.append(byte)
                if byte == 0x22 { inQuotes = false; justClosed = true }
                continue
            }
            switch byte {
            case 0x22:
                // A quote opens a quoted field only at its start, and a quote right after one closes
                // is an escaped quote. Anywhere else, like Main St "A", it's just a character.
                let atStart = line[fieldStart...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
                if justClosed || (atStart && !fieldQuoted) {
                    inQuotes = true
                    fieldQuoted = true
                }
                justClosed = false
                line.append(byte)
            case 0x2C:
                endField()
                line.append(byte)
                fieldStart = line.count
            case 0x0A:
                if sawCR { sawCR = false; continue }
                try endLine()
            case 0x0D:
                try endLine()
                sawCR = true
                continue
            default:
                justClosed = false
                line.append(byte)
            }
            sawCR = false
            if line.count > Self.maxLine { throw Failure.lineTooLong(file) }
        }
        if line.count > Self.maxLine { throw Failure.lineTooLong(file) }
    }

    public mutating func finish() throws {
        if let held = opening {
            opening = nil
            try held.withUnsafeBytes { try consume($0) }
        }
        if !line.isEmpty || !fields.isEmpty { try endLine() }
        if header == nil { throw Failure.noHeader(file) }
    }

    private mutating func endField() {
        fields.append((fieldStart, line.count, fieldQuoted))
        fieldQuoted = false
        justClosed = false
    }

    private mutating func endLine() throws {
        endField()
        defer {
            line.removeAll(keepingCapacity: true)
            fields.removeAll(keepingCapacity: true)
            fieldStart = 0
        }
        // A blank line, or one of only commas and spaces, holds nothing.
        if fields.count == 1, line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return }
        if let header {
            try onRow(Row(line: line, fields: fields, header: header))
        } else {
            let row = Row(line: line, fields: fields, header: [:])
            var names: [String: Int] = [:]
            for index in 0..<fields.count {
                let name = row.string(index)
                if names[name] == nil { names[name] = index }
            }
            header = names
        }
    }
}

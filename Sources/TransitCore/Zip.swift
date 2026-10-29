import Compression
import Foundation

/// Reads the files in a zip archive, which is how every agency publishes its schedule.
///
/// Foundation can't open zip archives on macOS 14, but the Compression framework that ships with
/// macOS inflates raw DEFLATE, the only compression GTFS archives use. This file reads the archive's
/// directory itself, then hands each file's bytes to Compression a piece at a time, so a 90 MB
/// stop_times.txt never has to sit in memory whole. Every offset and size is checked against the
/// archive before it's used, and every file's CRC-32 and length are checked once it's read.
public struct ZipArchive: Sendable {
    public enum Failure: Error, Equatable {
        case notAZip
        case damaged(String)
        case encrypted(String)
        case unsupportedMethod(String, Int)
        case tooLarge(String)
        case checksumMismatch(String)
        case missing(String)
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        let method: Int
        let flags: Int
        let crc32: UInt32
        let compressedSize: Int
        public let size: Int
        let headerOffset: Int
    }

    /// Bigger than any agency's stop_times.txt. Keeps a zip bomb from filling the disk or memory.
    public static let maxEntrySize = 2_000_000_000
    /// Schedule files shrink about ten to one, and DEFLATE can't do better than about a thousand to
    /// one. A file claiming more than this is almost certainly built to fill memory, and is refused
    /// before it's inflated.
    static let maxRatio = 250
    static let maxEntries = 10_000

    public let entries: [Entry]
    private let data: Data

    public init(_ data: Data) throws {
        self.data = data
        entries = try data.withUnsafeBytes { try Self.directory(in: $0) }
    }

    /// The entry named `name`, at the top of the archive or in a single folder, as some agencies
    /// zip a folder rather than its files.
    public func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
            ?? entries.filter { ($0.name as NSString).lastPathComponent == name && $0.name.split(separator: "/").count == 2 }.first
    }

    /// The whole file at once, for small ones.
    public func contents(of name: String) throws -> Data {
        guard let entry = entry(name) else { throw Failure.missing(name) }
        var result = Data()
        result.reserveCapacity(entry.size)
        try read(entry) { result.append(contentsOf: $0) }
        return result
    }

    /// Hands `body` the file's bytes a piece at a time, then checks the file was whole.
    public func read(_ entry: Entry, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            let start = try Self.dataStart(of: entry, in: raw)
            let compressed = UnsafeRawBufferPointer(rebasing: raw[start..<(start + entry.compressedSize)])
            var crc = CRC32()
            var total = 0
            func check(_ chunk: UnsafeRawBufferPointer) throws {
                total += chunk.count
                guard total <= entry.size else { throw Failure.damaged(entry.name) }
                crc.update(chunk)
                try body(chunk)
            }
            switch entry.method {
            case 0:
                guard entry.compressedSize == entry.size else { throw Failure.damaged(entry.name) }
                var offset = 0
                while offset < compressed.count {
                    let end = min(offset + 1 << 20, compressed.count)
                    try check(UnsafeRawBufferPointer(rebasing: compressed[offset..<end]))
                    offset = end
                }
            case 8:
                try Inflater.inflate(compressed, name: entry.name, check)
            default:
                throw Failure.unsupportedMethod(entry.name, entry.method)
            }
            guard total == entry.size else { throw Failure.damaged(entry.name) }
            guard crc.value == entry.crc32 else { throw Failure.checksumMismatch(entry.name) }
        }
    }

    // MARK: Directory

    private static func directory(in raw: UnsafeRawBufferPointer) throws -> [Entry] {
        // The end-of-directory record is in the last 64 KB plus its own 22 bytes, after a comment.
        guard raw.count >= 22 else { throw Failure.notAZip }
        var eocd = -1
        var index = raw.count - 22
        let floor = max(0, raw.count - 22 - 65_535)
        while index >= floor {
            if raw.u32(index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw Failure.notAZip }
        var count = Int(raw.u16(eocd + 10))
        var size = Int(raw.u32(eocd + 12))
        var offset = Int(raw.u32(eocd + 16))
        // Zip64, for archives with huge counts or offsets: a locator just before the record points
        // at a larger record with the real numbers.
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF, eocd >= 20, raw.u32(eocd - 20) == 0x0706_4B50 {
            let record = try int(raw.u64(eocd - 12))
            guard record >= 0, record + 56 <= raw.count, raw.u32(record) == 0x0606_4B50 else { throw Failure.notAZip }
            count = try int(raw.u64(record + 32))
            size = try int(raw.u64(record + 40))
            offset = try int(raw.u64(record + 48))
        }
        guard count <= maxEntries, offset >= 0, size >= 0, offset + size <= raw.count else { throw Failure.notAZip }

        var entries: [Entry] = []
        var position = offset
        for _ in 0..<count {
            guard position + 46 <= offset + size, raw.u32(position) == 0x0201_4B50 else { throw Failure.notAZip }
            let flags = Int(raw.u16(position + 8))
            let method = Int(raw.u16(position + 10))
            let crc = raw.u32(position + 16)
            var compressed = Int(raw.u32(position + 20))
            var uncompressed = Int(raw.u32(position + 24))
            let nameLength = Int(raw.u16(position + 28))
            let extraLength = Int(raw.u16(position + 30))
            let commentLength = Int(raw.u16(position + 32))
            var header = Int(raw.u32(position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= offset + size else { throw Failure.notAZip }
            let nameBytes = UnsafeRawBufferPointer(rebasing: raw[nameStart..<extraStart])
            // Names are UTF-8 when bit 11 is set, and in practice ASCII otherwise.
            let name = String(decoding: nameBytes, as: UTF8.self)

            // A Zip64 extra field holds whichever of the three numbers didn't fit, in this order.
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || header == 0xFFFF_FFFF {
                var extra = extraStart
                while extra + 4 <= extraStart + extraLength {
                    let id = raw.u16(extra), length = Int(raw.u16(extra + 2))
                    let body = extra + 4
                    guard body + length <= extraStart + extraLength else { break }
                    if id == 0x0001 {
                        var field = body
                        for keyPath in [0, 1, 2] {
                            let wanted = [uncompressed, compressed, header][keyPath] == 0xFFFF_FFFF
                            guard wanted else { continue }
                            guard field + 8 <= body + length else { throw Failure.damaged(name) }
                            let value = try int(raw.u64(field))
                            switch keyPath {
                            case 0: uncompressed = value
                            case 1: compressed = value
                            default: header = value
                            }
                            field += 8
                        }
                    }
                    extra = body + length
                }
            }

            // Sizes too big for 32 bits with no Zip64 field to give them.
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || header == 0xFFFF_FFFF { throw Failure.damaged(name) }
            position = next
            // Folders, and the resource forks macOS's Finder adds, aren't files to read.
            if name.hasSuffix("/") || name.hasPrefix("__MACOSX/") { continue }
            guard flags & 1 == 0 else { throw Failure.encrypted(name) }
            guard uncompressed <= maxEntrySize else { throw Failure.tooLarge(name) }
            guard compressed >= 0, header >= 0, header + 30 <= raw.count, compressed <= raw.count else { throw Failure.damaged(name) }
            if method == 8, uncompressed > 0, uncompressed / max(compressed, 1) > maxRatio { throw Failure.tooLarge(name) }
            entries.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: compressed, size: uncompressed, headerOffset: header))
        }
        return entries
    }

    private static func dataStart(of entry: Entry, in raw: UnsafeRawBufferPointer) throws -> Int {
        let header = entry.headerOffset
        guard header + 30 <= raw.count, raw.u32(header) == 0x0403_4B50 else { throw Failure.damaged(entry.name) }
        let start = header + 30 + Int(raw.u16(header + 26)) + Int(raw.u16(header + 28))
        guard start <= raw.count, entry.compressedSize <= raw.count - start else { throw Failure.damaged(entry.name) }
        return start
    }

    private static func int(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max / 2) else { throw Failure.notAZip }
        return Int(value)
    }
}

/// Raw DEFLATE, inflated by the Compression framework a megabyte at a time.
enum Inflater {
    static let chunk = 1 << 20

    static func inflate(_ input: UnsafeRawBufferPointer, name: String, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipArchive.Failure.damaged(name)
        }
        defer { compression_stream_destroy(stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { output.deallocate() }
        // An empty file can still be a valid stream of a few bytes, but zero bytes is never one.
        guard let base = input.baseAddress, input.count > 0 else { throw ZipArchive.Failure.damaged(name) }
        stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = input.count
        while true {
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = chunk
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 { try body(UnsafeRawBufferPointer(start: output, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // Out of input with no end of stream, and nothing more coming out: it was cut short.
                if produced == 0, stream.pointee.src_size == 0 { throw ZipArchive.Failure.damaged(name) }
            default:
                throw ZipArchive.Failure.damaged(name)
            }
        }
    }
}

/// The CRC-32 zip uses to check each file, the same polynomial as Ethernet and PNG.
struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = ~value
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        value = ~c
    }

    static func of(_ data: Data) -> UInt32 {
        var crc = CRC32()
        data.withUnsafeBytes { crc.update($0) }
        return crc.value
    }
}

extension UnsafeRawBufferPointer {
    // Callers check the bounds; these read little-endian numbers without assuming alignment.
    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= count else { return 0 }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }

    func u64(_ at: Int) -> UInt64 {
        guard at >= 0, at + 8 <= count else { return 0 }
        return UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }
}

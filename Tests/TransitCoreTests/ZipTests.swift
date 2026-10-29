import Foundation
import Testing
@testable import TransitCore

@Suite("Zip")
struct ZipTests {
    let text = Data(String(repeating: "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n", count: 40).utf8)

    @Test(arguments: [true, false])
    func readsStoredAndDeflatedFiles(deflate: Bool) throws {
        let zip = try ZipArchive(ZipWriter.archive([
            .init(name: "stops.txt", data: text, deflate: deflate),
            .init(name: "empty.txt", data: Data(), deflate: deflate),
        ]))
        #expect(zip.entries.map(\.name) == ["stops.txt", "empty.txt"])
        #expect(try zip.contents(of: "stops.txt") == text)
        #expect(try zip.contents(of: "empty.txt") == Data())
        #expect(throws: ZipArchive.Failure.missing("routes.txt")) { try zip.contents(of: "routes.txt") }
    }

    @Test func readsALargeFileInPieces() throws {
        var random = SeededRandom(state: 9)
        // Over two of the inflater's one-megabyte pieces, and not all compressible.
        var bytes = [UInt8](repeating: 0, count: 2_600_000)
        for index in bytes.indices {
            bytes[index] = index % 3 == 0 ? UInt8.random(in: 0...255, using: &random) : UInt8(48 + index % 10)
        }
        let big = Data(bytes)
        let zip = try ZipArchive(ZipWriter.archive([.init(name: "stop_times.txt", data: big)]))
        var pieces = 0
        var result = Data()
        try zip.read(zip.entry("stop_times.txt")!) { chunk in
            pieces += 1
            #expect(chunk.count <= Inflater.chunk)
            result.append(contentsOf: chunk)
        }
        #expect(pieces >= 3)
        #expect(result == big)
    }

    @Test func findsTheDirectoryPastAComment() throws {
        let zip = try ZipArchive(ZipWriter.archive([.init(name: "agency.txt", data: text)], comment: String(repeating: "c", count: 3000)))
        #expect(try zip.contents(of: "agency.txt") == text)
    }

    @Test func readsZip64() throws {
        let zip = try ZipArchive(ZipWriter.archive([.init(name: "a.txt", data: text), .init(name: "b.txt", data: text, deflate: false)], zip64: true))
        #expect(zip.entries.count == 2)
        #expect(try zip.contents(of: "b.txt") == text)
        #expect(try zip.contents(of: "a.txt") == text)
    }

    @Test func findsFilesZippedInsideAFolder() throws {
        let zip = try ZipArchive(ZipWriter.archive([
            .init(name: "gtfs/", data: Data(), deflate: false),
            .init(name: "gtfs/stops.txt", data: text),
            .init(name: "__MACOSX/gtfs/._stops.txt", data: Data("junk".utf8)),
            .init(name: "deep/er/routes.txt", data: text),
        ]))
        #expect(zip.entries.map(\.name) == ["gtfs/stops.txt", "deep/er/routes.txt"])
        #expect(zip.entry("stops.txt")?.name == "gtfs/stops.txt")
        // Only one folder deep, so an archive of archives isn't mistaken for a schedule.
        #expect(zip.entry("routes.txt") == nil)
    }

    @Test func archivesMadeByMacOSToolsRead() throws {
        let folder = TestFolder()
        let source = folder.url.appendingPathComponent("feed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try text.write(to: source.appendingPathComponent("stops.txt"))
        try Data("agency_id,agency_name\n".utf8).write(to: source.appendingPathComponent("agency.txt"))
        let made = folder.url.appendingPathComponent("ditto.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, made.path]
        try ditto.run()
        ditto.waitUntilExit()
        let zip = try ZipArchive(Data(contentsOf: made))
        #expect(try zip.contents(of: "stops.txt") == text)

        let infoZip = folder.url.appendingPathComponent("zip.zip")
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        tool.currentDirectoryURL = source
        tool.arguments = ["-q", "-X", infoZip.path, "stops.txt", "agency.txt"]
        try tool.run()
        tool.waitUntilExit()
        let second = try ZipArchive(Data(contentsOf: infoZip))
        #expect(try second.contents(of: "stops.txt") == text)
        #expect(try second.contents(of: "agency.txt") == Data("agency_id,agency_name\n".utf8))
    }

    @Test func refusesWhatIsNotAZip() {
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive(Data()) }
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive(Data("<html>Not found</html>".utf8)) }
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive(Data(repeating: 0, count: 5000)) }
    }

    @Test func catchesAChangedByte() throws {
        var data = ZipWriter.archive([.init(name: "stops.txt", data: text, deflate: false)])
        data[40] ^= 0x20
        let zip = try ZipArchive(data)
        #expect(throws: ZipArchive.Failure.checksumMismatch("stops.txt")) { try zip.contents(of: "stops.txt") }
    }

    @Test func catchesAFileLongerOrShorterThanItSays() throws {
        var data = ZipWriter.archive([.init(name: "a.txt", data: text)])
        // The central directory's uncompressed size, made smaller than the real file.
        let central = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        data[central + 24] = 10
        data[central + 25] = 0
        let zip = try ZipArchive(data)
        #expect(throws: ZipArchive.Failure.damaged("a.txt")) { try zip.contents(of: "a.txt") }
    }

    @Test func refusesEncryptedAndUnknownMethods() throws {
        var data = ZipWriter.archive([.init(name: "a.txt", data: text)])
        let central = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        data[central + 8] |= 1
        #expect(throws: ZipArchive.Failure.encrypted("a.txt")) { try ZipArchive(data) }

        var other = ZipWriter.archive([.init(name: "a.txt", data: text)])
        let at = other.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        other[at + 10] = 12 // bzip2
        let zip = try ZipArchive(other)
        #expect(throws: ZipArchive.Failure.unsupportedMethod("a.txt", 12)) { try zip.contents(of: "a.txt") }
    }

    @Test func refusesAZipBomb() throws {
        // Ten million zeros squeeze into a few kilobytes, far past any text file's ratio.
        let zeros = Data(count: 10_000_000)
        #expect(throws: ZipArchive.Failure.tooLarge("zeros.txt")) { try ZipArchive(ZipWriter.archive([.init(name: "zeros.txt", data: zeros)])) }
        // And a file that claims to be small but inflates to more is stopped as soon as it passes.
        var data = ZipWriter.archive([.init(name: "zeros.txt", data: Data(count: 500_000))])
        let central = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        data.replaceSubrange((central + 24)..<(central + 28), with: [0xE8, 0x03, 0, 0])
        let zip = try ZipArchive(data)
        #expect(throws: ZipArchive.Failure.damaged("zeros.txt")) { try zip.contents(of: "zeros.txt") }
    }

    @Test func checksTheCRCAgainstKnownValues() {
        #expect(CRC32.of(Data()) == 0)
        #expect(CRC32.of(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.of(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    /// Damaged archives must be read or refused, never crash or read outside the data.
    @Test func damagedArchivesNeverCrash() {
        let valid = Lakeside.zip()
        let stored = Lakeside.zip(deflate: false)
        var random = SeededRandom(state: 3)
        for round in 0..<1500 {
            var data = round % 2 == 0 ? valid : stored
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                let at = Int.random(in: 0..<data.count, using: &random)
                data[at] = UInt8.random(in: 0...255, using: &random)
            }
            if let zip = try? ZipArchive(data) {
                for entry in zip.entries { try? zip.read(entry) { _ in } }
            }
        }
        for length in stride(from: 0, to: valid.count, by: 13) {
            if let zip = try? ZipArchive(valid.prefix(length)) {
                for entry in zip.entries { try? zip.read(entry) { _ in } }
            }
        }
        // Random bytes after a real end-of-directory signature.
        for _ in 0..<1500 {
            var data = Data((0..<Int.random(in: 22...300, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) })
            data.replaceSubrange((data.count - 22)..<(data.count - 18), with: [0x50, 0x4B, 0x05, 0x06])
            if let zip = try? ZipArchive(data) {
                for entry in zip.entries { try? zip.read(entry) { _ in } }
            }
        }
    }
}

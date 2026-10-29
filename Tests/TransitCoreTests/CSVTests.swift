import Foundation
import Testing
@testable import TransitCore

@Suite("CSV")
struct CSVTests {
    private func rows(_ text: String, columns: [String]) throws -> [[String?]] {
        try rows(Data(text.utf8), columns: columns)
    }

    private func rows(_ data: Data, columns: [String], piece: Int? = nil) throws -> [[String?]] {
        var result: [[String?]] = []
        var reader = CSVReader(file: "test.txt") { row in result.append(columns.map { row($0) }) }
        if let piece {
            var start = 0
            while start < data.count {
                let end = min(start + piece, data.count)
                try data[start..<end].withUnsafeBytes { try reader.feed($0) }
                start = end
            }
        } else {
            try data.withUnsafeBytes { try reader.feed($0) }
        }
        try reader.finish()
        return result
    }

    @Test func readsColumnsByName() throws {
        let result = try rows("b,a,c\n2,1,3\n5,4,6\n", columns: ["a", "b", "c", "missing"])
        #expect(result == [["1", "2", "3", nil], ["4", "5", "6", nil]])
    }

    @Test func readsQuotedFields() throws {
        let text = "name,desc\n\"Night Owl, Late\",\"Say \"\"hi\"\"\"\n\"Two\nlines\",plain\n"
        #expect(try rows(text, columns: ["name", "desc"]) == [["Night Owl, Late", "Say \"hi\""], ["Two\nlines", "plain"]])
    }

    @Test func handlesLineEndingsBOMsAndPadding() throws {
        let text = "\u{FEFF}stop_id, stop_name \r\n 1 , Elm St \r\n\r\n2,Oak\r\n3,Ash"
        #expect(try rows(text, columns: ["stop_id", "stop_name"]) == [["1", "Elm St"], ["2", "Oak"], ["3", "Ash"]])
        #expect(try rows("a\r1\r2", columns: ["a"]) == [["1"], ["2"]])
    }

    @Test func emptyFieldsAreMissing() throws {
        #expect(try rows("a,b,c\n,,\n1\n", columns: ["a", "b", "c"]) == [[nil, nil, nil], ["1", nil, nil]])
    }

    @Test func theFirstOfTwoColumnsWithOneNameWins() throws {
        #expect(try rows("a,a\n1,2\n", columns: ["a"]) == [["1"]])
    }

    @Test func readsTheSameInAnySizePieces() throws {
        let text = "\u{FEFF}id,name\r\n1,\"Elm, \"\"North\"\"\"\r\n2,Ünïcødé Hall\r\n3,\"multi\r\nline\"\r\n"
        let whole = try rows(Data(text.utf8), columns: ["id", "name"])
        #expect(whole.count == 3)
        for piece in [1, 2, 3, 5, 7, 64] {
            #expect(try rows(Data(text.utf8), columns: ["id", "name"], piece: piece) == whole)
        }
    }

    @Test func aQuoteInsideAFieldIsJustACharacter() throws {
        let text = "name,code\nMain St \"A\",7\nOak,8\n"
        #expect(try rows(text, columns: ["name", "code"]) == [["Main St \"A\"", "7"], ["Oak", "8"]])
    }

    @Test func aQuoteThatNeverClosesIsStopped() {
        let text = "a\n\"" + String(repeating: "x", count: CSVReader.maxLine + 10)
        #expect(throws: CSVReader.Failure.lineTooLong("test.txt")) { try rows(text, columns: ["a"]) }
    }

    @Test func anEmptyFileHasNoHeader() {
        #expect(throws: CSVReader.Failure.noHeader("test.txt")) { try rows("", columns: []) }
        #expect(throws: CSVReader.Failure.noHeader("test.txt")) { try rows("\n\n", columns: []) }
    }

    @Test func rowsShorterOrLongerThanTheHeaderStillRead() throws {
        #expect(try rows("a,b\n1\n1,2,3\n", columns: ["a", "b"]) == [["1", nil], ["1", "2"]])
    }

    @Test func randomTextNeverCrashes() {
        var random = SeededRandom(state: 4)
        let alphabet: [UInt8] = Array("ab,\"\r\n \u{FEFF}é".utf8)
        for _ in 0..<3000 {
            let bytes = (0..<Int.random(in: 0...200, using: &random)).map { _ in
                Bool.random(using: &random) ? alphabet.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random)
            }
            _ = try? rows(Data(bytes), columns: ["a", "b"], piece: Int.random(in: 1...20, using: &random))
        }
    }
}

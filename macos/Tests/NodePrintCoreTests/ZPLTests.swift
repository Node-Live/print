import CoreGraphics
import Foundation
import Testing
@testable import NodePrintCore

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct Vector: Decodable {
    let name: String
    let dpi: Int
    let width: Int
    let length: Int
    let rows: [String]
    let data: String

    var bitmap: Bitmap {
        Bitmap(width: width, length: length, bytes: rows.flatMap { row in
            stride(from: 0, to: row.count, by: 2).map { offset in
                let start = row.index(row.startIndex, offsetBy: offset)
                return UInt8(row[start ..< row.index(start, offsetBy: 2)], radix: 16)!
            }
        })
    }

    static func all() throws -> [(file: String, vector: Vector)] {
        let directory = repository.appending(path: "testdata/zpl")
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { ($0, try JSONDecoder().decode(Vector.self, from: Data(contentsOf: directory.appending(path: $0)))) }
    }
}

@Test(arguments: try Vector.all().map(\.file))
func compressesLikeTheVector(file: String) throws {
    let vector = try #require(try Vector.all().first { $0.file == file }?.vector)
    #expect(ZPL.compressed(vector.bitmap) == vector.data)
}

@Test(arguments: try Vector.all().map(\.file))
func wrapsTheDataInTheJobTemplate(file: String) throws {
    let vector = try #require(try Vector.all().first { $0.file == file }?.vector)
    let bytesPerRow = (vector.width + 7) / 8
    let total = bytesPerRow * vector.length
    let expected = "^XA\n^PW\(vector.width)\n^LL\(vector.length)\n^LH0,0\n^FO0,0^GFA,\(total),\(total),\(bytesPerRow),\(vector.data)^FS\n^PQ3,0,1,Y\n^XZ\n"
    #expect(ZPL.job(pages: [vector.bitmap], copies: 3) == expected)
}

@Test func writesOneBlockPerPageInPageOrder() throws {
    let vectors = try Vector.all().map(\.vector)
    let first = try #require(vectors.first { $0.name.hasPrefix("a row of only 0") })
    let second = try #require(vectors.first { $0.name.hasPrefix("a row of only F") })
    let job = ZPL.job(pages: [first.bitmap, second.bitmap], copies: 1)
    let blocks = job.components(separatedBy: "^XZ\n").dropLast()
    #expect(blocks.count == 2)
    #expect(blocks.first?.contains("^GFA,4,4,4,,^FS") == true)
    #expect(blocks.last?.contains("^GFA,4,4,4,!^FS") == true)
}

@Test(arguments: ["blank-4x6-203", "border-4x6-203", "corner-landscape-4x6-203"])
func rendersTheLabelPageToTheVectorDots(name: String) throws {
    let directory = repository.appending(path: "testdata/zpl")
    let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: directory.appending(path: "\(name).json")))
    let document = try #require(CGPDFDocument(directory.appending(path: "\(name).pdf") as CFURL))
    let page = try #require(document.page(at: 1))
    #expect(LabelLayout.bitmap(page, dpi: vector.dpi) == vector.bitmap)
}

@Test func sizesTheLabelAtTheReportedResolution() throws {
    let url = repository.appending(path: "testdata/zpl/blank-4x6-203.pdf")
    let page = try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
    let bitmap = LabelLayout.bitmap(page, dpi: 300)
    #expect(bitmap.width == 1200)
    #expect(bitmap.length == 1800)
    #expect(bitmap.bytesPerRow == 150)
}

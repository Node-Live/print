import CoreGraphics
import Testing
@testable import NodePrintCore

private let label = CGRect(x: 0, y: 0, width: 812, height: 1218)

private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
    abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
}

@Test func turnsALandscapePageClockwise() {
    let t = LabelLayout.transform(pageSize: CGSize(width: 432, height: 288), into: label)
    #expect(close(CGPoint(x: 0, y: 288).applying(t), CGPoint(x: 812, y: 1218)))
    #expect(close(CGPoint(x: 432, y: 288).applying(t), CGPoint(x: 812, y: 0)))
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: 1218)))
}

@Test func keepsAPortraitPageUpright() {
    let t = LabelLayout.transform(pageSize: CGSize(width: 288, height: 432), into: label)
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: 0)))
    #expect(close(CGPoint(x: 288, y: 432).applying(t), CGPoint(x: 812, y: 1218)))
}

@Test func fitsATallerPageAndCentresItAcross() {
    let t = LabelLayout.transform(pageSize: CGSize(width: 288, height: 576), into: label)
    let scale = 1218.0 / 576
    let x = (812 - 288 * scale) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: x, y: 0)))
    #expect(close(CGPoint(x: 288, y: 576).applying(t), CGPoint(x: 812 - x, y: 1218)))
}

@Test func fitsAWiderPageAndCentresItDown() {
    let t = LabelLayout.transform(pageSize: CGSize(width: 612, height: 792), into: label)
    let scale = 812.0 / 612
    let y = (1218 - 792 * scale) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: y)))
    #expect(close(CGPoint(x: 612, y: 792).applying(t), CGPoint(x: 812, y: 1218 - y)))
}

@Test func fitsALandscapeLetterPageAfterTurningIt() {
    let t = LabelLayout.transform(pageSize: CGSize(width: 792, height: 612), into: label)
    let scale = 812.0 / 612
    let y = (1218 - 792 * scale) / 2
    #expect(close(CGPoint(x: 0, y: 612).applying(t), CGPoint(x: 812, y: 1218 - y)))
    #expect(close(CGPoint(x: 792, y: 0).applying(t), CGPoint(x: 0, y: y)))
}

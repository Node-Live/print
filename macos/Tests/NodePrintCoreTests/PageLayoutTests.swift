import CoreGraphics
import Testing
@testable import NodePrintCore

private let label = CGRect(x: 0, y: 0, width: 812, height: 1218)
private let letter = CGSize(width: 612, height: 792)
private let printable = CGRect(x: 18, y: 36, width: 576, height: 720)

private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
    abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
}

private func labelTransform(_ size: CGSize) -> CGAffineTransform {
    PageLayout.transform(pageSize: size, into: label, turn: PageLayout.labelTurn(for: size))
}

private func documentTransform(_ size: CGSize) -> CGAffineTransform {
    PageLayout.transform(pageSize: size, into: printable, turn: PageLayout.documentTurn(for: size, on: letter))
}

@Test func turnsALandscapeLabelPageClockwise() {
    let t = labelTransform(CGSize(width: 432, height: 288))
    #expect(close(CGPoint(x: 0, y: 288).applying(t), CGPoint(x: 812, y: 1218)))
    #expect(close(CGPoint(x: 432, y: 288).applying(t), CGPoint(x: 812, y: 0)))
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: 1218)))
}

@Test func keepsAPortraitLabelPageUpright() {
    let t = labelTransform(CGSize(width: 288, height: 432))
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: 0)))
    #expect(close(CGPoint(x: 288, y: 432).applying(t), CGPoint(x: 812, y: 1218)))
}

@Test func fitsATallerLabelPageAndCentresItAcross() {
    let t = labelTransform(CGSize(width: 288, height: 576))
    let x = (812 - 288 * 1218.0 / 576) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: x, y: 0)))
    #expect(close(CGPoint(x: 288, y: 576).applying(t), CGPoint(x: 812 - x, y: 1218)))
}

@Test func fitsAWiderLabelPageAndCentresItDown() {
    let t = labelTransform(CGSize(width: 612, height: 792))
    let y = (1218 - 792 * 812.0 / 612) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 0, y: y)))
    #expect(close(CGPoint(x: 612, y: 792).applying(t), CGPoint(x: 812, y: 1218 - y)))
}

@Test func fitsALandscapeLetterPageOnALabelAfterTurningIt() {
    let t = labelTransform(CGSize(width: 792, height: 612))
    let y = (1218 - 792 * 812.0 / 612) / 2
    #expect(close(CGPoint(x: 0, y: 612).applying(t), CGPoint(x: 812, y: 1218 - y)))
    #expect(close(CGPoint(x: 792, y: 0).applying(t), CGPoint(x: 0, y: y)))
}

@Test func fitsAPortraitDocumentPageIntoThePrintableAreaAndCentresIt() {
    let t = documentTransform(letter)
    let scale = min(576 / 612.0, 720 / 792.0)
    let x = 18 + (576 - 612 * scale) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: x, y: 36)))
    #expect(close(CGPoint(x: 612, y: 792).applying(t), CGPoint(x: 612 - x, y: 756)))
}

@Test func printsALandscapeDocumentPageLandscape() {
    let t = documentTransform(CGSize(width: 792, height: 612))
    let scale = min(576 / 612.0, 720 / 792.0)
    let x = 18 + (576 - 612 * scale) / 2
    // Turned counter-clockwise: the page's top-left corner goes to the sheet's bottom-left.
    #expect(close(CGPoint(x: 0, y: 612).applying(t), CGPoint(x: x, y: 36)))
    #expect(close(CGPoint(x: 792, y: 0).applying(t), CGPoint(x: 612 - x, y: 756)))
}

@Test func scalesASmallDocumentPageUpToThePrintableArea() {
    let t = documentTransform(CGSize(width: 288, height: 432))
    let scale = min(576 / 288.0, 720 / 432.0)
    let x = 18 + (576 - 288 * scale) / 2
    #expect(close(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: x, y: 36)))
    #expect(close(CGPoint(x: 288, y: 432).applying(t), CGPoint(x: 612 - x, y: 756)))
}

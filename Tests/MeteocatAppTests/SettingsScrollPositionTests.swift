import XCTest
import AppKit
@testable import MeteocatApp

final class SettingsScrollPositionTests: XCTestCase {
    @MainActor func testReopeningResetsScrolledDocumentToTopForBothCoordinateSystems() {
        for flipped in [false, true] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            scroll.hasVerticalScroller = true
            let document = TestDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 1200), flipped: flipped)
            scroll.documentView = document
            let root = NSView(frame: scroll.frame)
            root.addSubview(scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            SettingsScrollPosition.reset(in: root)
            let expected = flipped ? 0 : document.bounds.height - scroll.contentView.bounds.height
            XCTAssertEqual(scroll.contentView.bounds.origin.y, expected, accuracy: 0.5)
            // Reopening the same retained view resets a later scroll too.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
            SettingsScrollPosition.reset(in: root)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, expected, accuracy: 0.5)
        }
    }
}

private final class TestDocument: NSView {
    private let flippedCoordinates: Bool
    override var isFlipped: Bool { flippedCoordinates }
    init(frame: NSRect, flipped: Bool) { self.flippedCoordinates = flipped; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

import XCTest
import CoreGraphics
@testable import MeteocatApp

final class RadarPresentationTests: XCTestCase {
    func testStatusClickUsesWindowOrderInsteadOfTransientKeyFocus() {
        func window(_ number: Int, owner: Int, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: number),
             kCGWindowOwnerPID as String: NSNumber(value: owner),
             kCGWindowLayer as String: NSNumber(value: layer)]
        }
        let radar = window(10, owner: 20)
        let status = window(11, owner: 20, layer: 25)
        // The status control may take key focus, but its higher window level is irrelevant.
        XCTAssertTrue(RadarStatusPresentation.radarIsFrontmost([status, radar], pid: 20, window: 10))
        // Another app, or Settings in the same app, must be brought behind the radar on this click.
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost([window(12, owner: 30), radar], pid: 20, window: 10))
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost([window(13, owner: 20), radar], pid: 20, window: 10))
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost(nil, pid: 20, window: 10))
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost([], pid: 20, window: 10))
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost([[:], radar], pid: 20, window: 10))
        XCTAssertFalse(RadarStatusPresentation.radarIsFrontmost([[kCGWindowLayer as String: NSNumber(value: 0)], radar], pid: 20, window: 10))
    }
    func testToggleRestoresHiddenBackgroundAndMinimizedRadar() {
        let cases = [
            (visible: false, miniaturized: false, onActiveSpace: true, appActive: true, keyWindow: false),
            (visible: true, miniaturized: true, onActiveSpace: true, appActive: true, keyWindow: false),
            (visible: true, miniaturized: false, onActiveSpace: true, appActive: false, keyWindow: false),
            (visible: true, miniaturized: false, onActiveSpace: true, appActive: true, keyWindow: false),
            (visible: true, miniaturized: false, onActiveSpace: false, appActive: true, keyWindow: true)
        ]
        for state in cases {
            XCTAssertFalse(RadarPresentation.shouldHide(visible: state.visible, miniaturized: state.miniaturized,
                onActiveSpace: state.onActiveSpace, appActive: state.appActive, keyWindow: state.keyWindow))
        }
        XCTAssertTrue(RadarPresentation.shouldHide(visible: true, miniaturized: false,
                                                  onActiveSpace: true, appActive: true, keyWindow: true))
    }
}

import XCTest
@testable import MeteocatApp

final class MapRecenteringTests: XCTestCase {
    func testPanAfterEdgeAnchoredZoomDoesNotSnapToRecenteringBand() throws {
        var camera = MapCamera()
        camera.resize(to: CGSize(width: 600, height: 1000))
        camera.setZoom(1.1, anchoredAt: CGPoint(x: 510, y: 0))
        let previous = try XCTUnwrap(camera.fit).offset
        camera.pan(by: CGPoint(x: 0, y: -4))
        XCTAssertEqual(try XCTUnwrap(camera.fit).offset.y, previous.y - 4, accuracy: 0.000001)
    }

    func testSmoothedZoomOutAfterPanRestoresInitialCropWithoutFinalJump() throws {
        for size in [CGSize(width: 600, height: 400), CGSize(width: 1200, height: 300), CGSize(width: 400, height: 1000)] {
            for rate: Double in [30, 60, 120] {
              for startingZoom: CGFloat in [1.0004, 1.01, 1.1, 4] {
                var camera = MapCamera()
                camera.resize(to: size)
                let initial = try XCTUnwrap(camera.fit)
                let anchor = CGPoint(x: size.width * 0.85, y: size.height * 0.2)
                camera.setZoom(startingZoom, anchoredAt: anchor)
                camera.pan(by: CGPoint(x: -10000, y: 10000))
                var motion = MapWheelMotion()
                motion.enqueue(delta: -100, precise: false, zoom: camera.zoom, anchor: anchor)
                var finalStep: CGFloat = .infinity
                for _ in 0..<300 {
                    guard let next = motion.advance(from: camera.zoom, elapsed: 1 / rate) else { break }
                    let previous = try XCTUnwrap(camera.fit).offset
                    camera.setZoom(next, anchoredAt: motion.anchor)
                    let fit = try XCTUnwrap(camera.fit)
                    XCTAssertLessThanOrEqual(fit.rect.minX, 0.000001)
                    XCTAssertLessThanOrEqual(fit.rect.minY, 0.000001)
                    XCTAssertGreaterThanOrEqual(fit.rect.maxX, size.width - 0.000001)
                    XCTAssertGreaterThanOrEqual(fit.rect.maxY, size.height - 0.000001)
                    finalStep = hypot(fit.offset.x - previous.x, fit.offset.y - previous.y)
                }
                XCTAssertNil(motion.target)
                XCTAssertEqual(camera.zoom, 1)
                XCTAssertEqual(camera.fit?.offset.x ?? .nan, initial.offset.x, accuracy: 0.000001)
                XCTAssertEqual(camera.fit?.offset.y ?? .nan, initial.offset.y, accuracy: 0.000001)
                XCTAssertLessThan(finalStep, 1, "The last smoothing step must not snap the crop back")
                camera.resize(to: CGSize(width: 900, height: 500))
                XCTAssertEqual(camera.focus.x, 0.5, accuracy: 0.000001)
                XCTAssertEqual(camera.focus.y, 0.5, accuracy: 0.000001)
              }
            }
        }
    }
}

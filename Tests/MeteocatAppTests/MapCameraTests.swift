import XCTest
import AppKit
@testable import MeteocatApp

final class MapCameraTests: XCTestCase {
    private let size = CGSize(width: 750, height: 470)
    private func assertCoverage(_ camera: MapCamera, file: StaticString = #filePath, line: UInt = #line) {
        guard let fit = camera.fit else { return XCTFail("Missing fit", file: file, line: line) }
        XCTAssertLessThanOrEqual(fit.rect.minX, 0.000001, file: file, line: line)
        XCTAssertLessThanOrEqual(fit.rect.minY, 0.000001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(fit.rect.maxX, camera.viewport.width - 0.000001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(fit.rect.maxY, camera.viewport.height - 0.000001, file: file, line: line)
    }
    func testCoverResetAndCursorAnchor() throws {
        var camera = MapCamera(); camera.resize(to: size)
        let initial = try XCTUnwrap(camera.fit)
        XCTAssertEqual(initial.scale, 470.0 / 380, accuracy: 0.000001)
        XCTAssertEqual(initial.offset.y, 0, accuracy: 0.000001)
        let anchor = CGPoint(x: 300, y: 220)
        let canonical = try XCTUnwrap(initial.canonicalPoint(anchor))
        camera.setZoom(3, anchoredAt: anchor)
        let after = try XCTUnwrap(camera.fit).viewPoint(canonical)
        XCTAssertEqual(after.x, anchor.x, accuracy: 0.000001)
        XCTAssertEqual(after.y, anchor.y, accuracy: 0.000001)
        camera.pan(by: CGPoint(x: 45, y: -60))
        camera.reset()
        XCTAssertEqual(camera.zoom, 1)
        XCTAssertEqual(camera.fit?.rect, initial.rect)
    }
    func testCoverAcrossAspectRatiosAndOneXRestoresCenteredCrop() throws {
        for viewport in [size, CGSize(width: 1200, height: 300), CGSize(width: 400, height: 1000), CGSize(width: 500, height: 340)] {
            var camera = MapCamera(); camera.resize(to: viewport)
            let initial = try XCTUnwrap(camera.fit)
            XCTAssertEqual(initial.offset.x, (viewport.width - initial.rect.width) / 2, accuracy: 0.000001)
            XCTAssertEqual(initial.offset.y, (viewport.height - initial.rect.height) / 2, accuracy: 0.000001)
            camera.setZoom(4, anchoredAt: CGPoint(x: viewport.width * 0.2, y: viewport.height * 0.3))
            camera.pan(by: CGPoint(x: -100000, y: 100000))
            assertCoverage(camera)
            camera.setZoom(1, anchoredAt: CGPoint(x: viewport.width * 0.8, y: viewport.height * 0.8))
            assertCoverage(camera)
            XCTAssertEqual(camera.fit?.rect, initial.rect)
            camera.reset()
            XCTAssertEqual(camera.fit?.rect, initial.rect)
        }
        var camera = MapCamera(); camera.resize(to: size)
        camera.setZoom(2, anchoredAt: CGPoint(x: 375, y: 235))
        camera.pan(by: CGPoint(x: 100, y: 0))
        camera.setZoom(1, anchoredAt: CGPoint(x: 375, y: 235))
        XCTAssertEqual(camera.focus.x, 0.5, accuracy: 0.000001)
        camera.reset(); XCTAssertEqual(camera.focus.x, 0.5, accuracy: 0.000001)
    }
    func testClampLimitsHaveNoDrift() throws {
        var camera = MapCamera(); camera.resize(to: size)
        camera.setZoom(4, anchoredAt: CGPoint(x: 0, y: 0))
        camera.pan(by: CGPoint(x: 100000, y: -100000))
        assertCoverage(camera)
        let focus = camera.focus, rect = camera.fit?.rect
        for _ in 0..<100 { camera.scroll(delta: 10000, precise: true, anchoredAt: CGPoint(x: 700, y: 400)) }
        XCTAssertEqual(camera.focus, focus); XCTAssertEqual(camera.fit?.rect, rect)
        camera.setZoom(1, anchoredAt: CGPoint(x: 700, y: 400))
        let minFocus = camera.focus, minRect = camera.fit?.rect
        for _ in 0..<100 { camera.scroll(delta: -10000, precise: false, anchoredAt: .zero) }
        camera.pan(by: CGPoint(x: 20, y: 20))
        XCTAssertEqual(camera.focus, minFocus); XCTAssertEqual(camera.fit?.rect, minRect)
        assertCoverage(camera)
    }
    func testResizePreservesNormalizedFocusAndRejectsInvalidInput() throws {
        var camera = MapCamera(); camera.resize(to: size)
        camera.setZoom(3, anchoredAt: CGPoint(x: 375, y: 235))
        camera.pan(by: CGPoint(x: 50, y: -40))
        let focus = camera.focus
        camera.resize(to: CGSize(width: 900, height: 500))
        XCTAssertEqual(camera.zoom, 3)
        XCTAssertEqual(camera.focus.x, focus.x, accuracy: 0.000001)
        XCTAssertEqual(camera.focus.y, focus.y, accuracy: 0.000001)
        let rect = camera.fit?.rect, viewport = camera.viewport
        camera.resize(to: CGSize(width: -1, height: 20))
        camera.resize(to: .zero)
        camera.resize(to: CGSize(width: CGFloat.infinity, height: 20))
        camera.setZoom(.nan, anchoredAt: .zero)
        camera.scroll(delta: .infinity, precise: true, anchoredAt: .zero)
        camera.pan(by: CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertEqual(camera.viewport, viewport); XCTAssertEqual(camera.fit?.rect, rect)
        camera.resize(to: CGSize(width: 400, height: 1000)); assertCoverage(camera)
    }
    func testPreciseWheelAccumulatesAndCoarseWheelIsBounded() {
        var camera = MapCamera(); camera.resize(to: size)
        camera.scroll(delta: 0.1, precise: true, anchoredAt: CGPoint(x: 375, y: 235))
        XCTAssertGreaterThan(camera.zoom, 1)
        XCTAssertLessThan(camera.zoom, 1.001)
        camera.scroll(delta: .greatestFiniteMagnitude, precise: false, anchoredAt: .zero)
        XCTAssertEqual(camera.zoom, 4); assertCoverage(camera)
    }
    func testDragThresholdAndInterruptions() {
        var click = MapPointerGesture(start: .zero, windowStrip: false, canPan: true)
        XCTAssertEqual(click.drag(to: CGPoint(x: 2, y: 0)), .none)
        XCTAssertEqual(click.drag(to: CGPoint(x: 4, y: 0)), .pan(CGPoint(x: 4, y: 0)))
        _ = click.drag(to: .zero)
        var atOne = MapPointerGesture(start: .zero, windowStrip: false, canPan: false)
        XCTAssertEqual(atOne.drag(to: CGPoint(x: 10, y: 0)), .none)
        var interrupted = MapPointerGesture(start: .zero, windowStrip: false, canPan: true)
        interrupted.interrupt()
        XCTAssertEqual(interrupted.drag(to: CGPoint(x: 10, y: 0)), .none)
        var strip = MapPointerGesture(start: .zero, windowStrip: true, canPan: true)
        XCTAssertEqual(strip.drag(to: CGPoint(x: 4, y: 0)), .windowDrag)
        XCTAssertEqual(strip.drag(to: CGPoint(x: 8, y: 0)), .none)
    }
    func testPanOvershootReversesImmediately() throws {
        var camera = MapCamera(); camera.resize(to: size)
        camera.setZoom(2, anchoredAt: CGPoint(x: 375, y: 235))
        var press = MapPointerGesture(start: CGPoint(x: 100, y: 100), windowStrip: false, canPan: true)
        if case .pan(let delta) = press.drag(to: CGPoint(x: 2000, y: 100)) { camera.pan(by: delta) }
        XCTAssertEqual(camera.fit?.offset.x, 0)
        if case .pan(let delta) = press.drag(to: CGPoint(x: 1999, y: 101)) { camera.pan(by: delta) }
        XCTAssertEqual(try XCTUnwrap(camera.fit).offset.x, -1, accuracy: 0.000001)
    }
    func testFractionalPinchAtOneAndThreeXPreservesAnchor() throws {
        let anchor = CGPoint(x: 300, y: 220)
        for initialZoom: CGFloat in [1, 3] {
            var camera = MapCamera(); camera.resize(to: size)
            camera.setZoom(initialZoom, anchoredAt: anchor)
            let canonical = try XCTUnwrap(camera.fit?.canonicalPoint(anchor))
            camera.magnify(by: 0.1, anchoredAt: anchor)
            XCTAssertEqual(camera.zoom, initialZoom * 1.1, accuracy: 0.000001)
            let mapped = try XCTUnwrap(camera.fit).viewPoint(canonical)
            XCTAssertEqual(mapped.x, anchor.x, accuracy: 0.000001)
            XCTAssertEqual(mapped.y, anchor.y, accuracy: 0.000001)
            camera.magnify(by: -0.1, anchoredAt: anchor)
            XCTAssertEqual(camera.zoom, max(1, initialZoom * 1.1 * 0.9), accuracy: 0.000001)
            let contracted = try XCTUnwrap(camera.fit).viewPoint(canonical)
            if camera.zoom >= 1.25 {
                XCTAssertEqual(contracted.x, anchor.x, accuracy: 0.000001)
                XCTAssertEqual(contracted.y, anchor.y, accuracy: 0.000001)
            } else {
                XCTAssertEqual(camera.focus.x, 0.5, accuracy: 0.000001)
                XCTAssertEqual(camera.focus.y, 0.5, accuracy: 0.000001)
            }
            assertCoverage(camera)
        }
    }

    func testPinchLimitsAndInvalidFactorsDoNotDrift() throws {
        var camera = MapCamera(); camera.resize(to: size)
        let anchor = CGPoint(x: 300, y: 220)
        camera.setZoom(3, anchoredAt: anchor)
        for fraction: CGFloat in [-1, -2, .nan, .infinity, -.infinity] {
            let fit = camera.fit?.rect, focus = camera.focus
            camera.magnify(by: fraction, anchoredAt: anchor)
            XCTAssertEqual(camera.zoom, 3)
            XCTAssertEqual(camera.fit?.rect, fit); XCTAssertEqual(camera.focus, focus)
        }
        camera.magnify(by: 1, anchoredAt: anchor)
        XCTAssertEqual(camera.zoom, 4); assertCoverage(camera)
        let upper = try XCTUnwrap(camera.fit).rect, upperFocus = camera.focus
        for _ in 0..<20 { camera.magnify(by: 0.1, anchoredAt: .zero) }
        XCTAssertEqual(camera.fit?.rect, upper); XCTAssertEqual(camera.focus, upperFocus)
        camera.magnify(by: -0.9, anchoredAt: anchor)
        XCTAssertEqual(camera.zoom, 1); assertCoverage(camera)
        let lower = try XCTUnwrap(camera.fit).rect, lowerFocus = camera.focus
        for _ in 0..<20 { camera.magnify(by: -0.1, anchoredAt: .zero) }
        XCTAssertEqual(camera.fit?.rect, lower); XCTAssertEqual(camera.focus, lowerFocus)
    }

    @MainActor func testActualChromeExclusionsAndTopStripClassification() {
        let bounds = CGRect(origin: .zero, size: size)
        let exclusions = ChromeLayout.obstacles(size: size, native: NativeChrome.fallback)
        for obstacle in exclusions {
            let point = CGPoint(x: obstacle.midX, y: obstacle.midY)
            XCTAssertEqual(MapInput.region(at: point, in: bounds, exclusions: exclusions), .excluded)
        }
        for y: CGFloat in [0, 16, 31.999] {
            let point = CGPoint(x: 375, y: y)
            XCTAssertEqual(MapInput.region(at: point, in: bounds, exclusions: exclusions), .windowStrip)
        }
        XCTAssertEqual(MapInput.region(at: CGPoint(x: 375, y: 32), in: bounds, exclusions: exclusions), .map)
        XCTAssertEqual(MapInput.region(at: CGPoint(x: 375, y: -1), in: bounds, exclusions: exclusions), .outside)
    }

    func testWheelIntentIgnoresMomentumAndHorizontalOnlyInput() {
        XCTAssertEqual(MapInput.wheelDelta(vertical: 0.125, momentum: []), 0.125)
        XCTAssertEqual(MapInput.wheelDelta(vertical: -2, momentum: []), -2)
        XCTAssertNil(MapInput.wheelDelta(vertical: 0, momentum: []))
        XCTAssertNil(MapInput.wheelDelta(vertical: .nan, momentum: []))
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            XCTAssertNil(MapInput.wheelDelta(vertical: 10, momentum: phase))
        }
    }

    func testWheelSmoothingUsesElapsedTimeAndSettlesExactly() throws {
        func simulate(rate: Double) throws -> CGFloat {
            var motion = MapWheelMotion()
            motion.enqueue(delta: 4, precise: false, zoom: 1, anchor: .zero)
            var zoom: CGFloat = 1
            for _ in 0..<Int(rate * 0.1) { zoom = try XCTUnwrap(motion.advance(from: zoom, elapsed: 1 / rate)) }
            return zoom
        }
        XCTAssertEqual(try simulate(rate: 30), try simulate(rate: 120), accuracy: 0.000001)
        var motion = MapWheelMotion()
        motion.enqueue(delta: 4, precise: false, zoom: 1, anchor: .zero)
        let destination = try XCTUnwrap(motion.target)
        let first = try XCTUnwrap(motion.advance(from: 1, elapsed: 1 / 60))
        XCTAssertGreaterThan(first, 1); XCTAssertLessThan(first, destination)
        XCTAssertEqual(motion.advance(from: first, elapsed: 2), destination)
        XCTAssertNil(motion.target)
    }

    func testSmoothedWheelPreservesAnchorAndCancelsWithoutResidualMotion() throws {
        var camera = MapCamera(); camera.resize(to: size)
        let anchor = CGPoint(x: 375, y: 235)
        let canonical = try XCTUnwrap(camera.fit?.canonicalPoint(anchor))
        var motion = MapWheelMotion()
        motion.enqueue(delta: 4, precise: false, zoom: camera.zoom, anchor: anchor)
        for _ in 0..<30 {
            guard let zoom = motion.advance(from: camera.zoom, elapsed: 1 / 60) else { break }
            camera.setZoom(zoom, anchoredAt: motion.anchor)
            let mapped = try XCTUnwrap(camera.fit).viewPoint(canonical)
            XCTAssertEqual(mapped.x, anchor.x, accuracy: 0.000001)
            XCTAssertEqual(mapped.y, anchor.y, accuracy: 0.000001)
            assertCoverage(camera)
        }
        motion.enqueue(delta: 1, precise: false, zoom: camera.zoom, anchor: anchor)
        _ = motion.advance(from: camera.zoom, elapsed: 1 / 60)
        XCTAssertNotNil(motion.target, "Cancel while motion is still in flight")
        motion.cancel()
        XCTAssertNil(motion.target)
        XCTAssertNil(motion.advance(from: camera.zoom, elapsed: 1))
        motion.enqueue(delta: .greatestFiniteMagnitude, precise: false, zoom: camera.zoom, anchor: anchor)
        XCTAssertEqual(motion.target, 4)
        motion.enqueue(delta: -.greatestFiniteMagnitude, precise: false, zoom: camera.zoom, anchor: anchor)
        XCTAssertEqual(motion.target, 1)
    }

    @MainActor func testSpeedPillFitsMinimumAndLargeWindowsWithoutControlOverlap() {
        for width: CGFloat in [600, 750, 1200, 1800, 2560] {
            for height: CGFloat in [400, 900] {
                let size = CGSize(width: width, height: height)
                let bounds = CGRect(origin: .zero, size: size)
                let speed = ChromeLayout.speed(in: size)
                // The common bottom row uses the existing 8 pt inset; horizontal edges use `edge`.
                XCTAssertTrue(bounds.contains(speed))
                XCTAssertGreaterThanOrEqual(speed.minX, ChromeLayout.edge)
                XCTAssertLessThanOrEqual(speed.maxX, width - ChromeLayout.edge)
                XCTAssertEqual(speed.maxY, height - 8)
                for other in [ChromeLayout.transport(in: size), ChromeLayout.settings(in: size),
                              ChromeLayout.card(in: size), NativeChrome.fallback] {
                    XCTAssertFalse(speed.intersects(other))
                }
                XCTAssertEqual(speed.midY, ChromeLayout.transport(in: size).midY)
                let exclusions = ChromeLayout.obstacles(size: size, native: NativeChrome.fallback)
                XCTAssertEqual(MapInput.region(at: CGPoint(x: speed.midX, y: speed.midY),
                    in: bounds, exclusions: exclusions), .excluded)
            }
        }
    }

}

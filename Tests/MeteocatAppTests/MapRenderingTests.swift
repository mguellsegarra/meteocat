import AppKit
import XCTest
import MeteocatCore
@testable import MeteocatApp

/// Detached views and in-memory raster only. No application, window, settings store or service.
@MainActor
final class MapRenderingTests: XCTestCase {
    private let size = CGSize(width: 680, height: 380)

    func testCityNameRemainsVisibleAtPersonalMarker() throws {
        let point = CGPoint(x: 300, y: 180)
        let measured = CGSize(width: 32, height: 14)
        let labels = LabelPlacer.place([(name: "Valls", point: point)], pin: point,
                                      in: size, obstacles: []) { _ in measured }
        let label = try XCTUnwrap(labels.first)
        let origin = try XCTUnwrap(label.textOrigin)
        XCTAssertEqual(label.dot, point)
        XCTAssertFalse(CGRect(origin: origin, size: measured)
            .intersects(PersonalPointMarker.obstacle(at: point, in: size)))
    }

    func testCursorEventsFollowZoomDragAndExcludeControls() throws {
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        var cursors: [NSCursor] = []
        let canvas = MapCanvas(geography: nil, projection: projection,
                               shouldReduceMotion: { true }, setCursor: { cursors.append($0) })
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layout()
        canvas.updateTrackingAreas()
        XCTAssertTrue(canvas.trackingAreas.contains { $0.options.contains(.cursorUpdate) && $0.options.contains(.mouseMoved) })
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let point = CGPoint(x: 340, y: 190)
        canvas.mouseMoved(with: try event(.mouseMoved, point))
        XCTAssertTrue(cursors.last === NSCursor.arrow)
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: point, vertical: 100))
        canvas.cursorUpdate(with: try event(.mouseMoved, point))
        XCTAssertTrue(cursors.last === NSCursor.openHand)
        canvas.mouseDown(with: try event(.leftMouseDown, point))
        canvas.cursorUpdate(with: try event(.mouseMoved, point))
        XCTAssertTrue(cursors.last === NSCursor.closedHand)
        canvas.mouseUp(with: try event(.leftMouseUp, point))
        XCTAssertTrue(cursors.last === NSCursor.openHand)
        canvas.dragExclusions = [CGRect(x: 320, y: 170, width: 40, height: 40)]
        let count = cursors.count
        canvas.mouseMoved(with: try event(.mouseMoved, point))
        canvas.cursorUpdate(with: try event(.mouseMoved, CGPoint(x: 340, y: 16)))
        XCTAssertEqual(cursors.count, count, "Map cursor must not override controls or the window drag strip")
        canvas.dragExclusions = []
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: point, vertical: -10000))
        canvas.cursorUpdate(with: try event(.mouseMoved, point))
        XCTAssertTrue(cursors.last === NSCursor.arrow)
    }

    func testLightPaletteChangesBaseWithoutChangingSharedFit() throws {
        let geography = try Geography(directory: MeteocatResources.geographyDirectory, nativeDark: true)
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let canvas = MapCanvas(geography: geography, projection: projection)
        canvas.frame = CGRect(origin: .zero, size: size); canvas.layout()
        let fit = try XCTUnwrap(canvas.baseView.fit)
        let dark = try bitmap(drawing: canvas.baseView)
        canvas.setDarkAppearance(false)
        XCTAssertFalse(canvas.baseView.dark || canvas.boundariesView.dark)
        XCTAssertFalse(canvas.labelsView.dark)
        let light = try bitmap(drawing: canvas.baseView)
        let seaPoint = CGPoint(x: 650, y: 350)
        let darkPixel = try pixel(dark, at: seaPoint), lightPixel = try pixel(light, at: seaPoint)
        XCTAssertGreaterThan(Int(lightPixel[0]) + Int(lightPixel[1]) + Int(lightPixel[2]),
                             Int(darkPixel[0]) + Int(darkPixel[1]) + Int(darkPixel[2]) + 300)
        XCTAssertEqual(canvas.baseView.fit?.rect, fit.rect)
        XCTAssertEqual(canvas.boundariesView.fit?.rect, fit.rect)
        XCTAssertEqual(canvas.weatherView.fit?.rect, fit.rect)
        canvas.setDarkAppearance(true)
        XCTAssertEqual(try pixel(bitmap(drawing: canvas.baseView), at: seaPoint), darkPixel)
    }
    private func bitmap(drawing view: NSView) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 680, height: 380, bitsPerComponent: 8,
            bytesPerRow: 680 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        // Same top-left/down coordinate system AppKit supplies to these flipped views.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        return context
    }

    private func pixel(_ context: CGContext, at point: CGPoint) throws -> [UInt8] {
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let index = Int(point.y) * context.bytesPerRow + Int(point.x) * 4
        return Array(UnsafeBufferPointer(start: data + index, count: 4))
    }

    func testNorthSouthWeatherMarkersFollowSharedFitAtShiftedCrops() throws {
        let north = CGPoint(x: 220, y: 135), south = CGPoint(x: 400, y: 245)
        var bytes = Data(count: 680 * 380 * 4)
        for (point, color) in [(north, [UInt8(255), 0, 0, 255]), (south, [UInt8(0), 0, 255, 255])] {
            for y in Int(point.y) - 8...Int(point.y) + 8 {
                for x in Int(point.x) - 8...Int(point.x) + 8 {
                    bytes.replaceSubrange((y * 680 + x) * 4..<(y * 680 + x) * 4 + 4, with: color)
                }
            }
        }
        let view = WeatherView(frame: CGRect(origin: .zero, size: size))
        view.show(WeatherPresentation(serial: 1, endpoint: try RGBAImage(width: 680, height: 380, bytes: bytes), blend: nil))
        for offset in [CGPoint(x: -80, y: -60), CGPoint(x: -160, y: -150)] {
            let fit = MapFit(scale: 1.5, offset: offset,
                rect: CGRect(origin: offset, size: CGSize(width: 1020, height: 570)))
            view.fit = fit
            let context = try bitmap(drawing: view)
            let northPixel = try pixel(context, at: fit.viewPoint(north))
            let southPixel = try pixel(context, at: fit.viewPoint(south))
            XCTAssertGreaterThan(northPixel[0], 240); XCTAssertLessThan(northPixel[2], 10)
            XCTAssertGreaterThan(southPixel[2], 240); XCTAssertLessThan(southPixel[0], 10)
            XCTAssertEqual(try pixel(context, at: CGPoint(x: 10, y: 10))[3], 0)
        }
    }

    func testActualCityDotAndPinProjectionAndViewportSizes() throws {
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let cityCanonical = CGPoint(x: 300, y: 180), pinCanonical = CGPoint(x: 380, y: 220)
        let city = City(id: "probe", name: "Probe", point: try projection.unproject(cityCanonical))
        let settings = UserSettings(cities: [city], pin: try projection.unproject(pinCanonical))
        let view = LabelsView(projection: projection)
        view.frame = CGRect(origin: .zero, size: size)
        // Reserve all text candidates, leaving only the actual dot and pin drawing paths.
        view.update(labels: MapLabels(settings), obstacles: [view.bounds])
        for zoom: CGFloat in [1, 3] {
            let offset = CGPoint(x: size.width / 2 - 340 * zoom, y: size.height / 2 - 190 * zoom)
            let fit = MapFit(scale: zoom, offset: offset,
                rect: CGRect(origin: offset, size: CGSize(width: 680 * zoom, height: 380 * zoom)))
            view.setFit(fit)
            let context = try bitmap(drawing: view)
            let dot = fit.viewPoint(cityCanonical), pin = fit.viewPoint(pinCanonical)
            let dotPixel = try pixel(context, at: dot), pinPixel = try pixel(context, at: pin)
            XCTAssertGreaterThan(dotPixel[3], 200, "City dot must land on the projected point")
            XCTAssertGreaterThan(pinPixel[2], pinPixel[0], "Pin centre must be blue at the projected point")
            XCTAssertGreaterThan(try pixel(context, at: CGPoint(x: dot.x + 1, y: dot.y))[3], 100)
            XCTAssertEqual(try pixel(context, at: CGPoint(x: dot.x + 5, y: dot.y))[3], 0, "Dot remains viewport-sized")
            let ring = try pixel(context, at: CGPoint(x: pin.x + 6, y: pin.y))
            XCTAssertGreaterThan(ring[0], 200); XCTAssertGreaterThan(ring[1], 200)
            XCTAssertEqual(try pixel(context, at: CGPoint(x: pin.x + 20, y: pin.y))[3], 0, "Pin remains viewport-sized")
        }
    }

    func testDetachedCanvasTopStripDoesNotPan() throws {
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let canvas = MapCanvas(geography: nil, projection: projection, shouldReduceMotion: { true })
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layout()
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let start = CGPoint(x: 340, y: 16)
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: CGPoint(x: 375, y: 235), vertical: 100))
        canvas.mouseDown(with: try event(.leftMouseDown, at: start))
        canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 343, y: 16)))
        let fit = canvas.baseView.fit?.rect
        canvas.mouseDown(with: try event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 344, y: 16)))
        canvas.mouseUp(with: try event(.leftMouseUp, at: start))
        XCTAssertEqual(canvas.baseView.fit?.rect, fit, "Strip drag does not pan the camera")
        let mapStart = CGPoint(x: 340, y: 100)
        canvas.mouseDown(with: try event(.leftMouseDown, at: mapStart))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 360, y: 110)))
        canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 360, y: 110)))
        XCTAssertNotEqual(canvas.baseView.fit?.rect, fit, "A zoomed map drag must pan as a positive control")
    }

    private func wheelEvent(on canvas: MapCanvas, at anchor: CGPoint, vertical: Int32 = 10,
                            horizontal: Int32 = 0, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0))
        cg.location = anchor
        // CGEventTypes.h uses CGScrollPhase and CGMomentumScrollPhase, not NSEvent's raw bits.
        let scrollCode: Int64 = phase == .began ? 1 : phase == .changed ? 2 : 0
        let momentumCode: Int64 = momentum == .began ? 1 : momentum == .changed ? 2 : momentum == .ended ? 3 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollCode)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumCode)
        // CGEvent is global y-down; a windowless NSEvent is y-up. Calibrate that conversion
        // using the event itself, without a screen lookup, application or window.
        let initial = try XCTUnwrap(NSEvent(cgEvent: cg))
        let target = canvas.convert(anchor, to: nil)
        cg.location.y += initial.locationInWindow.y - target.y
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(canvas.convert(event.locationInWindow, from: nil), anchor)
        XCTAssertEqual(event.phase, phase); XCTAssertEqual(event.momentumPhase, momentum)
        return event
    }

    func testDetachedCanvasWheelPhasesTopStripAndRejections() throws {
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let canvas = MapCanvas(geography: nil, projection: projection, shouldReduceMotion: { true })
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layout()
        let anchor = CGPoint(x: 340, y: 16)
        for phase: NSEvent.Phase in [[], .began, .changed] {
            let event = try wheelEvent(on: canvas, at: anchor, phase: phase)
            let before = try XCTUnwrap(canvas.baseView.fit).scale
            canvas.scrollWheel(with: event)
            XCTAssertGreaterThan(try XCTUnwrap(canvas.baseView.fit).scale, before)
            XCTAssertEqual(canvas.baseView.fit?.rect, canvas.weatherView.fit?.rect)
            XCTAssertEqual(canvas.baseView.fit?.rect, canvas.boundariesView.fit?.rect)
        }
        let unchanged = canvas.baseView.fit?.rect
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: anchor, vertical: 0, horizontal: 10))
        XCTAssertEqual(canvas.baseView.fit?.rect, unchanged, "Horizontal-only scroll does not zoom")
        for momentum: NSEvent.Phase in [.began, .changed, .ended] {
            canvas.scrollWheel(with: try wheelEvent(on: canvas, at: anchor, momentum: momentum))
            XCTAssertEqual(canvas.baseView.fit?.rect, unchanged, "Momentum does not zoom")
        }
        canvas.dragExclusions = [CGRect(x: 320, y: 0, width: 40, height: 32)]
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: anchor))
        XCTAssertGreaterThan(try XCTUnwrap(canvas.baseView.fit).rect.width, try XCTUnwrap(unchanged).width,
            "Label/drag reservations must not create zoom dead bands; overlay controls own hit routing")
        let afterReservation = canvas.baseView.fit?.rect
        canvas.scrollWheel(with: try wheelEvent(on: canvas, at: CGPoint(x: -5, y: 16)))
        XCTAssertEqual(canvas.baseView.fit?.rect, afterReservation, "Outside input does not zoom")
        XCTAssertFalse(canvas.acceptsFirstResponder, "Map input must not take over the existing key route")
    }
}

import Foundation
import CoreGraphics
import MeteocatCore

/// A bounded wheel destination, approached in log space using elapsed time rather than callback count.
struct MapWheelMotion {
    private(set) var target: CGFloat?
    private(set) var anchor: CGPoint = .zero

    mutating func enqueue(delta: CGFloat, precise: Bool, zoom: CGFloat, anchor: CGPoint) {
        guard delta.isFinite, zoom.isFinite, zoom > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        let exponent = min(8, max(-8, delta * (precise ? 0.005 : 0.12)))
        target = exp(min(log(4), max(0, log(target ?? zoom) + exponent)))
        self.anchor = anchor
    }

    mutating func advance(from zoom: CGFloat, elapsed: TimeInterval) -> CGFloat? {
        guard let target, zoom.isFinite, zoom > 0, elapsed.isFinite, elapsed > 0 else { return nil }
        let distance = log(target / zoom)
        let next = exp(log(zoom) + distance * (1 - exp(-elapsed / 0.07)))
        if abs(log(target / next)) < 0.0005 {
            self.target = nil
            return target
        }
        return next
    }

    mutating func cancel() { target = nil }
}

/// Canonical top-left focus; offsets are always derived, never accumulated separately.
struct MapCamera {
    private(set) var zoom: CGFloat = 1
    private(set) var focus = CGPoint(x: 0.5, y: 0.5)
    private(set) var viewport: CGSize = .zero
    private(set) var fit: MapFit?

    mutating func resize(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let scale = max(size.width / 680, size.height / 380) * zoom
        guard scale.isFinite, scale > 0, (scale * 680).isFinite, (scale * 380).isFinite else { return }
        viewport = size
        publish(offset: CGPoint(x: size.width / 2 - scale * 680 * focus.x,
                                y: size.height / 2 - scale * 380 * focus.y), scale: scale)
    }

    mutating func setZoom(_ value: CGFloat, anchoredAt anchor: CGPoint) {
        guard value.isFinite, anchor.x.isFinite, anchor.y.isFinite, let fit else { return }
        let next = min(4, max(1, value))
        guard next != zoom else { return } // Bounded input must not drift focus.
        let q = CGPoint(x: (anchor.x - fit.offset.x) / fit.scale, y: (anchor.y - fit.offset.y) / fit.scale)
        let scale = max(viewport.width / 680, viewport.height / 380) * next
        guard scale.isFinite, scale > 0, (scale * 680).isFinite, (scale * 380).isFinite else { return }
        var offset = CGPoint(x: anchor.x - q.x * scale, y: anchor.y - q.y * scale)
        // Release the panned crop gradually near the minimum, including the spare
        // cover axis. At 1x the original centered framing is restored exactly.
        if next < zoom, next < 1.25 {
            let retention = cropWeight(next) / cropWeight(zoom)
            let center = CGPoint(x: (viewport.width - 680 * scale) / 2,
                                 y: (viewport.height - 380 * scale) / 2)
            offset = CGPoint(x: center.x + (offset.x - center.x) * retention,
                             y: center.y + (offset.y - center.y) * retention)
        }
        guard offset.x.isFinite, offset.y.isFinite else { return }
        zoom = next
        publish(offset: offset, scale: scale)
    }

    mutating func scroll(delta: CGFloat, precise: Bool, anchoredAt anchor: CGPoint) {
        guard delta.isFinite else { return }
        let exponent = min(8, max(-8, delta * (precise ? 0.005 : 0.12)))
        setZoom(zoom * exp(exponent), anchoredAt: anchor)
    }

    /// AppKit magnification is a fractional change, independent of current zoom.
    mutating func magnify(by fraction: CGFloat, anchoredAt anchor: CGPoint) {
        let factor = 1 + fraction
        guard factor.isFinite, factor > 0 else { return }
        setZoom(zoom * factor, anchoredAt: anchor)
    }

    mutating func pan(by delta: CGPoint) {
        guard zoom > 1, delta.x.isFinite, delta.y.isFinite, let fit else { return }
        var offset = CGPoint(x: fit.offset.x + delta.x, y: fit.offset.y + delta.y)
        if zoom < 1.25 {
            // Do not create a large new crop displacement inside the recentering
            // band: wheel settling may finish in a single frame this close to 1x.
            let weight = cropWeight(zoom)
            let center = CGPoint(x: (viewport.width - fit.rect.width) / 2,
                                 y: (viewport.height - fit.rect.height) / 2)
            let allowance = CGPoint(x: abs(center.x) * weight, y: abs(center.y) * weight)
            // An anchored zoom-in may already exceed this band. Preserve that
            // existing offset, allowing movement inward without snapping on drag.
            offset.x = min(max(center.x + allowance.x, fit.offset.x),
                           max(min(center.x - allowance.x, fit.offset.x), offset.x))
            offset.y = min(max(center.y + allowance.y, fit.offset.y),
                           max(min(center.y - allowance.y, fit.offset.y), offset.y))
        }
        publish(offset: offset, scale: fit.scale)
    }

    mutating func reset() {
        zoom = 1
        focus = CGPoint(x: 0.5, y: 0.5)
        resize(to: viewport)
    }

    private func cropWeight(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - 1) / 0.25))
        return t * t * (3 - 2 * t)
    }

    private mutating func publish(offset: CGPoint, scale: CGFloat) {
        let extent = CGSize(width: 680 * scale, height: 380 * scale)
        let origin = CGPoint(x: min(0, max(viewport.width - extent.width, offset.x)),
                             y: min(0, max(viewport.height - extent.height, offset.y)))
        focus = CGPoint(x: (viewport.width / 2 - origin.x) / extent.width,
                        y: (viewport.height / 2 - origin.y) / extent.height)
        fit = MapFit(scale: scale, offset: origin, rect: CGRect(origin: origin, size: extent))
    }
}

/// One press owns its original region. Movement consumption survives returning to the origin.
struct MapPointerGesture {
    enum Action: Equatable { case none, pan(CGPoint), windowDrag }
    private let start: CGPoint
    private var previous: CGPoint
    private let windowStrip: Bool
    private let canPan: Bool
    private var moved = false
    private var interrupted = false

    init(start: CGPoint, windowStrip: Bool, canPan: Bool) {
        self.start = start; previous = start; self.windowStrip = windowStrip; self.canPan = canPan
    }

    mutating func interrupt() { interrupted = true }

    mutating func drag(to point: CGPoint) -> Action {
        guard !interrupted else { return .none }
        let wasMoved = moved
        moved = moved || hypot(point.x - start.x, point.y - start.y) >= 4
        guard moved else { return .none }
        let delta = CGPoint(x: point.x - previous.x, y: point.y - previous.y)
        previous = point // Advance even when camera clamps: edge reversal has no dead zone.
        if windowStrip { interrupted = true; return .windowDrag }
        guard canPan else { return .none }
        // The threshold-crossing event includes the motion withheld while it was a possible click.
        return .pan(wasMoved ? delta : CGPoint(x: point.x - start.x, y: point.y - start.y))
    }

}

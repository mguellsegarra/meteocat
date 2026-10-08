import AppKit
import SwiftUI
import MeteocatCore

struct MapLabels: Equatable {
    var cities: [City]
    var visible: Bool
    var pin: GeoPoint?
    init(_ settings: UserSettings) { cities = settings.cities; visible = settings.labelsVisible; pin = settings.pin }
}

struct MapView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let geography: Geography?
    let projection: MapProjection
    let weather: WeatherPresentation?
    let labels: MapLabels
    let obstacles: [CGRect]

    func makeNSView(context: Context) -> MapCanvas { MapCanvas(geography: geography, projection: projection) }
    func updateNSView(_ view: MapCanvas, context: Context) {
        view.setDarkAppearance(colorScheme == .dark)
        view.weatherView.show(weather)
        view.dragExclusions = obstacles
        view.labelsView.update(labels: labels, obstacles: obstacles)
    }
}

/// Input ownership in viewport points; controls above the canvas keep their native hit routing.
enum MapInput {
    enum Region: Equatable { case outside, excluded, windowStrip, map }

    static func region(at point: CGPoint, in bounds: CGRect, exclusions: [CGRect]) -> Region {
        guard bounds.contains(point) else { return .outside }
        guard !exclusions.contains(where: { $0.contains(point) }) else { return .excluded }
        return point.y >= 0 && point.y < 32 ? .windowStrip : .map
    }

    /// No regular phase requirement: physical wheels have phase-less events too.
    /// Horizontal-only input has no vertical zoom intent; momentum never changes the camera.
    static func wheelDelta(vertical: CGFloat, momentum: NSEvent.Phase) -> CGFloat? {
        guard momentum.isEmpty, vertical.isFinite, vertical != 0 else { return nil }
        return vertical
    }
}

/// Flipped container, back to front: static base, weather surface, static boundaries, labels.
/// Only a press beginning in the free top strip can drag the window. Map clicks do not control playback.
final class MapCanvas: NSView {
    let baseView: BaseMapView
    let weatherView = WeatherView()
    let boundariesView: BoundariesView
    let labelsView: LabelsView
    private let shouldReduceMotion: () -> Bool
    private var camera = MapCamera()
    private var wheelMotion = MapWheelMotion()
    private var wheelLink: CADisplayLink?
    private var wheelLastTime: CFTimeInterval = 0
    private lazy var wheelTarget = WheelDisplayTarget(self)
    private var gesture: MapPointerGesture?
    private var panCursorActive = false
    private var cursorAllowsPan = false
    private var cursorTracking: NSTrackingArea?
    private let setCursor: (NSCursor) -> Void
    func setDarkAppearance(_ dark: Bool) {
        baseView.dark = dark; boundariesView.dark = dark; labelsView.dark = dark
    }
    var dragExclusions: [CGRect] = [] {
        didSet { if oldValue != dragExclusions { refreshCursorUnderPointer() } }
    }

    init(geography: Geography?, projection: MapProjection,
         shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         setCursor: @escaping (NSCursor) -> Void = { $0.set() }) {
        self.shouldReduceMotion = shouldReduceMotion
        self.setCursor = setCursor
        baseView = BaseMapView(geography: geography)
        boundariesView = BoundariesView(geography: geography)
        labelsView = LabelsView(projection: projection)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [baseView, weatherView, boundariesView, labelsView] as [NSView] { view.wantsLayer = true; addSubview(view) }
        // Static surfaces: the layer bitmap is reused and only redrawn when camera, size or backing scale changes.
        for view in [baseView, boundariesView] as [NSView] { view.layerContentsRedrawPolicy = .duringViewResize }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        guard bounds.size != camera.viewport else { return }
        stopWheelMotion()
        camera.resize(to: bounds.size)
        guard camera.viewport == bounds.size else { return }
        publishFit()
    }

    private func publishFit() {
        guard let fit = camera.fit else { return }
        guard baseView.fit?.rect != fit.rect || baseView.fit?.scale != fit.scale || baseView.frame != bounds else { return }
        // Publish all four transforms in one main-thread transaction before invalidation.
        for view in subviews where view.frame != bounds { view.frame = bounds }
        baseView.fit = fit; weatherView.fit = fit; boundariesView.fit = fit
        labelsView.setFit(fit)
        baseView.needsDisplay = true; weatherView.needsDisplay = true; boundariesView.needsDisplay = true
        if cursorAllowsPan != (camera.zoom > 1) {
            cursorAllowsPan = camera.zoom > 1
            refreshCursorUnderPointer()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard applyMapCursor(at: point) else { super.cursorUpdate(with: event); return }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard applyMapCursor(at: point) else { super.mouseMoved(with: event); return }
    }

    @discardableResult private func applyMapCursor(at point: CGPoint) -> Bool {
        if let content = window?.contentView {
            guard content.hitTest(convert(point, to: content.superview)) === self else { return false }
        }
        guard MapInput.region(at: point, in: bounds, exclusions: dragExclusions) == .map else { return false }
        setCursor(camera.zoom > 1 ? (panCursorActive ? .closedHand : .openHand) : .arrow)
        return true
    }

    private func refreshCursorUnderPointer() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
              let content = window.contentView else { return }
        let point = window.mouseLocationOutsideOfEventStream
        guard content.hitTest(content.superview?.convert(point, from: nil) ?? point) === self else { return }
        applyMapCursor(at: convert(point, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        stopWheelMotion()
        let point = convert(event.locationInWindow, from: nil)
        let region = MapInput.region(at: point, in: bounds, exclusions: dragExclusions)
        gesture = MapPointerGesture(start: point, windowStrip: region == .windowStrip, canPan: camera.zoom > 1)
        panCursorActive = region == .map && camera.zoom > 1
        if panCursorActive { setCursor(.closedHand) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard var gesture else { return }
        let action = gesture.drag(to: convert(event.locationInWindow, from: nil))
        self.gesture = gesture
        switch action {
        case .none: break
        case .pan(let delta): setCursor(.closedHand); camera.pan(by: delta); publishFit()
        case .windowDrag:
            self.gesture = nil // performDrag may consume mouse-up synchronously.
            window?.performDrag(with: event)
        }
    }
    override func mouseUp(with event: NSEvent) {
        endPointerInteraction()
        let point = convert(event.locationInWindow, from: nil)
        if camera.zoom > 1, MapInput.region(at: point, in: bounds, exclusions: dragExclusions) == .map {
            setCursor(.openHand)
        } else { setCursor(.arrow) }
    }
    private func endPointerInteraction() {
        gesture = nil; panCursorActive = false
        refreshCursorUnderPointer()
    }
    override func viewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willMiniaturizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillMinimize),
                name: NSWindow.willMiniaturizeNotification, object: window)
        }
        if window == nil { endPointerInteraction(); stopWheelMotion() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        endPointerInteraction()
        stopWheelMotion()
    }
    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !window.isVisible || !window.occlusionState.contains(.visible) else { return }
        endPointerInteraction()
        stopWheelMotion()
    }
    @objc private func windowWillMinimize(_ notification: Notification) { endPointerInteraction(); stopWheelMotion() }
    override func scrollWheel(with event: NSEvent) {
        gesture?.interrupt()
        let anchor = convert(event.locationInWindow, from: nil)
        guard bounds.contains(anchor),
              let delta = MapInput.wheelDelta(vertical: event.scrollingDeltaY, momentum: event.momentumPhase) else { return }
        if shouldReduceMotion() {
            stopWheelMotion()
            camera.scroll(delta: delta, precise: event.hasPreciseScrollingDeltas, anchoredAt: anchor)
            publishFit()
            return
        }
        wheelMotion.enqueue(delta: delta, precise: event.hasPreciseScrollingDeltas, zoom: camera.zoom, anchor: anchor)
        if wheelLink == nil {
            wheelLastTime = CACurrentMediaTime()
            let link = displayLink(target: wheelTarget, selector: #selector(WheelDisplayTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            wheelLink = link
        }
    }
    override func magnify(with event: NSEvent) {
        stopWheelMotion()
        gesture?.interrupt()
        let anchor = convert(event.locationInWindow, from: nil)
        guard bounds.contains(anchor) else { return }
        camera.magnify(by: event.magnification, anchoredAt: anchor)
        publishFit()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        gesture?.interrupt()
        let menu = NSMenu()
        let reset = NSMenuItem(title: L10n.text("Restableix la vista del mapa"), action: #selector(resetCamera), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        for title in [L10n.text("Fes servir la rodeta o pessiga per ampliar; arrossega per moure el mapa."),
                      L10n.text("El zoom amplia les dades disponibles; no afegeix detall al radar.")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
    @objc private func resetCamera() {
        stopWheelMotion()
        gesture?.interrupt()
        camera.reset()
        publishFit()
    }

    private func advanceWheelMotion() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { stopWheelMotion(); return }
        let now = CACurrentMediaTime()
        let elapsed = now - wheelLastTime
        wheelLastTime = now
        if shouldReduceMotion() {
            if let target = wheelMotion.target { camera.setZoom(target, anchoredAt: wheelMotion.anchor); publishFit() }
            stopWheelMotion()
            return
        }
        if let zoom = wheelMotion.advance(from: camera.zoom, elapsed: elapsed) {
            camera.setZoom(zoom, anchoredAt: wheelMotion.anchor)
            publishFit()
        }
        if wheelMotion.target == nil { stopWheelMotion() }
    }

    private func stopWheelMotion() {
        wheelLink?.invalidate(); wheelLink = nil
        wheelMotion.cancel()
    }

    /// The display link must not retain its canvas while waiting for a hidden window to redraw.
    private final class WheelDisplayTarget: NSObject {
        weak var canvas: MapCanvas?
        init(_ canvas: MapCanvas) { self.canvas = canvas }
        @objc func tick(_ link: CADisplayLink) {
            guard let canvas else { link.invalidate(); return }
            canvas.advanceWheelMotion()
        }
    }

}

/// Sea, context land and Catalunya fills, under the weather. Drawn at backing scale and cached by its layer:
/// redrawn on camera, resize or backing-scale change, never per playback step.
final class BaseMapView: NSView {
    var dark = true { didSet { if oldValue != dark { needsDisplay = true } } }
    var fit: MapFit?
    private let geography: Geography?
    init(geography: Geography?) {
        self.geography = geography
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true } // Geography requires a top-left, y-down context; this is the only conversion.
    override func viewDidChangeBackingProperties() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let fit, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clip(to: bounds)
        let hex: UInt32 = dark ? 0x0F1114 : 0xDCEAF1
        context.setFillColor(CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                     green: CGFloat((hex >> 8) & 255) / 255,
                                     blue: CGFloat(hex & 255) / 255, alpha: 1))
        context.fill(bounds)
        geography?.drawUnderlay(in: context, fit: fit, dark: dark)
    }
}

/// Comarca, country and outline strokes on a transparent surface above the opaque weather, below the labels.
/// Same cover fit and the same flipped context as the base, so there is no second geography flip. Static: cached
/// by its layer and redrawn on camera, resize or backing-scale change.
final class BoundariesView: NSView {
    var dark = true { didSet { if oldValue != dark { needsDisplay = true } } }
    var fit: MapFit?
    private let geography: Geography?
    init(geography: Geography?) {
        self.geography = geography
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    override func viewDidChangeBackingProperties() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let fit, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clip(to: bounds)
        geography?.drawBoundaries(in: context, fit: fit, dark: dark)
    }
}

/// The single weather surface. Endpoints draw the original straight-RGBA frame; an eligible step draws one
/// premultiplied linear blend per display refresh (at most 60 Hz) for the step duration, then the destination endpoint.
/// Progress comes from the shared `MediaTransition` and the media clock, not the callback count, so a late callback never
/// stretches the blend and the clock and knob stay at the same p.
final class WeatherView: NSView {
    var fit: MapFit?
    private var presentation: WeatherPresentation?
    private var endpointImage: CGImage?
    private var drawnImage: CGImage?
    private var link: CADisplayLink?

    override var isFlipped: Bool { true }

    func show(_ next: WeatherPresentation?) {
        guard next?.serial != presentation?.serial else { return }
        presentation = next
        endpointImage = next.flatMap { Self.image($0.endpoint.bytes, $0.endpoint, premultiplied: false) }
        if next?.blend != nil {
            if link == nil {
                let link = displayLink(target: self, selector: #selector(tick))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            renderBlend()
        } else {
            stopLink()
            drawnImage = endpointImage
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() { if window == nil { stopLink(); drawnImage = endpointImage } }

    @objc private func tick(_ link: CADisplayLink) { renderBlend(); needsDisplay = true }

    private func renderBlend() {
        guard let presentation, let blend = presentation.blend else { stopLink(); return }
        // The same descriptor and clock as the presentation time and the knob; linear, clamped and finite.
        let progress = blend.transition.progress(at: CACurrentMediaTime())
        guard progress < 1 else { stopLink(); drawnImage = endpointImage; return }
        let to = presentation.endpoint
        drawnImage = (try? WeatherRasterizer.blendedPremultiplied(from: blend.from, to: to, progress: progress))
            .flatMap { Self.image($0, to, premultiplied: true) } ?? endpointImage
    }

    private func stopLink() { link?.invalidate(); link = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let fit, let image = drawnImage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clip(to: bounds)
        let rect = fit.rect
        // Display-only bilinear softening; the source raster itself is untouched.
        context.interpolationQuality = .medium
        // CGContext.draw expects y-up; undo this view's flip exactly once so row 0 (north) lands at the top.
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
    }

    private static func image(_ bytes: Data, _ size: RGBAImage, premultiplied: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Native SF city labels, dots and the manual pin. Never animated; re-placed on camera, resize, obstacle or settings changes.
final class LabelsView: NSView {
    var dark = true { didSet { if oldValue != dark { needsDisplay = true } } }
    private let projection: MapProjection
    private var labels: MapLabels?
    private var obstacles: [CGRect] = []
    private var placed: [LabelPlacer.Placed] = []
    private var pinPoint: CGPoint?
    private var fit: MapFit?

    /// Subdued neutral gray, quieter than the time and controls; a light dark halo keeps it legible over radar colours.
    private static let textColor = NSColor(srgbRed: 0.63, green: 0.65, blue: 0.68, alpha: 0.9)
    private static let haloA: NSShadow = { let s = NSShadow(); s.shadowBlurRadius = 2.5; s.shadowOffset = .zero; s.shadowColor = .black.withAlphaComponent(0.7); return s }()
    private static let haloB: NSShadow = { let s = NSShadow(); s.shadowBlurRadius = 1; s.shadowOffset = .zero; s.shadowColor = .black.withAlphaComponent(0.6); return s }()

    init(projection: MapProjection) { self.projection = projection; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }

    func update(labels: MapLabels, obstacles: [CGRect]) {
        guard labels != self.labels || obstacles != self.obstacles else { return }
        self.labels = labels; self.obstacles = obstacles
        replace()
    }

    func setFit(_ fit: MapFit) {
        guard self.fit?.scale != fit.scale || self.fit?.offset != fit.offset || self.fit?.rect != fit.rect else { return }
        self.fit = fit
        replace()
    }

    private func replace() {
        guard let labels, let fit, bounds.width > 0 else { placed = []; pinPoint = nil; needsDisplay = true; return }
        func viewPoint(_ geo: GeoPoint) -> CGPoint? { (try? projection.project(geo)).map(fit.viewPoint) }
        pinPoint = labels.pin.flatMap(viewPoint).flatMap { bounds.contains($0) ? $0 : nil }
        let cities = labels.visible ? labels.cities.filter(\.visible).compactMap { city in
            viewPoint(city.point).flatMap { bounds.contains($0) ? (city.name, $0) : nil }
        } : []
        placed = LabelPlacer.place(cities, pin: pinPoint, in: bounds.size, obstacles: obstacles) { name in
            (name as NSString).size(withAttributes: [.font: LabelPlacer.font])
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let textColor = dark ? Self.textColor : NSColor(srgbRed: 0.28, green: 0.32, blue: 0.36, alpha: 1)
        let lightHalo = NSShadow()
        lightHalo.shadowColor = NSColor.white.withAlphaComponent(0.9)
        lightHalo.shadowBlurRadius = 2; lightHalo.shadowOffset = .zero
        let halos = dark ? [Self.haloA, Self.haloB] : [lightHalo]
        let dotFill = dark ? NSColor(white: 0.66, alpha: 0.9) : textColor
        let dotRing = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.55)
        for label in placed {
            let dot = NSBezierPath(ovalIn: CGRect(x: label.dot.x - 2, y: label.dot.y - 2, width: 4, height: 4))
            dotFill.setFill(); dot.fill()
            dotRing.setStroke(); dot.lineWidth = 0.75; dot.stroke()
            guard let origin = label.textOrigin else { continue }
            // Two shadow passes, no stroke, so SF glyph shapes stay crisp.
            for halo in halos {
                (label.name as NSString).draw(at: origin, withAttributes: [.font: LabelPlacer.font, .foregroundColor: textColor, .shadow: halo])
            }
        }
        if let pinPoint {
            let scale = PersonalPointMarker.scale(in: bounds.size)
            NSGraphicsContext.saveGraphicsState()
            let halo = NSBezierPath(ovalIn: CGRect(x: pinPoint.x - 14 * scale, y: pinPoint.y - 14 * scale,
                                                 width: 28 * scale, height: 28 * scale))
            NSColor.systemBlue.withAlphaComponent(0.22).setFill(); halo.fill()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 3 * scale; shadow.shadowOffset = .zero; shadow.set()
            let ring = NSBezierPath(ovalIn: CGRect(x: pinPoint.x - 7 * scale, y: pinPoint.y - 7 * scale,
                                                 width: 14 * scale, height: 14 * scale))
            NSColor.white.setFill(); ring.fill()
            NSShadow().set()
            let dot = NSBezierPath(ovalIn: CGRect(x: pinPoint.x - 5 * scale, y: pinPoint.y - 5 * scale,
                                                width: 10 * scale, height: 10 * scale))
            NSColor.systemBlue.setFill(); dot.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

enum PersonalPointMarker {
    static func scale(in size: CGSize) -> CGFloat { min(1.35, max(1, 1 + 0.25 * (size.width / 750 - 1))) }
    static func obstacle(at point: CGPoint, in size: CGSize) -> CGRect {
        let radius = 16 * scale(in: size)
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Greedy placement: priority cities first, then settings order; right, left, above, below.
@MainActor enum LabelPlacer {
    struct Placed { let name: String; let dot: CGPoint; let textOrigin: CGPoint? }
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let priority = ["Barcelona", "Girona", "Lleida", "Tarragona"]

    static func place(_ cities: [(name: String, point: CGPoint)], pin: CGPoint?, in size: CGSize, obstacles: [CGRect],
                      measure: (String) -> CGSize) -> [Placed] {
        let inset = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        let dots = cities.map { CGRect(x: $0.point.x - 6, y: $0.point.y - 5, width: 12, height: 10) }
        var taken = obstacles
        if let pin { taken.append(PersonalPointMarker.obstacle(at: pin, in: size)) }
        let order = cities.indices.sorted { a, b in
            let pa = priority.firstIndex(of: cities[a].name) ?? priority.count, pb = priority.firstIndex(of: cities[b].name) ?? priority.count
            return pa != pb ? pa < pb : a < b
        }
        var origins = [Int: CGPoint]()
        for i in order {
            let s = measure(cities[i].name), p = cities[i].point
            var candidates = [CGPoint(x: p.x + 6, y: p.y - s.height / 2), CGPoint(x: p.x - 6 - s.width, y: p.y - s.height / 2),
                              CGPoint(x: p.x - s.width / 2, y: p.y - 4 - s.height), CGPoint(x: p.x - s.width / 2, y: p.y + 4)]
            if let pin {
                let marker = PersonalPointMarker.obstacle(at: pin, in: size)
                if marker.contains(p) {
                    candidates += [
                        CGPoint(x: marker.maxX + 4, y: p.y - s.height / 2),
                        CGPoint(x: marker.minX - 4 - s.width, y: p.y - s.height / 2),
                        CGPoint(x: p.x - s.width / 2, y: marker.minY - 4 - s.height),
                        CGPoint(x: p.x - s.width / 2, y: marker.maxY + 4)
                    ]
                }
            }
            let rect = candidates.lazy.map { CGRect(origin: $0, size: s) }.first { r in
                inset.contains(r) && !taken.contains { $0.intersects(r) }
                    && !dots.indices.contains { $0 != i && dots[$0].intersects(r) }
            }
            // No free position: keep the dot, drop the text rather than cover a control or another label.
            if let rect { taken.append(rect); origins[i] = rect.origin }
        }
        return cities.indices.map { Placed(name: cities[$0].name, dot: cities[$0].point, textOrigin: origins[$0]) }
    }
}

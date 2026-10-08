import AppKit

/// Small local preferences, independent of weather and personal map settings. Sizes are window frame points; the
/// content view fills the whole frame (full-size content), so frame and content size are the same thing here.
struct WindowPlacement: Codable, Equatable {
    static let defaultSize = NSSize(width: 750, height: 470)
    static let minimumSize = NSSize(width: 600, height: 400)
    static let maximumDimension: Double = 10_000

    var width: Double = 750
    var height: Double = 470
    var screen: String?
    var positions: [String: Offset] = [:]

    struct Offset: Codable, Equatable {
        var x: Double
        var y: Double
    }

    init() {}

    /// Version 1 stored only a width and a fixed 750:470 shape; a missing height derives from it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultSize.width
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? width * Self.defaultSize.height / Self.defaultSize.width
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        positions = try c.decodeIfPresent([String: Offset].self, forKey: .positions) ?? [:]
    }

    var isValid: Bool {
        width.isFinite && height.isFinite &&
        (Self.minimumSize.width...Self.maximumDimension).contains(width) &&
        (Self.minimumSize.height...Self.maximumDimension).contains(height) && positions.count <= 32 &&
        positions.allSatisfy { key, value in
            key.count <= 256 && value.x.isFinite && value.y.isFinite &&
            abs(value.x) <= 100_000 && abs(value.y) <= 100_000
        }
    }

    /// Each dimension is limited on its own: at least the minimum (or the whole screen when that is smaller), at most the
    /// screen's visible area. The shape is free.
    static func clamped(_ size: NSSize, in visible: NSRect) -> NSSize {
        func limit(_ value: CGFloat, minimum: CGFloat, available: CGFloat) -> CGFloat {
            let top = max(1, available)
            return min(top, max(min(minimum, top), value.isFinite ? value : minimum))
        }
        return NSSize(width: limit(size.width, minimum: minimumSize.width, available: visible.width),
                      height: limit(size.height, minimum: minimumSize.height, available: visible.height))
    }

    /// Keyboard scaling keeps the current shape: one factor, narrowed so neither side crosses its limit.
    static func scaled(_ size: NSSize, by factor: CGFloat, in visible: NSRect) -> NSSize {
        guard size.width > 0, size.height > 0 else { return clamped(defaultSize, in: visible) }
        let low = max(minimumSize.width / size.width, minimumSize.height / size.height)
        let high = min(visible.width / size.width, visible.height / size.height)
        let f = min(max(factor, low), max(high, 0.01))
        return clamped(NSSize(width: size.width * f, height: size.height * f), in: visible)
    }

    func frame(in visible: NSRect, screen: String) -> NSRect {
        let size = Self.clamped(NSSize(width: width, height: height), in: visible)
        let offset = positions[screen]
        let x = offset.map { visible.minX + $0.x } ?? visible.midX - size.width / 2
        let y = offset.map { visible.minY + $0.y } ?? visible.minY + visible.height * 0.55 - size.height / 2
        return NSRect(x: max(visible.minX, min(x, visible.maxX - size.width)),
                      y: max(visible.minY, min(y, visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}

struct WindowPlacementStore {
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let key = "radarWindowPlacement.v1"
    init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
    }
    func load() -> WindowPlacement {
        // A present but malformed new value must not resurrect an older placement.
        let usesLegacy = defaults.object(forKey: key) == nil
        let source = usesLegacy ? legacyDefaults : defaults
        guard let data = source?.data(forKey: key), data.count <= 32_768,
              var value = try? JSONDecoder().decode(WindowPlacement.self, from: data) else {
            return WindowPlacement()
        }
        // Raise the previous minimum without losing the saved screen and positions.
        if value.height.isFinite, (376..<WindowPlacement.minimumSize.height).contains(value.height) {
            value.height = WindowPlacement.minimumSize.height
        }
        guard value.isValid else { return WindowPlacement() }
        if usesLegacy { save(value) }
        return value
    }
    func save(_ value: WindowPlacement) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

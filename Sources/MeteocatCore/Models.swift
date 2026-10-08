import Foundation

public struct MeteocatError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum FrameKind: String, Codable, Sendable { case observation, forecast }
public struct FrameID: Hashable, Codable, Sendable {
    public let kind: FrameKind
    public let validUTC: Date
    public let originUTC: Date?
    public init(kind: FrameKind, validUTC: Date, originUTC: Date? = nil) throws {
        self.kind = kind; self.validUTC = validUTC; self.originUTC = originUTC
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case kind, validUTC, originUTC }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(FrameKind.self,forKey: .kind), validUTC: c.decode(Date.self,forKey: .validUTC), originUTC: c.decodeIfPresent(Date.self,forKey: .originUTC))
    }
    public func validate() throws {
        guard validUTC.timeIntervalSince1970.isFinite, (-62135596800...253402300799).contains(validUTC.timeIntervalSince1970), validUTC.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else { throw MeteocatError("Hora de radar no vàlida.") }
        switch kind {
        case .observation: guard originUTC == nil else { throw MeteocatError("Observació amb origen de previsió.") }
        case .forecast:
            guard let originUTC, originUTC.timeIntervalSince1970.isFinite, (-62135596800...253402300799).contains(originUTC.timeIntervalSince1970) else { throw MeteocatError("Previsió sense origen vàlid.") }
            let lead = validUTC.timeIntervalSince(originUTC)
            guard lead >= 360, lead <= 3600, lead.truncatingRemainder(dividingBy: 360) == 0 else { throw MeteocatError("Termini de previsió no vàlid.") }
        }
    }
    public func isExpired(at now: Date) -> Bool { kind == .forecast && now >= originUTC!.addingTimeInterval(3600) }
    public var storageKey: String { "\(kind.rawValue):\(originUTC?.timeIntervalSince1970.description ?? ""):\(validUTC.timeIntervalSince1970)" }
}
public struct TileCoordinate: Hashable, Codable, Sendable {
    public let z: Int; public let x: Int; public let yTMS: Int
    public init(z: Int = 7, x: Int, yTMS: Int) { self.z = z; self.x = x; self.yTMS = yTMS }
    public static let grid = (79...80).flatMap { y in (63...65).map { TileCoordinate(x: $0, yTMS: y) } }
}
public struct TileReference: Codable, Sendable {
    public let coordinate: TileCoordinate; public let sha256: String; public let relativePath: String
    public init(coordinate: TileCoordinate, sha256: String, relativePath: String) { self.coordinate = coordinate; self.sha256 = sha256; self.relativePath = relativePath }
    public func validate() throws {
        guard TileCoordinate.grid.contains(coordinate), sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }), relativePath == "tiles/\(sha256).png" else { throw MeteocatError("Referència del fragment del radar no vàlida.") }
    }
}
public struct CachedFrame: Codable, Sendable {
    public let id: FrameID; public let tiles: [TileReference]
    public init(id: FrameID, tiles: [TileReference]) throws { self.id = id; self.tiles = tiles; try validate() }
    private enum CodingKeys: String, CodingKey { case id, tiles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(FrameID.self,forKey: .id), tiles: c.decode([TileReference].self,forKey: .tiles))
    }
    public func validate() throws {
        try id.validate()
        guard tiles.count == 6, Set(tiles.map(\.coordinate)) == Set(TileCoordinate.grid) else { throw MeteocatError("Fotograma incomplet: calen sis fragments del radar.") }
        try tiles.forEach { try $0.validate() }
    }
}
public struct GeoPoint: Codable, Sendable, Equatable {
    public var lon: Double; public var lat: Double
    public init(lon: Double, lat: Double) { self.lon = lon; self.lat = lat }
}
public struct City: Identifiable, Codable, Sendable, Equatable {
    public var id: String; public var name: String; public var point: GeoPoint; public var visible: Bool
    public init(id: String, name: String, point: GeoPoint, visible: Bool = true) { self.id = id; self.name = name; self.point = point; self.visible = visible }
}
public struct Shortcut: Codable, Sendable, Equatable {
    public var keyCode: UInt32; public var carbonModifiers: UInt32
    public init(keyCode: UInt32, carbonModifiers: UInt32) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }
    public static let defaultShortcut = Shortcut(keyCode: 15, carbonModifiers: 0x1800)
}
public enum AppAppearance: String, Codable, Sendable, CaseIterable {
    case automatic, light, dark
}
public struct UserSettings: Codable, Sendable, Equatable {
    public var version: Int; public var labelsVisible: Bool; public var cities: [City]; public var pin: GeoPoint?; public var shortcut: Shortcut
    public var appearance: AppAppearance
    public var showsInDock: Bool
    public var showsInMenuBar: Bool
    /// Catalog entries already offered, including defaults the user later removed.
    public var knownDefaultCityIDs: [String]?
    public init(version: Int = 1, labelsVisible: Bool = true, cities: [City], pin: GeoPoint? = nil, shortcut: Shortcut = .defaultShortcut,
                showsInDock: Bool = true, showsInMenuBar: Bool = true, knownDefaultCityIDs: [String]? = nil,
                appearance: AppAppearance = .automatic) {
        self.version = version; self.labelsVisible = labelsVisible; self.cities = cities; self.pin = pin; self.shortcut = shortcut
        self.showsInDock = showsInDock; self.showsInMenuBar = showsInMenuBar
        self.knownDefaultCityIDs = knownDefaultCityIDs; self.appearance = appearance
    }
    private enum CodingKeys: String, CodingKey { case appearance, version, labelsVisible, cities, pin, shortcut, showsInDock, showsInMenuBar, knownDefaultCityIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version),
                  labelsVisible: try c.decode(Bool.self, forKey: .labelsVisible),
                  cities: try c.decode([City].self, forKey: .cities),
                  pin: try c.decodeIfPresent(GeoPoint.self, forKey: .pin),
                  shortcut: try c.decode(Shortcut.self, forKey: .shortcut),
                  showsInDock: try c.decodeIfPresent(Bool.self, forKey: .showsInDock) ?? true,
                  showsInMenuBar: try c.decodeIfPresent(Bool.self, forKey: .showsInMenuBar) ?? true,
                  knownDefaultCityIDs: try c.decodeIfPresent([String].self, forKey: .knownDefaultCityIDs),
                  appearance: (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? .automatic)
    }
}
public struct Metadata: Codable, Sendable {
    public let serverUTC: Date; public let observationUTC: Date; public let originUTC: Date
    public init(serverUTC: Date, observationUTC: Date, originUTC: Date) { self.serverUTC = serverUTC; self.observationUTC = observationUTC; self.originUTC = originUTC }
}
public struct RGBAImage: Sendable {
    public let width: Int; public let height: Int; public let bytes: Data
    public init(width: Int, height: Int, bytes: Data) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, bytes.count == width * height * 4 else { throw MeteocatError("Imatge del radar incompleta.") }
        self.width = width; self.height = height; self.bytes = bytes
    }
}
public enum DataMode: Sendable { case fixture(directory: URL, referenceUTC: Date), live }
public enum SourceState: Sendable {
    case recorded(capturedAt: Date), cached, refreshing, deferred(until: Date), unavailable(message: String)
}
public struct RadarSnapshot: Sendable {
    public let revision: UInt64; public let observations: [CachedFrame]; public let forecast: [CachedFrame]
    public let checkedAt: Date?; public let nextEligibleAt: Date?; public let sourceState: SourceState
    public let historyComplete: Bool; public let observationError: String?; public let forecastError: String?
    public init(revision: UInt64, observations: [CachedFrame], forecast: [CachedFrame], checkedAt: Date?, nextEligibleAt: Date?, sourceState: SourceState, historyComplete: Bool, observationError: String?, forecastError: String?) {
        self.revision = revision; self.observations = observations; self.forecast = forecast; self.checkedAt = checkedAt; self.nextEligibleAt = nextEligibleAt; self.sourceState = sourceState; self.historyComplete = historyComplete; self.observationError = observationError; self.forecastError = forecastError
    }
    /// Chronological playback; storage still retains all ten forecasts.
    public var visibleTimeline: [CachedFrame] { observations + forecast.filter { $0.id.validUTC > (observations.last?.id.validUTC ?? .distantPast) } }
    public func observationsAreStale(at now: Date) -> Bool { observations.last.map { now.timeIntervalSince($0.id.validUTC) > 720 } ?? true }
}
public enum FrameTransition {
    public static func canCrossfade(from: FrameID, to: FrameID, isAdjacent: Bool, isPlaying: Bool, isLoopWrap: Bool, generationChanged: Bool) -> Bool {
        let sameProduct = from.kind == to.kind && from.originUTC == to.originUTC
        let entersForecast = from.kind == .observation && to.kind == .forecast
        return isAdjacent && isPlaying && !isLoopWrap && !generationChanged &&
            (sameProduct || entersForecast) && to.validUTC.timeIntervalSince(from.validUTC) == 360
    }
}

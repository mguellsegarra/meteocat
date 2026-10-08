import Foundation
import CoreGraphics
public struct MapProjection: Sendable {
    public static let bbox = [-150284.85361480707, 4923982.758275913, 538964.6601540097, 5309151.604205547]
    public static let radius = 6378137.0
    public init(manifestURL: URL) throws {
        struct Manifest: Decodable { let crs: String; let width: Int; let height: Int; let bbox: [Double] }
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard m.crs == "EPSG:3857", m.width == 680, m.height == 380, m.bbox == Self.bbox else { throw MeteocatError("Projecció geogràfica incompatible.") }
    }
    public func project(_ point: GeoPoint) throws -> CGPoint {
        guard point.lon.isFinite, point.lat.isFinite, abs(point.lon) <= 180, abs(point.lat) < 85.051129 else { throw MeteocatError("Coordenades no vàlides.") }
        let x = Self.radius * point.lon * .pi / 180
        let y = Self.radius * log(tan(.pi / 4 + point.lat * .pi / 360))
        return CGPoint(x: (x - Self.bbox[0]) / (Self.bbox[2] - Self.bbox[0]) * 680, y: (Self.bbox[3] - y) / (Self.bbox[3] - Self.bbox[1]) * 380)
    }
    public func unproject(_ point: CGPoint) throws -> GeoPoint {
        guard point.x.isFinite, point.y.isFinite, CGRect(x: 0, y: 0, width: 680, height: 380).contains(point) || (point.x >= 0 && point.x <= 680 && point.y >= 0 && point.y <= 380) else { throw MeteocatError("Punt fora del mapa.") }
        let x = Self.bbox[0] + Double(point.x) / 680 * (Self.bbox[2] - Self.bbox[0])
        let y = Self.bbox[3] - Double(point.y) / 380 * (Self.bbox[3] - Self.bbox[1])
        return GeoPoint(lon: x / Self.radius * 180 / .pi, lat: (2 * atan(exp(y / Self.radius)) - .pi / 2) * 180 / .pi)
    }
    public func fit(in size: CGSize) -> MapFit {
        let s = max(0, min(size.width / 680, size.height / 380))
        let o = CGPoint(x: (size.width - 680 * s) / 2, y: (size.height - 380 * s) / 2)
        return MapFit(scale: s, offset: o, rect: CGRect(origin: o, size: CGSize(width: 680 * s, height: 380 * s)))
    }
}
public struct MapFit: Sendable {
    public let scale: CGFloat; public let offset: CGPoint; public let rect: CGRect
    public init(scale: CGFloat, offset: CGPoint, rect: CGRect) { self.scale = scale; self.offset = offset; self.rect = rect }
    public func viewPoint(_ canonical: CGPoint) -> CGPoint { CGPoint(x: offset.x + canonical.x * scale, y: offset.y + canonical.y * scale) }
    public func canonicalPoint(_ view: CGPoint) -> CGPoint? {
        guard scale > 0, view.x >= rect.minX, view.x <= rect.maxX, view.y >= rect.minY, view.y <= rect.maxY else { return nil }
        return CGPoint(x: (view.x - offset.x) / scale, y: (view.y - offset.y) / scale)
    }
}

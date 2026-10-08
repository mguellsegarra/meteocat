import Foundation
public enum WeatherRasterizer {
    public static func rasterize(_ tiles: [TileCoordinate: RGBAImage]) throws -> RGBAImage {
        guard Set(tiles.keys) == Set(TileCoordinate.grid), tiles.values.allSatisfy({ $0.width == 256 && $0.height == 256 }) else { throw MeteocatError("Cobertura de radar incompleta.") }
        let span = 313086.06785608194, half = 20037508.342789244, bbox = MapProjection.bbox
        let buffers = tiles.mapValues { [UInt8]($0.bytes) }
        var out = [UInt8](repeating: 0, count: 680 * 380 * 4)
        for y in 0..<380 { for x in 0..<680 {
            let X = bbox[0] + (Double(x)+0.5)/680*(bbox[2]-bbox[0])
            let Y = bbox[3] - (Double(y)+0.5)/380*(bbox[3]-bbox[1])
            let tx = Int(floor((X+half)/span)), ty = Int(floor((Y+half)/span))
            let sx = Int(floor((X-(Double(tx)*span-half))/span*256)), sy = Int(floor(((Double(ty+1)*span-half)-Y)/span*256))
            guard (0..<256).contains(sx), (0..<256).contains(sy), let t = buffers[TileCoordinate(x: tx, yTMS: ty)] else { throw MeteocatError("Mostra fora de cobertura.") }
            let src = (sy*256+sx)*4, dst = (y*680+x)*4
            out[dst..<dst+4] = t[src..<src+4]
        } }
        return try RGBAImage(width: 680, height: 380, bytes: Data(out))
    }
    /// Returns one premultiplied RGBA surface. At endpoints, UI must bypass this
    /// helper and draw the original straight-alpha RGBAImage without conversion.
    public static func blendedPremultiplied(from: RGBAImage, to: RGBAImage, progress: Double) throws -> Data {
        guard from.width == to.width, from.height == to.height, progress.isFinite else { throw MeteocatError("Transició incompatible.") }
        let t = min(1,max(0,progress)), a = [UInt8](from.bytes), b = [UInt8](to.bytes)
        var out = [UInt8](repeating: 0, count: a.count)
        for p in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { out[p+c] = UInt8(((1-t)*Double(a[p+c])*Double(a[p+3])/255 + t*Double(b[p+c])*Double(b[p+3])/255).rounded()) }
            out[p+3] = UInt8(((1-t)*Double(a[p+3])+t*Double(b[p+3])).rounded())
        }
        return Data(out)
    }
}

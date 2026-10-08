import Foundation
import ImageIO
import CryptoKit

@_silgen_name("uncompress") private func zlibUncompress(_ dest: UnsafeMutablePointer<UInt8>, _ length: UnsafeMutablePointer<UInt>, _ source: UnsafePointer<UInt8>, _ sourceLength: UInt) -> Int32

public enum PNGDecoder {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xedb88320 : 0) } }
        return c ^ 0xffffffff
    }
    /// Requires ImageIO's complete decode, but reconstructs straight RGBA directly
    /// from PNG scanlines to avoid CGContext premultiplication/color conversion.
    public static func decode(_ data: Data, expectedHash: String? = nil, width: Int = 256, height: Int = 256) throws -> RGBAImage {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw MeteocatError("Dimensions de la imatge PNG fora dels límits admesos.") }
        guard data.count <= maximumBytes, data.count >= 57 else { throw MeteocatError("Fragment del radar massa gran o incomplet.") }
        if let expectedHash, sha256(data) != expectedHash { throw MeteocatError("La comprovació d'integritat del fragment del radar ha fallat.") }
        let b = [UInt8](data)
        guard Array(b.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw MeteocatError("Signatura PNG incorrecta.") }
        func u32(_ i: Int) -> UInt32 { b[i..<i+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        var i = 8, header = false, ended = false, seenIDAT = false, endedIDAT = false
        var color: UInt8 = 0, compressed = Data(), palette = [UInt8](), alpha = [UInt8]()
        while i < b.count {
            guard i + 12 <= b.count else { throw MeteocatError("Bloc de dades PNG incomplet.") }
            let n = Int(u32(i)); guard n <= maximumBytes, i + 12 + n <= b.count else { throw MeteocatError("Bloc de dades PNG fora dels límits admesos.") }
            let type = String(bytes: b[i+4..<i+8], encoding: .ascii) ?? ""
            guard type.count == 4, type.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }), crc32(b[i+4..<i+8+n]) == u32(i+8+n) else { throw MeteocatError("CRC PNG incorrecte.") }
            let payload = Array(b[i+8..<i+8+n])
            guard header || type == "IHDR" else { throw MeteocatError("IHDR absent.") }
            if seenIDAT && type != "IDAT" { endedIDAT = true }
            switch type {
            case "IHDR":
                guard !header, i == 8, n == 13, Int(u32(i+8)) == width, Int(u32(i+12)) == height, payload[8] == 8, [0,2,3,4,6].contains(payload[9]), payload[10] == 0, payload[11] == 0, payload[12] == 0 else { throw MeteocatError("Format o dimensions PNG incompatibles.") }
                color = payload[9]; header = true
            case "PLTE": guard !seenIDAT, palette.isEmpty, n > 0, n <= 768, n % 3 == 0 else { throw MeteocatError("Paleta PNG incorrecta.") }; palette = payload
            case "tRNS": guard !seenIDAT, alpha.isEmpty else { throw MeteocatError("Transparència PNG incorrecta.") }; alpha = payload
            case "IDAT": guard !endedIDAT else { throw MeteocatError("IDAT no contigu.") }; seenIDAT = true; compressed.append(contentsOf: payload)
            case "IEND": guard n == 0, seenIDAT, i + 12 == b.count else { throw MeteocatError("Final PNG incorrecte.") }; ended = true
            default: guard type.first!.isLowercase else { throw MeteocatError("Bloc de dades essencial del PNG desconegut.") }
            }
            i += n + 12
        }
        guard ended, let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetStatus(src) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), image.width == width, image.height == height, CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete else { throw MeteocatError("ImageIO no pot descodificar el PNG complet.") }
        let channels = [0:1,2:3,3:1,4:2,6:4][Int(color)]!
        let row = width * channels, count = (row + 1) * height
        var raw = [UInt8](repeating: 0, count: count), length = UInt(count)
        let result = raw.withUnsafeMutableBufferPointer { dst in compressed.withUnsafeBytes { source in zlibUncompress(dst.baseAddress!, &length, source.bindMemory(to: UInt8.self).baseAddress!, UInt(compressed.count)) } }
        guard result == 0, length == count else { throw MeteocatError("Dades PNG comprimides incompletes.") }
        var pixels = [UInt8](repeating: 0, count: row * height)
        func paeth(_ a: Int, _ b: Int, _ c: Int) -> UInt8 { let p = a+b-c, pa = abs(p-a), pb = abs(p-b), pc = abs(p-c); return UInt8(pa <= pb && pa <= pc ? a : pb <= pc ? b : c) }
        for y in 0..<height {
            let filter = raw[y*(row+1)]; guard filter <= 4 else { throw MeteocatError("Filtre PNG incorrecte.") }
            for x in 0..<row {
                let k = y*row+x, a = x >= channels ? pixels[k-channels] : 0, up = y > 0 ? pixels[k-row] : 0, c = y > 0 && x >= channels ? pixels[k-row-channels] : 0
                let base: UInt8 = filter == 0 ? 0 : filter == 1 ? a : filter == 2 ? up : filter == 3 ? UInt8((Int(a)+Int(up))/2) : paeth(Int(a),Int(up),Int(c))
                pixels[k] = raw[y*(row+1)+1+x] &+ base
            }
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<width*height {
            let k = p*channels, d = p*4
            switch color {
            case 6: rgba[d..<d+4] = pixels[k..<k+4]
            case 2: rgba[d] = pixels[k]; rgba[d+1] = pixels[k+1]; rgba[d+2] = pixels[k+2]; rgba[d+3] = 255
                if alpha.count == 6 && (0..<3).allSatisfy({ alpha[$0*2] == 0 && alpha[$0*2+1] == pixels[k+$0] }) { rgba[d+3] = 0 }
            case 3:
                let index = Int(pixels[k]); guard index*3+2 < palette.count else { throw MeteocatError("Índex de paleta PNG fora de rang.") }
                rgba[d] = palette[index*3]; rgba[d+1] = palette[index*3+1]; rgba[d+2] = palette[index*3+2]; rgba[d+3] = index < alpha.count ? alpha[index] : 255
            default:
                rgba[d] = pixels[k]; rgba[d+1] = pixels[k]; rgba[d+2] = pixels[k]; rgba[d+3] = color == 4 ? pixels[k+1] : (alpha.count == 2 && alpha[0] == 0 && alpha[1] == pixels[k] ? 0 : 255)
            }
        }
        return try RGBAImage(width: width, height: height, bytes: Data(rgba))
    }
}

import Foundation
import MeteocatCore
import ImageIO
import CoreGraphics
@main struct FixtureImportCommand {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--audit-fixture" {
            let root = MeteocatResources.previewFixtureDirectory
            let manifest = try NativeJSON.decode(CacheManifest.self,AtomicFile.read(root.appendingPathComponent("active.json")))
            let timestamp = try RadarMetadata.parseUTC("10/07/2026 05:48Z")
            guard let frame = manifest.frames.first(where: { $0.id.kind == .observation && $0.id.validUTC == timestamp }) else { throw MeteocatError("Fotograma d'auditoria absent.") }
            try frame.validate()
            var tiles = [TileCoordinate:RGBAImage]()
            for ref in frame.tiles { tiles[ref.coordinate] = try PNGDecoder.decode(AtomicFile.read(root.appendingPathComponent(ref.relativePath)),expectedHash: ref.sha256) }
            let image = try WeatherRasterizer.rasterize(tiles)
            try AtomicFile.write(image.bytes,to: URL(fileURLWithPath: args[2]))
            let output = URL(fileURLWithPath: args[2]).appendingPathExtension("png")
            guard let provider = CGDataProvider(data: image.bytes as CFData), let cgImage = CGImage(width: image.width,height: image.height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: image.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent), let destination = CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil) else { throw MeteocatError("No es pot crear la imatge d'auditoria.") }
            CGImageDestinationAddImage(destination,cgImage,nil)
            guard CGImageDestinationFinalize(destination) else { throw MeteocatError("No es pot desar la imatge d'auditoria.") }
            let roundtrip = try PNGDecoder.decode(AtomicFile.read(output),width: 680,height: 380)
            guard roundtrip.bytes == image.bytes else { throw MeteocatError("La imatge PNG d'auditoria altera els bytes RGBA.") }
            print("680x380 straight RGBA8, north row 0, SHA256=\(PNGDecoder.sha256(image.bytes)), PNG roundtrip exact")
            return
        }
        if args.count == 2 && args[1] == "--verify-resources" {
            let settings = try MeteocatResources.defaultSettings()
            _ = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
            let root = MeteocatResources.previewFixtureDirectory
            let manifest = try NativeJSON.decode(CacheManifest.self,AtomicFile.read(root.appendingPathComponent("active.json")))
            try manifest.validate()
            var hashes = Set<String>()
            for frame in manifest.frames { for ref in frame.tiles where hashes.insert(ref.sha256).inserted {
                _ = try PNGDecoder.decode(AtomicFile.read(root.appendingPathComponent(ref.relativePath)),expectedHash: ref.sha256)
            } }
            print("Resources verified at \(root.path): \(settings.cities.count) cities, \(manifest.frames.count) frames, \(hashes.count) distinct tiles.")
            return
        }
        guard args.count == 3 else { throw MeteocatError("Ús: FixtureImport <cache Raycast local> <directori destí buit>") }
        let info = try FixtureImporter.importSnapshot(source: URL(fileURLWithPath: args[1]),destination: URL(fileURLWithPath: args[2]))
        print(String(data: try NativeJSON.encode(info),encoding: .utf8)!)
    }
}

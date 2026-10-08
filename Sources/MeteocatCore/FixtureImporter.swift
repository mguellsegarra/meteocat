import Foundation
public struct SnapshotInfo: Codable, Sendable {
    public let capturedAt: Date; public let sourceManifestSHA256: String; public let distinctTiles: Int
    public init(capturedAt: Date, sourceManifestSHA256: String, distinctTiles: Int) { self.capturedAt = capturedAt; self.sourceManifestSHA256 = sourceManifestSHA256; self.distinctTiles = distinctTiles }
}
public enum FixtureImporter {
    public static func importSnapshot(source: URL, destination: URL) throws -> SnapshotInfo {
        try NativeDestination.validate(destination)
        guard source.standardizedFileURL != destination.standardizedFileURL, !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw MeteocatError("El destí ha de ser independent de l'origen.") }
        let manifestURL = source.appendingPathComponent("active.json"), bytes = try AtomicFile.read(manifestURL)
        let hash = PNGDecoder.sha256(bytes)
        struct LegacyTile: Decodable { let x: Int; let y: Int; let file: String; let sha256: String }
        struct LegacyFrame: Decodable { let kind: FrameKind; let validUTC: String; let originUTC: String?; let tiles: [LegacyTile] }
        struct LegacyManifest: Decodable { let version: Int; let frames: [LegacyFrame]; let checkedAt: Double }
        let legacy = try JSONDecoder().decode(LegacyManifest.self, from: bytes)
        guard legacy.version == 1, legacy.checkedAt.isFinite else { throw MeteocatError("Snapshot antic no vàlid.") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        func date(_ text: String) throws -> Date { guard let d = formatter.date(from: text), formatter.string(from: d) == text else { throw MeteocatError("Data de fixture no vàlida.") }; return d }
        let frames = try legacy.frames.map { f in
            try CachedFrame(id: FrameID(kind: f.kind, validUTC: date(f.validUTC), originUTC: f.originUTC.map { try date($0) }), tiles: f.tiles.map { TileReference(coordinate: TileCoordinate(x: $0.x,yTMS: $0.y),sha256: $0.sha256,relativePath: $0.file) })
        }
        let capture = Date(timeIntervalSince1970: legacy.checkedAt/1000)
        let manifest = CacheManifest(frames: frames,checkedAt: capture); try manifest.validate()
        let tiles = source.appendingPathComponent("tiles")
        guard source.resolvingSymlinksInPath().standardizedFileURL == source.standardizedFileURL, tiles.resolvingSymlinksInPath().standardizedFileURL == tiles.standardizedFileURL else { throw MeteocatError("L'origen conté enllaços simbòlics.") }
        var verified = [String:Data]()
        for ref in frames.flatMap(\.tiles) where verified[ref.sha256] == nil {
            try ref.validate()
            let data = try AtomicFile.read(source.appendingPathComponent(ref.relativePath))
            _ = try PNGDecoder.decode(data,expectedHash: ref.sha256); verified[ref.sha256] = data
        }
        guard PNGDecoder.sha256(try AtomicFile.read(manifestURL)) == hash else { throw MeteocatError("El manifest ha canviat durant la lectura. Torna a importar-lo.") }
        let fm = FileManager.default
        guard try !fm.fileExists(atPath: destination.path) || fm.contentsOfDirectory(atPath: destination.path).isEmpty else { throw MeteocatError("El destí del fixture ja conté dades.") }
        try fm.createDirectory(at: destination,withIntermediateDirectories: true)
        do {
            for (hash,data) in verified { try AtomicFile.write(data,to: destination.appendingPathComponent("tiles/\(hash).png")) }
            let info = SnapshotInfo(capturedAt: capture,sourceManifestSHA256: hash,distinctTiles: verified.count)
            try AtomicFile.write(NativeJSON.encode(info),to: destination.appendingPathComponent("snapshot-info.json"))
            try AtomicFile.write(NativeJSON.encode(manifest),to: destination.appendingPathComponent("active.json"))
            return info
        } catch { try? fm.removeItem(at: destination); throw error }
    }
}

import Foundation
import Darwin

enum NativeDestination {
    static func validate(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.resolvingSymlinksInPath() == normalized, !normalized.pathComponents.contains("meteocat-raycast"), !normalized.path.contains("/com.raycast.macos/extensions/meteocat-radar/") else { throw MeteocatError("La carpeta de l'app ha de ser independent de la memòria cau i del projecte Raycast.") }
    }
}

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default, parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MeteocatError("No es pot crear el fitxer temporal.") }
        defer { Darwin.close(fd); try? fm.removeItem(at: temp) }
        try data.withUnsafeBytes { ptr in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw MeteocatError("No s'ha pogut desar la memòria cau.") }
                offset += n
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw MeteocatError("No s'ha pogut confirmar la memòria cau.") }
        let directory = Darwin.open(parent.path, O_RDONLY)
        guard directory >= 0 else { throw MeteocatError("No es pot sincronitzar el directori.") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw MeteocatError("No s'ha pogut sincronitzar el directori.") }
    }
    public static func read(_ url: URL, maximum: Int = 2 * 1024 * 1024) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw MeteocatError("No es pot llegir el fitxer local.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximum else { throw MeteocatError("Fitxer local fora de límits.") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw MeteocatError("Lectura local incompleta.") }; offset += n
        }
        return Data(bytes)
    }
}
public enum NativeJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            var container = encoder.singleValueContainer(); try container.encode(formatter.string(from: date))
        }
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self), formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw MeteocatError("Data local no vàlida.") }; return date
        }
        return try d.decode(type,from: data)
    }
}
public struct CacheManifest: Codable, Sendable {
    public var version: Int = 1
    public var frames: [CachedFrame]
    public var checkedAt: Date?
    public init(frames: [CachedFrame], checkedAt: Date?) { self.frames = frames; self.checkedAt = checkedAt }
    // Compare source identity and tile content independently of order or checkedAt.
    var content: [FrameID: [TileCoordinate: String]] {
        Dictionary(uniqueKeysWithValues: frames.map { frame in
            (frame.id,Dictionary(uniqueKeysWithValues: frame.tiles.map { ($0.coordinate,$0.sha256) }))
        })
    }
    public func validate() throws {
        guard version == 1, frames.count <= 21, Set(frames.map(\.id)).count == frames.count else { throw MeteocatError("Manifest de radar no vàlid.") }
        try frames.forEach { try $0.validate() }
        let obs = frames.filter { $0.id.kind == .observation }.sorted { $0.id.validUTC < $1.id.validUTC }
        guard obs.count <= 11, zip(obs,obs.dropFirst()).allSatisfy({ $1.id.validUTC.timeIntervalSince($0.id.validUTC) == 360 }) else { throw MeteocatError("Historial de radar no contigu.") }
        let forecast = frames.filter { $0.id.kind == .forecast }.sorted { $0.id.validUTC < $1.id.validUTC }
        guard forecast.isEmpty || (forecast.count == 10 && Set(forecast.map { $0.id.originUTC }).count == 1 && forecast.first!.id.validUTC.timeIntervalSince(forecast.first!.id.originUTC!) == 360 && zip(forecast,forecast.dropFirst()).allSatisfy({ $1.id.validUTC.timeIntervalSince($0.id.validUTC) == 360 })) else { throw MeteocatError("Bloc de previsions incomplet.") }
    }
}
public struct AdmissionGate: Codable, Sendable {
    public var nextCycleAt: Date; public var blockedUntil: Date
    public init(nextCycleAt: Date = .distantPast, blockedUntil: Date = .distantPast) { self.nextCycleAt = nextCycleAt; self.blockedUntil = blockedUntil }
    private enum CodingKeys: String, CodingKey { case nextCycleAt, blockedUntil }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date {
            if let seconds = try? c.decode(Double.self,forKey: key) {
                guard seconds.isFinite else { throw MeteocatError("Termini del límit de consultes no vàlid.") }; return Date(timeIntervalSince1970: seconds)
            }
            return try c.decode(Date.self,forKey: key) // migrate the initial ISO8601 gate
        }
        nextCycleAt = try date(.nextCycleAt); blockedUntil = try date(.blockedUntil)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nextCycleAt.timeIntervalSince1970,forKey: .nextCycleAt)
        try c.encode(blockedUntil.timeIntervalSince1970,forKey: .blockedUntil)
    }
    public var deadline: Date { max(nextCycleAt, blockedUntil) }
}
struct MetadataRecord: Codable, Sendable { var body: Data; var metadata: Metadata; var etag: String?; var lastModified: String?; var checkedAt: Date }

struct CycleBusy: Error {}
final class CycleLock {
    private let fd: Int32
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fd = Darwin.open(root.appendingPathComponent("refresh.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MeteocatError("No es pot obrir el bloqueig de radar.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw CycleBusy() }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

final class DiskCache {
    let root: URL
    let budget: Int
    var index: [String: TileReference] = [:]
    var previous = Set<String>()
    var active = Set<String>()
    var protected = Set<String>()
    var staged = Set<String>()
    var reserved = 0
    var committed: CacheManifest?
    var recoveryNotice: String?
    private var cycleOwned = false
    private var inventory: [URL: (size: Int, modified: Date)]?
    private(set) var inventoryScans = 0
    private var inventoryBytes = 0
    private var indexDirty = false
    func beginCycle() { cycleOwned = true; inventory = nil }
    func endCycle() { cycleOwned = false; inventory = nil }
    private func validateTilesDirectory() throws {
        let tiles = root.appendingPathComponent("tiles",isDirectory: true)
        guard tiles.resolvingSymlinksInPath().standardizedFileURL.path == tiles.standardizedFileURL.path else { throw MeteocatError("La carpeta dels fragments del radar conté un enllaç simbòlic.") }
    }
    // Every owned write updates the byte inventory; an uncertain write invalidates it.
    func write(_ data: Data, to url: URL) throws {
        do { try AtomicFile.write(data,to: url) }
        catch { inventory = nil; throw error }
        if inventory != nil { inventoryBytes += data.count - (inventory?[url]?.size ?? 0); inventory?[url] = (data.count,Date()) }
    }
    init(root: URL, budget: Int = 192 * 1024 * 1024) { self.root = root; self.budget = budget }
    func tile(_ ref: TileReference) throws -> Data {
        let data = try tileBytes(ref); _ = try PNGDecoder.decode(data, expectedHash: ref.sha256); return data
    }
    func decodedTile(_ ref: TileReference) throws -> RGBAImage { try PNGDecoder.decode(tileBytes(ref), expectedHash: ref.sha256) }
    private func tileBytes(_ ref: TileReference) throws -> Data {
        try ref.validate()
        let tiles = root.appendingPathComponent("tiles", isDirectory: true)
        guard tiles.resolvingSymlinksInPath().standardizedFileURL.path == tiles.standardizedFileURL.path else { throw MeteocatError("La carpeta dels fragments del radar conté un enllaç simbòlic.") }
        let data = try AtomicFile.read(root.appendingPathComponent(ref.relativePath))
        return data
    }
    func load() throws -> CacheManifest {
        try validateTilesDirectory()
        index = [:]; active = []; previous = []; recoveryNotice = nil
        let activeURL = root.appendingPathComponent("active.json"), previousURL = root.appendingPathComponent("previous.json")
        // Validate all identities/paths before reading any referenced bytes.
        func structure(_ url: URL) -> CacheManifest? {
            guard let manifest = try? NativeJSON.decode(CacheManifest.self,AtomicFile.read(url)), (try? manifest.validate()) != nil else { return nil }
            return manifest
        }
        let current = structure(activeURL), prior = structure(previousURL)
        var validated = [String: Bool]()
        func intact(_ frame: CachedFrame) -> Bool {
            frame.tiles.allSatisfy { ref in
                if let result = validated[ref.sha256] { return result }
                let result = (try? tile(ref)) != nil; validated[ref.sha256] = result; return result
            }
        }
        func complete(_ manifest: CacheManifest?) -> Bool { manifest.map { $0.frames.allSatisfy(intact) } ?? false }
        let manifest: CacheManifest
        if let current, complete(current) { manifest = current }
        else if let prior, complete(prior) {
            manifest = prior; recoveryNotice = "La memòria cau activa no és vàlida. Es conserva l'última còpia completa."
        } else {
            var observations = [CachedFrame](), forecast = [CachedFrame]()
            for candidate in [current,prior].compactMap({ $0 }) {
                let good = candidate.frames.filter { $0.id.kind == .observation && intact($0) }.sorted { $0.id.validUTC < $1.id.validUTC }
                // A contiguous suffix ending at the newest intact observation only.
                var suffix = [CachedFrame]()
                for frame in good.reversed() {
                    if let oldest = suffix.first, oldest.id.validUTC.timeIntervalSince(frame.id.validUTC) != 360 { break }
                    suffix.insert(frame,at: 0)
                }
                if let newest = suffix.last, newest.id.validUTC > (observations.last?.id.validUTC ?? .distantPast) { observations = suffix }
                let block = candidate.frames.filter { $0.id.kind == .forecast }
                if block.count == 10, block.allSatisfy(intact), let origin = block.first?.id.originUTC, origin > (forecast.first?.id.originUTC ?? .distantPast) { forecast = block }
            }
            manifest = CacheManifest(frames: observations + forecast,checkedAt: nil)
            if FileManager.default.fileExists(atPath: activeURL.path) || FileManager.default.fileExists(atPath: previousURL.path) {
                recoveryNotice = "La memòria cau estava malmesa. Es mostren només fotogrames verificats; cal actualitzar el radar."
            }
        }
        try manifest.validate(); committed = manifest
        active = Set(manifest.frames.flatMap { $0.tiles.map(\.sha256) })
        // Never protect or reuse unvalidated paths from a damaged prior manifest.
        if let prior, complete(prior) { previous = Set(prior.frames.flatMap { $0.tiles.map(\.sha256) }) }
        for frame in manifest.frames { for ref in frame.tiles { index[frame.id.storageKey + ":\(ref.coordinate.z):\(ref.coordinate.x):\(ref.coordinate.yTMS)"] = ref } }
        let indexURL = root.appendingPathComponent("tile-index.json")
        let saved = try? NativeJSON.decode([String: TileReference].self,AtomicFile.read(indexURL,maximum: 4 * 1024 * 1024))
        if let saved {
            for key in saved.keys.sorted() where index[key] == nil && index.count < 2048 {
                guard let ref = saved[key], (try? ref.validate()) != nil, Self.matchesSource(key,ref: ref) else { continue }
                let valid = validated[ref.sha256] ?? ((try? tile(ref)) != nil)
                validated[ref.sha256] = valid
                if valid { index[key] = ref }
            }
        }
        indexDirty = saved.map { old in
            old.count != index.count || old.contains { key,ref in
                guard let value = index[key] else { return true }
                return value.sha256 != ref.sha256 || value.coordinate != ref.coordinate || value.relativePath != ref.relativePath
            }
        } ?? (!index.isEmpty || FileManager.default.fileExists(atPath: indexURL.path))
        return manifest
    }
    private static func matchesSource(_ key: String, ref: TileReference) -> Bool {
        let parts = key.split(separator: ":",omittingEmptySubsequences: false)
        guard parts.count == 6, let kind = FrameKind(rawValue: String(parts[0])), let valid = Double(parts[2]), valid.isFinite else { return false }
        let origin: Date?
        if parts[1].isEmpty { origin = nil }
        else { guard let seconds = Double(parts[1]), seconds.isFinite else { return false }; origin = Date(timeIntervalSince1970: seconds) }
        guard let id = try? FrameID(kind: kind,validUTC: Date(timeIntervalSince1970: valid),originUTC: origin) else { return false }
        let c = ref.coordinate
        return key == id.storageKey + ":\(c.z):\(c.x):\(c.yTMS)"
    }
    private func persistIndex(protecting hashes: Set<String> = []) throws {
        guard indexDirty else { return }
        let body = try NativeJSON.encode(index)
        try reserve(body.count,protecting: hashes); defer { reserved -= body.count }
        try write(body,to: root.appendingPathComponent("tile-index.json")); indexDirty = false
    }
    func gate(now: Date) throws -> AdmissionGate {
        let url = root.appendingPathComponent("gate.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AdmissionGate() }
        do {
            let g = try NativeJSON.decode(AdmissionGate.self, AtomicFile.read(url, maximum: 4096))
            guard g.nextCycleAt.timeIntervalSince1970.isFinite, g.blockedUntil.timeIntervalSince1970.isFinite else { throw MeteocatError("Límit de consultes no vàlid.") }
            return g
        } catch {
            let closed = AdmissionGate(nextCycleAt: now.addingTimeInterval(360), blockedUntil: now.addingTimeInterval(360))
            try writeGate(closed); return closed
        }
    }
    func writeGate(_ gate: AdmissionGate) throws {
        let body = try NativeJSON.encode(gate)
        try reserve(body.count); defer { reserved -= body.count }
        try write(body,to: root.appendingPathComponent("gate.json"))
    }
    func persist(_ manifest: CacheManifest) throws {
        try manifest.validate()
        let hashes = Set(manifest.frames.flatMap { $0.tiles.map(\.sha256) })
        let body = try NativeJSON.encode(manifest)
        if let committed, committed.content == manifest.content {
            try persistIndex(protecting: hashes)
            guard committed.checkedAt != manifest.checkedAt else { return }
            // A successful source check updates active once, without rotating last-good content.
            try reserve(body.count,protecting: hashes); defer { reserved -= body.count }
            try write(body,to: root.appendingPathComponent("active.json")); self.committed = manifest
            return
        }
        let indices = try NativeJSON.encode(index)
        let oldBody = try committed.map { try NativeJSON.encode($0) } ?? Data()
        try reserve(body.count + indices.count + oldBody.count,protecting: hashes)
        defer { reserved -= body.count + indices.count + oldBody.count }
        if !oldBody.isEmpty { try write(oldBody,to: root.appendingPathComponent("previous.json")) }
        try write(indices,to: root.appendingPathComponent("tile-index.json"))
        indexDirty = false
        try write(body,to: root.appendingPathComponent("active.json"))
        previous = active; active = hashes; committed = manifest
    }
    func reserve(_ count: Int, protecting extra: Set<String> = []) throws {
        guard count >= 0, count <= budget else { throw MeteocatError("La memòria cau supera el límit de 192 MiB.") }
        try validateTilesDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("tiles"),withIntermediateDirectories: true)
        if inventory == nil {
            var entries = [URL: (size: Int, modified: Date)]()
            let keys: Set<URLResourceKey> = [.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey]
            guard let enumerator = fm.enumerator(at: root,includingPropertiesForKeys: Array(keys),options: [.skipsPackageDescendants]) else { throw MeteocatError("No es pot comptar la memòria cau.") }
            for case let url as URL in enumerator {
                let v = try url.resourceValues(forKeys: keys)
                if v.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if v.isRegularFile == true { entries[url] = (v.fileSize ?? 0,v.contentModificationDate ?? .distantPast) }
            }
            inventory = entries; inventoryBytes = entries.values.reduce(0) { $0 + $1.size }; inventoryScans += 1
        }
        // .write-* left by a crash count toward budget; only this process's AtomicFile
        // temporaries are removed by their write defer, never another process's files.
        var total = inventoryBytes
        let keep = active.union(previous).union(protected).union(staged).union(extra)
        if total + reserved + count > budget {
            let tiles = root.appendingPathComponent("tiles",isDirectory: true)
            let candidates = inventory!.filter { url,_ in url.deletingLastPathComponent() == tiles && url.pathExtension == "png" && !keep.contains(url.deletingPathExtension().lastPathComponent) }
            for (url,value) in candidates.sorted(by: { $0.value.modified < $1.value.modified }) {
                try fm.removeItem(at: url); inventory?[url] = nil; total -= value.size; inventoryBytes -= value.size
                if total + reserved + count <= Int(Double(budget)*0.9) { break }
            }
        }
        guard total + reserved + count <= budget else { throw MeteocatError("La memòria cau protegida és plena. Es conserva el radar actual.") }
        reserved += count
    }
    func store(_ data: Data, coordinate: TileCoordinate, key: String) throws -> TileReference {
        // Service writes already own flock. Standalone callers acquire it for this write.
        let lock = try cycleOwned ? nil : CycleLock(root: root)
        if lock != nil { inventory = nil }
        defer { if lock != nil { inventory = nil }; withExtendedLifetime(lock) {} }
        try validateTilesDirectory()
        _ = try PNGDecoder.decode(data)
        let hash = PNGDecoder.sha256(data), ref = TileReference(coordinate: coordinate, sha256: hash, relativePath: "tiles/\(hash).png")
        let url = root.appendingPathComponent(ref.relativePath)
        var info = stat()
        let exists = lstat(url.path,&info) == 0
        guard exists || errno == ENOENT else { throw MeteocatError("No es pot comprovar el fragment local del radar.") }
        guard !exists || info.st_mode & S_IFMT == S_IFREG else { throw MeteocatError("El fragment local del radar té un enllaç o un tipus de fitxer no vàlid.") }
        if !exists || (try? tile(ref)) == nil {
            // Incoming PNG has already been verified. Atomic replacement repairs a regular
            // corrupt blob without leaving active/previous readers a missing-file interval.
            try reserve(data.count,protecting: [hash]); defer { reserved -= data.count }
            try write(data,to: url)
        }
        staged.insert(hash); index[key] = ref; indexDirty = true
        if index.count > 2048 {
            for oldKey in index.keys.sorted() where oldKey != key && !active.union(previous).union(protected).union(staged).contains(index[oldKey]!.sha256) {
                index.removeValue(forKey: oldKey); if index.count <= 2048 { break }
            }
        }
        // Persist identities even when a cycle stops before frame promotion.
        try persistIndex()
        return ref
    }
}

import XCTest
import Foundation
import CoreGraphics
@testable import MeteocatCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}
actor FakeHTTP: HTTPClient {
    enum Behavior: Sendable { case normal, metadata304, metadata429(String), tiles429, transportError, corrupt }
    var behavior: Behavior
    let body: Data, tile: Data
    var requests = [HTTPRequest](), active = 0, maximum = 0
    var preflight: (@Sendable () throws -> Void)?
    init(body: Data, tile: Data, behavior: Behavior = .normal, preflight: (@Sendable () throws -> Void)? = nil) { self.body = body; self.tile = tile; self.behavior = behavior; self.preflight = preflight }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try preflight?(); requests.append(request); active += 1; maximum = max(maximum,active)
        defer { active -= 1 }
        if request.url == RadarMetadata.url {
            switch behavior {
            case .metadata304: return HTTPResponse(status: 304,headers: ["etag":"tag2"])
            case .metadata429(let value): return HTTPResponse(status: 429,headers: ["retry-after":value])
            case .transportError: throw MeteocatError("Error injectat.")
            default: return HTTPResponse(status: 200,headers: ["ETag":"tag1","Last-Modified":"Wed, 07 Oct 2026 06:12:00 GMT"],body: body)
            }
        }
        if case .tiles429 = behavior {
            // Ignore cancellation to model concurrent responses extending the global deadline.
            let value = request.url.path.contains("/063/") ? "1200" : "600"
            try? await Task.sleep(nanoseconds: value == "1200" ? 30_000_000 : 10_000_000)
            return HTTPResponse(status: 429,headers: ["retry-after":value])
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        if case .corrupt = behavior { return HTTPResponse(status: 200,body: Data("bad".utf8)) }
        return HTTPResponse(status: 200,body: tile)
    }
    func change(_ behavior: Behavior) { self.behavior = behavior }
    func count() -> Int { requests.count }
    func stats() -> (Int,Int,[HTTPRequest]) { (requests.count,maximum,requests) }
}
final class CoreTests: XCTestCase {
    func date(_ text: String = "10/07/2026 06:12Z") throws -> Date { try RadarMetadata.parseUTC(text) }
    func metadata(_ obs: String = "10/07/2026 06:12Z", origin: String = "10/07/2026 06:00Z") -> Data { Data("dataServidor: '\(obs)', dataDarreraRadar: '\(obs)', dataDarreraAdveccio: '\(origin)'".utf8) }
    func temporary() throws -> URL {
        // FileManager enumeration returns physical paths; normalize the system temp alias too.
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        let root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
            .appendingPathComponent("meteocat-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func fixture() throws -> CacheManifest { try NativeJSON.decode(CacheManifest.self,AtomicFile.read(MeteocatResources.previewFixtureDirectory.appendingPathComponent("active.json"))) }
    func tileBytes() throws -> Data { let f = try fixture(); return try AtomicFile.read(MeteocatResources.previewFixtureDirectory.appendingPathComponent(f.frames[0].tiles[0].relativePath)) }
    func testStrictMetadataAndRollover() throws {
        let m = try RadarMetadata.parse(metadata()); XCTAssertEqual(m.observationUTC,try date())
        XCTAssertThrowsError(try RadarMetadata.parse(metadata()+metadata()))
        for bad in ["02/30/2026 06:12Z","13/01/2026 06:12Z","10/07/2026 24:00Z","07/10/2026 06:12+00:00"] { XCTAssertThrowsError(try RadarMetadata.parseUTC(bad)) }
        XCTAssertEqual(try date("01/02/2026 00:00Z"),ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
        let origin = try date("12/31/2026 23:54Z"), f = try FrameID(kind: .forecast,validUTC: origin.addingTimeInterval(360),originUTC: origin)
        XCTAssertEqual(try RadarMetadata.tileURL(f,coordinate: .init(x: 63,yTMS: 80)).absoluteString,"https://static-m.meteo.cat/tiles/adveccio/2026/12/31/2027/01/01/23/54/00/00/07/000/000/063/000/000/080.png")
        XCTAssertThrowsError(try FrameID(kind: .forecast,validUTC: origin.addingTimeInterval(60),originUTC: origin))
        XCTAssertThrowsError(try RadarMetadata.parse(metadata("10/07/2026 06:12Z",origin: "10/07/2026 06:24Z")))
    }
    func testProjectionFitAndSettings() async throws {
        let p = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let settings = try MeteocatResources.defaultSettings(); XCTAssertEqual(settings.cities.count,27); XCTAssertEqual(settings.shortcut,.defaultShortcut)
        let vilanova = try XCTUnwrap(settings.cities.first { $0.id == "mun:083073" })
        XCTAssertEqual(vilanova.name, "Vilanova i la Geltrú")
        XCTAssertTrue(vilanova.visible)
        XCTAssertEqual(vilanova.point.lon, 1 + 43.0 / 60 + 35.22 / 3600, accuracy: 1e-10)
        XCTAssertEqual(vilanova.point.lat, 41 + 13.0 / 60 + 26.87 / 3600, accuracy: 1e-10)
        let valls = settings.cities.first { $0.name == "Valls" }!, q = try p.project(valls.point), back = try p.unproject(q)
        XCTAssertEqual(q.x,285.77,accuracy: 0.1); XCTAssertEqual(back.lon,valls.point.lon,accuracy: 1e-10); XCTAssertEqual(back.lat,valls.point.lat,accuracy: 1e-10)
        let fit = p.fit(in: CGSize(width: 750,height: 470)); XCTAssertEqual(fit.rect.height,419.1176470588,accuracy: 1e-8); XCTAssertNil(fit.canonicalPoint(.zero)); XCTAssertEqual(fit.canonicalPoint(fit.viewPoint(q))!.x,q.x,accuracy: 1e-10)
        var invalid = settings; invalid.cities.append(valls); XCTAssertThrowsError(try SettingsStore.validate(invalid))
        invalid = settings; invalid.pin = .init(lon: 180,lat: 41); XCTAssertThrowsError(try SettingsStore.validate(invalid))
        invalid = settings; invalid.cities[0].name = String(repeating: "x",count: 41); XCTAssertThrowsError(try SettingsStore.validate(invalid))
        let root = try temporary(), url = root.appendingPathComponent("settings.json"); try AtomicFile.write(Data("bad".utf8),to: url)
        let store = try await SettingsStore.open(at: url); let notice = await store.recoveryNotice(); XCTAssertNotNil(notice)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("settings-malformed-") })
        var edited = settings; edited.cities[0].visible = false; edited.cities.removeLast(); edited.pin = valls.point
        try await store.save(edited); let reread = try await SettingsStore.open(at: url); let loaded = await reread.load(); XCTAssertEqual(loaded,edited)
    }
    func testPNGValidationAndTransparentTile() throws {
        let bytes = try tileBytes(), image = try PNGDecoder.decode(bytes,expectedHash: PNGDecoder.sha256(bytes))
        XCTAssertEqual(image.bytes.count,256*256*4); XCTAssertTrue(stride(from: 3,to: image.bytes.count,by: 4).allSatisfy { image.bytes[$0] == 0 })
        var crc = bytes; crc[crc.count/2] ^= 1; XCTAssertThrowsError(try PNGDecoder.decode(crc))
        XCTAssertThrowsError(try PNGDecoder.decode(bytes.dropLast()))
        XCTAssertThrowsError(try PNGDecoder.decode(bytes,expectedHash: String(repeating: "0",count: 64)))
        XCTAssertThrowsError(try PNGDecoder.decode(bytes,width: 255))
        XCTAssertThrowsError(try PNGDecoder.decode(Data(repeating: 0,count: PNGDecoder.maximumBytes+1)))
        var partial = try fixture().frames[0].tiles; partial.removeLast(); XCTAssertThrowsError(try CachedFrame(id: fixture().frames[0].id,tiles: partial))
    }
    func testTMSAndCrossfade() throws {
        var tiles = [TileCoordinate:RGBAImage]()
        for c in TileCoordinate.grid {
            var bytes = [UInt8](repeating: 0,count: 256*256*4)
            for y in 0..<256 { for x in 0..<256 { let k = (y*256+x)*4; bytes[k] = UInt8(c.yTMS); bytes[k+1] = UInt8(y); bytes[k+2] = UInt8(c.x); bytes[k+3] = 255 } }
            tiles[c] = try RGBAImage(width: 256,height: 256,bytes: Data(bytes))
        }
        let out = try WeatherRasterizer.rasterize(tiles); XCTAssertEqual(out.bytes[0],80); XCTAssertEqual(out.bytes[(379*680)*4],79)
        let a = try RGBAImage(width: 1,height: 1,bytes: Data([255,0,0,255])), b = try RGBAImage(width: 1,height: 1,bytes: Data([255,0,0,255]))
        XCTAssertEqual(try WeatherRasterizer.blendedPremultiplied(from: a,to: b,progress: 0.5),a.bytes)
        let transparent = try RGBAImage(width: 1,height: 1,bytes: Data([100,100,255,0]))
        XCTAssertEqual(try WeatherRasterizer.blendedPremultiplied(from: transparent,to: transparent,progress: 0.5),Data([0,0,0,0]))
        let from = try FrameID(kind: .observation,validUTC: date()), to = try FrameID(kind: .observation,validUTC: date().addingTimeInterval(360))
        func eligible(_ playing: Bool = true,_ adjacent: Bool = true,_ wrap: Bool = false,_ changed: Bool = false) -> Bool { FrameTransition.canCrossfade(from: from,to: to,isAdjacent: adjacent,isPlaying: playing,isLoopWrap: wrap,generationChanged: changed) }
        XCTAssertTrue(eligible()); XCTAssertFalse(eligible(false)); XCTAssertFalse(eligible(true,false)); XCTAssertFalse(eligible(true,true,true)); XCTAssertFalse(eligible(true,true,false,true))
        let f = try FrameID(kind: .forecast,validUTC: to.validUTC,originUTC: from.validUTC)
        XCTAssertTrue(FrameTransition.canCrossfade(from: from,to: f,isAdjacent: true,isPlaying: true,isLoopWrap: false,generationChanged: false))
        let gap = try FrameID(kind: .forecast,validUTC: from.validUTC.addingTimeInterval(720),originUTC: from.validUTC)
        XCTAssertFalse(FrameTransition.canCrossfade(from: from,to: gap,isAdjacent: true,isPlaying: true,isLoopWrap: false,generationChanged: false))
        let changedRun = try FrameID(kind: .forecast,validUTC: f.validUTC.addingTimeInterval(360),originUTC: f.originUTC!.addingTimeInterval(360))
        XCTAssertFalse(FrameTransition.canCrossfade(from: f,to: changedRun,isAdjacent: true,isPlaying: true,isLoopWrap: false,generationChanged: false))
        XCTAssertFalse(FrameTransition.canCrossfade(from: f,to: from,isAdjacent: true,isPlaying: true,isLoopWrap: false,generationChanged: false))
    }
    func testIndependentRawRGBAReference() async throws {
        let fixture = try fixture(), id = fixture.frames.first { $0.id.validUTC == (try? date("10/07/2026 05:48Z")) && $0.id.kind == .observation }!.id
        let http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: try temporary(),mode: .fixture(directory: MeteocatResources.previewFixtureDirectory,referenceUTC: MeteocatResources.fixtureReferenceUTC()),client: http,now: { Date() })
        let actual = try await service.weather(for: id)
        let reference = try PNGDecoder.decode(AtomicFile.read(Bundle.module.resourceURL!.appendingPathComponent("Fixtures/independent-precipitation.png")),width: 680,height: 380)
        XCTAssertEqual(actual.bytes,reference.bytes,"All 258400 straight RGBA pixels must match independently reconstructed reference")
        await service.activateAndRefresh(); let count = await http.count(); XCTAssertEqual(count,0)
        let snapshot = await service.current(); XCTAssertEqual(snapshot.observations.count,11); XCTAssertEqual(snapshot.forecast.count,10); XCTAssertEqual(snapshot.visibleTimeline.count,19)
        print("RGBA audit sha256=\(PNGDecoder.sha256(actual.bytes)) pixels=258400 mismatch=0")
        await service.shutdown()
    }
    @MainActor func testGeographyParsesAndDrawsNorthUp() throws {
        let g = try Geography(directory: MeteocatResources.geographyDirectory), p = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        var bytes = [UInt8](repeating: 0,count: 680*380*4)
        let ctx = CGContext(data: &bytes,width: 680,height: 380,bitsPerComponent: 8,bytesPerRow: 680*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Quartz bitmap contexts start unflipped. Convert once to the required y-down contract.
        ctx.translateBy(x: 0,y: 380); ctx.scaleBy(x: 1,y: -1)
        g.drawUnderlay(in: ctx,fit: p.fit(in: CGSize(width: 680,height: 380))); g.drawBoundaries(in: ctx,fit: p.fit(in: CGSize(width: 680,height: 380)))
        XCTAssertTrue(bytes.contains { $0 != 0 }); XCTAssertEqual(bytes[3],255)
    }
    func testServicePreflightDedupeWarm304AndExpiry() async throws {
        let root = try temporary(), clock = TestClock(try date())
        let http = FakeHTTP(body: metadata(),tile: try tileBytes(),preflight: {
            let gate = try NativeJSON.decode(AdmissionGate.self,AtomicFile.read(root.appendingPathComponent("gate.json")))
            guard gate.nextCycleAt >= clock.now().addingTimeInterval(360) else { throw MeteocatError("Gate no desat abans del GET.") }
        })
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let initialCount = await http.count(); XCTAssertEqual(initialCount,0)
        await service.activateAndRefresh()
        let stats = await http.stats(); XCTAssertEqual(stats.0,127); XCTAssertEqual(stats.1,3); XCTAssertEqual(Set(stats.2.map { $0.url }).count,127)
        let s = await service.current(); XCTAssertEqual(s.observations.count,11); XCTAssertEqual(s.forecast.count,10)
        await service.refreshIfEligible(); let count = await http.count(); XCTAssertEqual(count,127)
        await service.setViewerVisible(false); await service.shutdown()
        clock.advance(380)
        await http.change(.metadata304)
        // 304 checkedAt changes without treating old dataServidor as current weather.
        let warm = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await warm.activateAndRefresh(); let warmStats = await http.stats(); XCTAssertEqual(warmStats.0,128)
        XCTAssertEqual(warmStats.2.last!.headers["If-None-Match"],"tag1")
        let warmed = await warm.current(); XCTAssertEqual(warmed.checkedAt,clock.now()); XCTAssertEqual(warmed.observations.last!.id.validUTC,try date())
        clock.advance(3600); let expired = await warm.current(); XCTAssertTrue(expired.forecast.isEmpty); XCTAssertTrue(expired.observationsAreStale(at: clock.now()))
        await warm.shutdown()
    }
    func test429MaximumAndMalformedGate() async throws {
        let root = try temporary(), clock = TestClock(try date()), http = FakeHTTP(body: metadata(),tile: try tileBytes(),behavior: .tiles429)
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await service.activateAndRefresh()
        let gate = try NativeJSON.decode(AdmissionGate.self,AtomicFile.read(root.appendingPathComponent("gate.json")))
        XCTAssertEqual(gate.blockedUntil,clock.now().addingTimeInterval(1200)); let stats = await http.stats(); XCTAssertEqual(stats.0,4); XCTAssertLessThanOrEqual(stats.1,3)
        await service.shutdown()
        let badRoot = try temporary(); try AtomicFile.write(Data("broken".utf8),to: badRoot.appendingPathComponent("gate.json"))
        let badHTTP = FakeHTTP(body: metadata(),tile: try tileBytes())
        let bad = try await RadarService.open(cacheRoot: badRoot,mode: .live,client: badHTTP,now: { clock.now() }, scheduler: clock.scheduler); await bad.activateAndRefresh()
        let count = await badHTTP.count(); XCTAssertEqual(count,0); await bad.shutdown()
        XCTAssertEqual(RadarMetadata.retryDeadline("Wed, 07 Oct 2026 07:12:00 GMT",now: try date()),try date().addingTimeInterval(3600))
        XCTAssertEqual(RadarMetadata.retryDeadline("bad",now: try date()),try date().addingTimeInterval(360))
    }
    func test304WithoutMetadataAndPreflightWriteFailure() async throws {
        let clock = TestClock(try date()), http = FakeHTTP(body: metadata(),tile: try tileBytes(),behavior: .metadata304)
        let service = try await RadarService.open(cacheRoot: try temporary(),mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler); await service.activateAndRefresh()
        let snap = await service.current(); XCTAssertTrue(snap.observations.isEmpty); XCTAssertNotNil(snap.observationError); let count = await http.count(); XCTAssertEqual(count,1); await service.shutdown()
        let root = try temporary(); try FileManager.default.createDirectory(at: root.appendingPathComponent("gate.json"),withIntermediateDirectories: true)
        let noHTTP = FakeHTTP(body: metadata(),tile: try tileBytes())
        let failing = try await RadarService.open(cacheRoot: root,mode: .live,client: noHTTP,now: { clock.now() }, scheduler: clock.scheduler)
        clock.advance(361); await failing.activateAndRefresh(); let zero = await noHTTP.count(); XCTAssertEqual(zero,0); await failing.shutdown()
    }
    func testBudgetProtectsDisplayedAndAtomicForecast() throws {
        let root = try temporary(), data = try tileBytes(), hash = PNGDecoder.sha256(data)
        let disk = DiskCache(root: root,budget: 4096)
        try AtomicFile.write(data,to: root.appendingPathComponent("tiles/\(hash).png")); disk.protected = [hash]
        XCTAssertThrowsError(try disk.reserve(4096)); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("tiles/\(hash).png").path))
        let manifest = try fixture(); try manifest.validate()
        let forecasts = manifest.frames.filter { $0.id.kind == .forecast }; XCTAssertThrowsError(try CacheManifest(frames: Array(forecasts.prefix(9)),checkedAt: nil).validate())
        let old = forecasts[0], newID = try FrameID(kind: .forecast,validUTC: old.id.validUTC.addingTimeInterval(360),originUTC: old.id.originUTC!.addingTimeInterval(360))
        let mixed = try CachedFrame(id: newID,tiles: old.tiles); XCTAssertThrowsError(try CacheManifest(frames: [mixed]+Array(forecasts.dropFirst()),checkedAt: nil).validate())
    }
}

extension CoreTests {
    func copyFixture(to root: URL) throws {
        let source = MeteocatResources.previewFixtureDirectory
        for name in ["active.json","snapshot-info.json","tiles"] { try FileManager.default.copyItem(at: source.appendingPathComponent(name),to: root.appendingPathComponent(name)) }
    }
    func testWarmOverlapOnlyDownloadsNewIdentitiesAndPreservesSelection() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let old = try fixture().frames.first!.id, clock = TestClock(try date("10/07/2026 06:30Z"))
        let http = FakeHTTP(body: metadata("10/07/2026 06:18Z"),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await service.protectDisplayed([old]); await service.activateAndRefresh()
        let stats = await http.stats(); XCTAssertEqual(stats.0,7,"One metadata and six tiles for the new observation only")
        let snapshot = await service.current(); XCTAssertEqual(snapshot.observations.count,11); XCTAssertEqual(snapshot.forecast.count,10)
        XCTAssertEqual(snapshot.observations.first!.id.validUTC,try date("10/07/2026 05:18Z"))
        _ = try await service.weather(for: old)
        await service.setViewerVisible(false); await service.shutdown()
    }
    func testFailedForecastReplacementRetainsOldAtomicBlockAndLatestObservation() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let clock = TestClock(try date("10/07/2026 06:30Z"))
        let http = FakeHTTP(body: metadata(origin: "10/07/2026 06:12Z"),tile: try tileBytes(),behavior: .corrupt)
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await service.activateAndRefresh()
        let snapshot = await service.current()
        XCTAssertEqual(snapshot.observations.count,11); XCTAssertEqual(snapshot.forecast.count,10)
        XCTAssertTrue(snapshot.forecast.allSatisfy { $0.id.originUTC == (try? date("10/07/2026 06:00Z")) })
        XCTAssertNotNil(snapshot.forecastError)
        let saved = try NativeJSON.decode(CacheManifest.self,AtomicFile.read(root.appendingPathComponent("active.json"))); try saved.validate()
        XCTAssertEqual(Set(saved.frames.filter { $0.id.kind == .forecast }.map { $0.id.originUTC }),[try date("10/07/2026 06:00Z")])
        await service.shutdown()
    }
    func testConcurrentServicesCannotAdmitSecondCycleAndStreamImmediate() async throws {
        let root = try temporary(), clock = TestClock(try date()), http = FakeHTTP(body: metadata(),tile: try tileBytes(),behavior: .metadata429("600"))
        let a = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let b = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let stream = await a.snapshots(); var iterator = stream.makeAsyncIterator(); let initial = await iterator.next(); XCTAssertNotNil(initial)
        async let first: Void = a.activateAndRefresh()
        async let second: Void = b.activateAndRefresh()
        _ = await (first,second)
        let count = await http.count(); XCTAssertEqual(count,1)
        let gate = try NativeJSON.decode(AdmissionGate.self,AtomicFile.read(root.appendingPathComponent("gate.json")))
        XCTAssertEqual(gate.deadline,clock.now().addingTimeInterval(600))
        await a.shutdown(); await b.shutdown()
    }
    func testHideKeepsCycleAndWeatherNeverFetches() async throws {
        let root = try temporary(), clock = TestClock(try date()), http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let opening = Task { await service.activateAndRefresh() }
        await service.setViewerVisible(false); await opening.value
        let before = await http.count(); XCTAssertEqual(before,127)
        let missing = try FrameID(kind: .observation,validUTC: date("01/01/2025 00:00Z"))
        do { _ = try await service.weather(for: missing); XCTFail("Absent image must fail") } catch { }
        let cached = await service.current()
        _ = try await service.weather(for: cached.observations.last!.id)
        let after = await http.count(); XCTAssertEqual(before,after)
        await service.shutdown()
    }
    func testDurablePartialTileIndexAndPNGCorruptionKeepsLastObservation() async throws {
        let root = try temporary(), disk = DiskCache(root: root), id = try FrameID(kind: .observation,validUTC: date()), tile = try tileBytes(), c = TileCoordinate.grid[0]
        let key = id.storageKey + ":\(c.z):\(c.x):\(c.yTMS)"
        let reference = try disk.store(tile,coordinate: c,key: key)
        let reopened = DiskCache(root: root); _ = try reopened.load(); XCTAssertEqual(reopened.index[key]?.sha256,reference.sha256)
        XCTAssertNoThrow(try reopened.tile(reference))
        var damaged = tile; damaged[20] ^= 1; try AtomicFile.write(damaged,to: root.appendingPathComponent(reference.relativePath)); XCTAssertThrowsError(try reopened.tile(reference))
    }
    func testImporterRefusesTraversalSymlinkAndChangedManifestShape() throws {
        let source = try temporary(), destination = try temporary().appendingPathComponent("output")
        let bad = "{\"version\":1,\"checkedAt\":1791354520115,\"frames\":[{\"kind\":\"observation\",\"validUTC\":\"2026-10-07T05:12:00.000Z\",\"tiles\":[{\"x\":63,\"y\":79,\"file\":\"../escape.png\",\"sha256\":\"\(String(repeating: "0",count: 64))\"}]}]}"
        try AtomicFile.write(Data(bad.utf8),to: source.appendingPathComponent("active.json")); XCTAssertThrowsError(try FixtureImporter.importSnapshot(source: source,destination: destination)); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let actual = try temporary(); try copyFixture(to: actual)
        let tiles = actual.appendingPathComponent("tiles"), renamed = actual.appendingPathComponent("real-tiles")
        try FileManager.default.moveItem(at: tiles,to: renamed); try FileManager.default.createSymbolicLink(at: tiles,withDestinationURL: renamed)
        XCTAssertThrowsError(try FixtureImporter.importSnapshot(source: actual,destination: destination))
    }
    @MainActor func testGeographyRejectsUnsupportedVocabulary() throws {
        let dir = try temporary()
        let svg = Data("<svg width=\"680\" height=\"380\" viewBox=\"0 0 680 380\"><path d=\"M0 0 C1 1 2 2 3 3\"/></svg>".utf8)
        try AtomicFile.write(svg,to: dir.appendingPathComponent("layer-under.svg")); try AtomicFile.write(svg,to: dir.appendingPathComponent("paths.svg"))
        XCTAssertThrowsError(try Geography(directory: dir))
    }
}

extension CoreTests {
    func testSourceAuditRetainsPartialAlphaAndTransparentRGB() throws {
        let dir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        for name in ["alpha-rgba.png","alpha-paletted.png"] {
            let image = try PNGDecoder.decode(AtomicFile.read(dir.appendingPathComponent(name)))
            for pixel in stride(from: 0,to: image.bytes.count,by: 4) { XCTAssertEqual(Array(image.bytes[pixel..<pixel+4]),[13,57,229,127]) }
        }
        let transparent = try PNGDecoder.decode(AtomicFile.read(dir.appendingPathComponent("transparent-colored.png")))
        XCTAssertEqual(Array(transparent.bytes.prefix(4)),[13,57,229,0])
        let single = try RGBAImage(width: 1,height: 1,bytes: Data(transparent.bytes.prefix(4)))
        XCTAssertEqual(try WeatherRasterizer.blendedPremultiplied(from: single,to: single,progress: 0.5),Data([0,0,0,0]))
    }
    @MainActor func testVectorRelativeRepeatedPairsEvenOddStylesAndNorthUp() throws {
        let dir = try temporary()
        let svg = "<svg width=\"680\" height=\"380\" viewBox=\"0 0 680 380\" fill-rule=\"evenodd\"><defs><clipPath id=\"frame\"><rect width=\"680\" height=\"380\" rx=\"10\"/></clipPath><path id=\"shape\" d=\"m20 20 80 0 0 80 -80 0z m20 20 0 40 40 0 0 -40z\"/></defs><g clip-path=\"url(#frame)\" fill=\"#00ff00\"><use href=\"#shape\"/></g></svg>"
        try AtomicFile.write(Data(svg.utf8),to: dir.appendingPathComponent("layer-under.svg"))
        try AtomicFile.write(Data("<svg width=\"680\" height=\"380\" viewBox=\"0 0 680 380\"/>".utf8),to: dir.appendingPathComponent("paths.svg"))
        let geography = try Geography(directory: dir)
        var data = [UInt8](repeating: 0,count: 680*380*4)
        let context = CGContext(data: &data,width: 680,height: 380,bitsPerComponent: 8,bytesPerRow: 680*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0,y: 380); context.scaleBy(x: 1,y: -1)
        let fit = MapFit(scale: 1,offset: .zero,rect: CGRect(x: 0,y: 0,width: 680,height: 380)); geography.drawUnderlay(in: context,fit: fit)
        XCTAssertEqual(Array(data[(30*680+30)*4..<(30*680+30)*4+4]),[0,255,0,255])
        XCTAssertEqual(data[(50*680+50)*4+3],0,"Even-odd local use hole stays transparent")
        XCTAssertEqual(data[(350*680+30)*4+3],0,"North path must not be vertically flipped")
    }
}

extension CoreTests {
    func testReadOnlyOpenFallsBackToValidatedPreviousManifest() async throws {
        let root = try temporary(); try copyFixture(to: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent("active.json"),to: root.appendingPathComponent("previous.json"))
        let corrupt = Data("corrupt manifest".utf8); try AtomicFile.write(corrupt,to: root.appendingPathComponent("active.json"))
        let http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let reference = try date("10/07/2026 06:30Z")
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        let snapshot = await service.current(); XCTAssertEqual(snapshot.observations.count,11); XCTAssertNotNil(snapshot.observationError)
        XCTAssertEqual(try AtomicFile.read(root.appendingPathComponent("active.json")),corrupt,"open must remain read-only")
        let count = await http.count(); XCTAssertEqual(count,0); await service.shutdown()
    }
}

extension CoreTests {
    func testBudgetEvictsUnusedToLowWaterAndProtectsAllClasses() throws {
        let root = try temporary(), disk = DiskCache(root: root,budget: 20000)
        let hashes = (0..<16).map { String(format: "%064x",$0) }
        for hash in hashes { try AtomicFile.write(Data(repeating: 0,count: 1000),to: root.appendingPathComponent("tiles/\(hash).png")) }
        disk.active = [hashes[0]]; disk.previous = [hashes[1]]; disk.protected = [hashes[2]]; disk.staged = [hashes[3]]
        try disk.reserve(6000)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tiles").path)
        XCTAssertEqual(remaining.count,12)
        for hash in hashes.prefix(4) { XCTAssertTrue(remaining.contains("\(hash).png")) }
        disk.reserved -= 6000
    }
}


extension CoreTests {
    func testDurableRetryAfterCapsBeyondCalendarFormattingRange() throws {
        let now = try date(), until = RadarMetadata.retryDeadline(String(repeating: "9",count: 40),now: now)
        let gate = AdmissionGate(nextCycleAt: until,blockedUntil: until)
        let encoded = try NativeJSON.encode(gate), decoded = try NativeJSON.decode(AdmissionGate.self,encoded)
        XCTAssertEqual(decoded.deadline,until); XCTAssertEqual(decoded.deadline,now.addingTimeInterval(86400))
    }
}

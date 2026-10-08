import XCTest
import Foundation
@testable import MeteocatCore

actor HistoryHTTP: HTTPClient {
    let body: Data, tile: Data, missingPath: String, status: Int
    var requests = [HTTPRequest]()
    init(body: Data, tile: Data, missingPath: String, status: Int) {
        self.body = body; self.tile = tile; self.missingPath = missingPath; self.status = status
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url == RadarMetadata.url { return HTTPResponse(status: 200,body: body) }
        if request.url.path.contains(missingPath) {
            if status == -1 { throw MeteocatError("Error de transport injectat.") }
            return HTTPResponse(status: status)
        }
        return HTTPResponse(status: 200,body: tile)
    }
    func urls() -> [URL] { requests.map(\.url) }
}

actor PausedMetadataHTTP: HTTPClient {
    let body: Data, tile: Data
    private var started = false
    private var waiting: CheckedContinuation<Void,Never>?
    private var response: CheckedContinuation<HTTPResponse,Never>?
    init(body: Data, tile: Data) { self.body = body; self.tile = tile }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url != RadarMetadata.url { return HTTPResponse(status: 200,body: tile) }
        return await withCheckedContinuation { continuation in
            response = continuation; started = true; waiting?.resume(); waiting = nil
        }
    }
    func waitForMetadata() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() { response?.resume(returning: HTTPResponse(status: 200,body: body)); response = nil }
}

extension CoreTests {
    func testRepairLiveMixedUTCFormats() throws {
        // Literal fields observed on the official page on 2026-10-07; forecast now uses ISO UTC.
        let body = Data("dataServidor: '10/07/2026 09:24Z', dataDarreraRadar: '10/07/2026 09:12Z', dataDarreraAdveccio: '2026-10-07T09:12:00+00:00'".utf8)
        let metadata = try RadarMetadata.parse(body)
        XCTAssertEqual(metadata.originUTC,metadata.observationUTC)
        XCTAssertEqual(try RadarMetadata.parseUTC("2026-10-07T09:12:00Z"),metadata.originUTC)
        XCTAssertEqual(try RadarMetadata.candidates(metadata).forecast.count,10)
        for value in ["2026-10-07T09:12:00+01:00", "2026-02-30T09:12:00Z", "2026-10-07T09:12:60Z", "2026-10-07T09:12:00Z\n", "٢٠٢٦-10-07T09:12:00Z"] {
            XCTAssertThrowsError(try RadarMetadata.parseUTC(value))
        }
    }
    func testRepairFirstInstallWithMissingCacheParents() async throws {
        let base = try temporary()
        let root = base.appendingPathComponent("new-install/radar-v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let reference = try date("10/07/2026 06:30Z")
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),"Open must remain read-only")
        await service.activateAndRefresh()
        let snapshot = await service.current()
        XCTAssertEqual(snapshot.observations.count,11)
        XCTAssertEqual(snapshot.forecast.count,10)
        try DiskCache(root: root).load().validate()
        await service.shutdown()
    }
    func testRepairWarmStatusKeepsGenerationAndPrevious() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let previous = root.appendingPathComponent("previous.json")
        let original = try AtomicFile.read(root.appendingPathComponent("active.json"))
        try AtomicFile.write(original,to: previous)
        let previousDate = try previous.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let clock = TestClock(try date("10/07/2026 06:30Z")), http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let before = await service.current()
        let stream = await service.snapshots(); var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        await service.activateAndRefresh()
        let after = await service.current(), update = await iterator.next()
        XCTAssertEqual(after.revision,before.revision)
        XCTAssertEqual(update?.revision,before.revision,"Status stream still yields without changing content generation")
        XCTAssertEqual(after.checkedAt,clock.now())
        XCTAssertEqual(try AtomicFile.read(previous),original)
        XCTAssertEqual(try previous.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,previousDate)
        for _ in 0..<15 { await service.setViewerVisible(false); await service.activateAndRefresh() }
        let deferred = await service.current(); XCTAssertEqual(deferred.revision,before.revision)
        let count = await http.count(); XCTAssertEqual(count,1)
        clock.advance(1800)
        let expired = await service.current(); XCTAssertTrue(expired.forecast.isEmpty); XCTAssertEqual(expired.revision,before.revision+1)
        let expiredAgain = await service.current(); XCTAssertEqual(expiredAgain.revision,expired.revision)
        await service.shutdown()
    }
    func testRepairTimelinePromotionChangesGeneration() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let reference = try date("10/07/2026 06:30Z"), http = FakeHTTP(body: metadata("10/07/2026 06:18Z"),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        let before = await service.current(); await service.activateAndRefresh(); let after = await service.current()
        XCTAssertEqual(after.revision,before.revision+1,"One new observation, status changes and warm history must not add generations")
        await service.shutdown()
    }
    func testRepairSharedCorruptionRecoversReadOnlyAndRefreshes() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let original = try AtomicFile.read(root.appendingPathComponent("active.json"))
        try AtomicFile.write(original,to: root.appendingPathComponent("previous.json"))
        let victim = try fixture().frames[0].tiles[0], url = root.appendingPathComponent(victim.relativePath)
        var damaged = try AtomicFile.read(url); damaged[30] ^= 1; try AtomicFile.write(damaged,to: url)
        let disk = DiskCache(root: root), salvaged = try disk.load(); try salvaged.validate()
        XCTAssertNotNil(disk.recoveryNotice)
        for frame in salvaged.frames { for ref in frame.tiles { XCTAssertNoThrow(try disk.tile(ref)) } }
        XCTAssertTrue(salvaged.frames.filter { $0.id.kind == .forecast }.isEmpty || salvaged.frames.filter { $0.id.kind == .forecast }.count == 10)
        XCTAssertEqual(try AtomicFile.read(root.appendingPathComponent("active.json")),original)
        XCTAssertEqual(try AtomicFile.read(url),damaged)
        let http = FakeHTTP(body: metadata(),tile: try tileBytes()), reference = try date("10/07/2026 06:30Z")
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        let count = await http.count(); XCTAssertEqual(count,0)
        let recovered = await service.current(); XCTAssertNotNil(recovered.observationError)
        await service.activateAndRefresh(); let refreshed = await service.current()
        XCTAssertEqual(refreshed.observations.count,11); XCTAssertEqual(refreshed.forecast.count,10)
        XCTAssertNil(refreshed.observationError,"Successful repair must clear its stale corruption notice")
        let saved = try DiskCache(root: root).load(); try saved.validate()
        await service.shutdown()
    }
    func testRepairOlderForecastOriginKeepsNewerCompleteForecast() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let reference = try date("10/07/2026 06:30Z")
        let http = HistoryHTTP(body: metadata("10/07/2026 06:12Z",origin: "10/07/2026 05:54Z"),tile: try tileBytes(),missingPath: "no-missing-path",status: 404)
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        let before = await service.current()
        await service.activateAndRefresh()
        let after = await service.current(), urls = await http.urls()
        XCTAssertEqual(after.forecast.map(\.id),before.forecast.map(\.id))
        XCTAssertEqual(after.revision,before.revision)
        XCTAssertFalse(urls.contains { $0.path.contains("/adveccio/") })
        XCTAssertEqual(urls.count,1)
        await service.shutdown()
    }
    func testRepairCorruptBlobReplacementAndSymlinkRefusal() throws {
        let root = try temporary(), disk = DiskCache(root: root), data = try tileBytes(), c = TileCoordinate.grid[0]
        let ref = try disk.store(data,coordinate: c,key: "one"), url = root.appendingPathComponent(ref.relativePath)
        var damaged = data; damaged[30] ^= 1; try AtomicFile.write(damaged,to: url)
        _ = try disk.store(data,coordinate: c,key: "two"); XCTAssertEqual(try disk.tile(ref),data)
        let outside = root.appendingPathComponent("outside.png"); try AtomicFile.write(damaged,to: outside)
        try FileManager.default.removeItem(at: url); try FileManager.default.createSymbolicLink(at: url,withDestinationURL: outside)
        XCTAssertThrowsError(try disk.store(data,coordinate: c,key: "three"))
        XCTAssertEqual(try AtomicFile.read(outside),damaged)
    }
    func testRepairUnsafeManifestRecoversEmptyWithoutReadingPaths() throws {
        let root = try temporary(); try copyFixture(to: root)
        let original = try AtomicFile.read(root.appendingPathComponent("active.json"))
        var json = try JSONSerialization.jsonObject(with: original) as! [String:Any]
        var frames = json["frames"] as! [[String:Any]], tiles = frames[0]["tiles"] as! [[String:Any]]
        tiles[0]["relativePath"] = "../outside.png"; frames[0]["tiles"] = tiles; json["frames"] = frames
        let bad = try JSONSerialization.data(withJSONObject: json)
        try AtomicFile.write(bad,to: root.appendingPathComponent("active.json")); try AtomicFile.write(bad,to: root.appendingPathComponent("previous.json"))
        let disk = DiskCache(root: root); XCTAssertTrue(try disk.load().frames.isEmpty); XCTAssertNotNil(disk.recoveryNotice)
    }
    func testRepairASCIIUTCRejectsUnicodeAndNewlines() throws {
        for bad in ["١٠/٠٧/٢٠٢٦ ٠٦:١٢Z","１０/０７/２０２６ ０６:１２Z","10/07/2026 06:12Z\n","10/07/2026 06:12Z\r\n","10/07/2026 06:12Z\u{2028}"] {
            XCTAssertThrowsError(try RadarMetadata.parseUTC(bad))
        }
        XCTAssertThrowsError(try RadarMetadata.parse(metadata("10/07/2026 06:12Z\n")))
        XCTAssertEqual(try date("01/01/2027 00:00Z"),try date("12/31/2026 23:54Z").addingTimeInterval(360))
    }
    func testRepairHistoricMissingContinuesAtomicForecast() async throws {
        for status in [404,410] {
            let root = try temporary(), reference = try date("10/07/2026 06:34Z")
            let http = HistoryHTTP(body: metadata("10/07/2026 06:18Z",origin: "10/07/2026 06:18Z"),tile: try tileBytes(),missingPath: "/radar/2026/10/07/05/",status: status)
            let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
            await service.activateAndRefresh(); let snap = await service.current(), urls = await http.urls()
            XCTAssertEqual(snap.observations.count,4); XCTAssertFalse(snap.historyComplete); XCTAssertNotNil(snap.observationError)
            XCTAssertEqual(snap.forecast.count,10); XCTAssertNil(snap.forecastError)
            XCTAssertEqual(urls.filter { $0.path.contains("/adveccio/") }.count,60)
            XCTAssertEqual(snap.nextEligibleAt,reference.addingTimeInterval(380))
            try DiskCache(root: root).load().validate(); await service.shutdown()
        }
    }
    func testRepairLatestMissingRetainsLastGoodAndCanRefreshForecast() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let reference = try date("10/07/2026 06:34Z")
        let http = HistoryHTTP(body: metadata("10/07/2026 06:18Z",origin: "10/07/2026 06:18Z"),tile: try tileBytes(),missingPath: "/radar/2026/10/07/06/18/",status: 404)
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        await service.activateAndRefresh(); let snap = await service.current()
        XCTAssertEqual(snap.observations.last?.id.validUTC,try date()); XCTAssertNotNil(snap.observationError)
        XCTAssertEqual(snap.forecast.first?.id.originUTC,try date("10/07/2026 06:18Z")); XCTAssertEqual(snap.forecast.count,10)
        await service.shutdown()
    }
    func testRepairHistoricServerFailureStillStopsCycle() async throws {
        for status in [429,503,-1] {
        let reference = try date("10/07/2026 06:34Z")
        let http = HistoryHTTP(body: metadata("10/07/2026 06:18Z",origin: "10/07/2026 06:18Z"),tile: try tileBytes(),missingPath: "/radar/2026/10/07/05/",status: status)
        let service = try await RadarService.open(cacheRoot: try temporary(),mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        await service.activateAndRefresh(); let snap = await service.current(), urls = await http.urls()
        XCTAssertEqual(snap.observations.count,4); XCTAssertTrue(snap.forecast.isEmpty)
        XCTAssertFalse(urls.contains { $0.path.contains("/adveccio/") }); XCTAssertNotNil(snap.observationError)
        await service.refreshIfEligible(); let again = await http.urls(); XCTAssertEqual(again.count,urls.count)
        await service.shutdown()
        }
    }
    func testRepairMetadataFreshnessAndRegressionBeforeTileRequests() async throws {
        let reference = try date("10/07/2026 06:30Z")
        for body in [metadata("10/07/2026 05:30Z",origin: "10/07/2026 05:00Z"),metadata("10/07/2026 05:24Z",origin: "10/07/2026 05:00Z"),metadata("10/07/2026 06:42Z")] {
            let root = try temporary(); try copyFixture(to: root)
            let original = try AtomicFile.read(root.appendingPathComponent("active.json"))
            let http = FakeHTTP(body: body,tile: try tileBytes())
            let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
            await service.activateAndRefresh(); let snap = await service.current(), count = await http.count()
            XCTAssertEqual(count,1); XCTAssertEqual(snap.observations.last?.id.validUTC,try date()); XCTAssertNotNil(snap.observationError)
            XCTAssertEqual(try AtomicFile.read(root.appendingPathComponent("active.json")),original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata.json").path))
            await service.shutdown()
        }
    }
    func testRepairStale304DoesNotRevalidateWeatherOrReplaceMetadata() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let m = try RadarMetadata.parse(metadata()), record = MetadataRecord(body: metadata(),metadata: m,etag: "old",lastModified: nil,checkedAt: try date())
        let recordBytes = try NativeJSON.encode(record); try AtomicFile.write(recordBytes,to: root.appendingPathComponent("metadata.json"))
        let reference = try date("10/07/2026 07:18Z"), http = FakeHTTP(body: metadata(),tile: try tileBytes(),behavior: .metadata304)
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        await service.activateAndRefresh(); let snap = await service.current(), count = await http.count()
        XCTAssertEqual(count,1); XCTAssertNotNil(snap.observationError); XCTAssertEqual(snap.checkedAt,try fixture().checkedAt)
        XCTAssertEqual(try AtomicFile.read(root.appendingPathComponent("metadata.json")),recordBytes)
        await service.shutdown()
    }
    func testRepairRetryAfterCapsHugeSecondsAndDates() throws {
        let now = try date()
        for raw in [String(repeating: "9",count: 300),String(repeating: "9",count: 400),"999999", "Wed, 07 Oct 2037 07:12:00 GMT"] {
            XCTAssertEqual(RadarMetadata.retryDeadline(raw,now: now),now.addingTimeInterval(86400))
        }
        XCTAssertEqual(RadarMetadata.retryDeadline("Wed, 07 Oct 2026 07:12:00 GMT",now: now),now.addingTimeInterval(3600))
        for raw in ["0","-5","1e300","bad"] { XCTAssertEqual(RadarMetadata.retryDeadline(raw,now: now),now.addingTimeInterval(360)) }
    }
    func testRepairShortcutNeedsPhysicalModifierAndRecoveryNotice() async throws {
        for modifiers: UInt32 in [0,0x400,0x200,0x600] {
            var settings = try MeteocatResources.defaultSettings(); settings.shortcut = Shortcut(keyCode: 15,carbonModifiers: modifiers)
            XCTAssertThrowsError(try SettingsStore.validate(settings))
        }
        for modifiers: UInt32 in [0x100,0x800,0x1000,0x1900] {
            var settings = try MeteocatResources.defaultSettings(); settings.shortcut = Shortcut(keyCode: 15,carbonModifiers: modifiers)
            XCTAssertNoThrow(try SettingsStore.validate(settings))
        }
        var settings = try MeteocatResources.defaultSettings(); settings.shortcut = Shortcut(keyCode: 128,carbonModifiers: 0x100)
        XCTAssertThrowsError(try SettingsStore.validate(settings))
        settings.shortcut = Shortcut(keyCode: 15,carbonModifiers: 0)
        let root = try temporary(), url = root.appendingPathComponent("settings.json"), bytes = try NativeJSON.encode(settings)
        try AtomicFile.write(bytes,to: url); let store = try await SettingsStore.open(at: url)
        let recovered = await store.load(), notice = await store.recoveryNotice(); XCTAssertEqual(recovered.shortcut,.defaultShortcut); XCTAssertNotNil(notice)
        let backup = try FileManager.default.contentsOfDirectory(at: root,includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("settings-malformed-") }!
        XCTAssertEqual(try AtomicFile.read(backup),bytes)
    }
}

extension CoreTests {
    func testRepairIndexVerifiesSourceCoordinateAndBytesBeforeAtomicRepair() throws {
        let root = try temporary(), disk = DiskCache(root: root), id = try FrameID(kind: .observation,validUTC: date())
        let c = TileCoordinate.grid[0], other = TileCoordinate.grid[1], good = try tileBytes()
        let key = id.storageKey + ":\(c.z):\(c.x):\(c.yTMS)"
        let ref = try disk.store(good,coordinate: c,key: key)
        let alternate = try XCTUnwrap(try fixture().frames.flatMap(\.tiles).first { $0.sha256 != ref.sha256 })
        let raw = try AtomicFile.read(MeteocatResources.previewFixtureDirectory.appendingPathComponent(alternate.relativePath))
        let nextID = try FrameID(kind: .observation,validUTC: id.validUTC.addingTimeInterval(360))
        let corruptKey = nextID.storageKey + ":\(c.z):\(c.x):\(c.yTMS)"
        let corrupt = try disk.store(raw,coordinate: c,key: corruptKey)
        var damaged = raw; damaged[30] ^= 1; try AtomicFile.write(damaged,to: root.appendingPathComponent(corrupt.relativePath))
        let wrongCoordinate = id.storageKey + ":\(other.z):\(other.x):\(other.yTMS)"
        let unsafe = [key:ref,corruptKey:corrupt,wrongCoordinate:ref,"garbage":ref,"forecast::\(id.validUTC.timeIntervalSince1970):7:63:79":ref]
        let url = root.appendingPathComponent("tile-index.json"), original = try NativeJSON.encode(unsafe)
        try AtomicFile.write(original,to: url)
        let reopened = DiskCache(root: root), manifest = try reopened.load()
        XCTAssertEqual(Set(reopened.index.keys),[key]); XCTAssertEqual(try AtomicFile.read(url),original,"Open remains read-only")
        let limited = DiskCache(root: root,budget: 1), empty = try limited.load()
        XCTAssertThrowsError(try limited.persist(empty)); XCTAssertEqual(try AtomicFile.read(url),original,"Failed repair leaves the existing index intact")
        try reopened.persist(manifest)
        let repaired = try NativeJSON.decode([String:TileReference].self,AtomicFile.read(url))
        XCTAssertEqual(Set(repaired.keys),[key]); XCTAssertEqual(repaired[key]?.coordinate,c); XCTAssertEqual(repaired[key]?.sha256,ref.sha256)
        XCTAssertEqual(try reopened.tile(ref),good)
    }
    func testRepairHuge429RemainsDurableAndManualRefreshCannotBypassIt() async throws {
        let root = try temporary(), clock = TestClock(try date()), initial = clock.now()
        let http = FakeHTTP(body: metadata(),tile: try tileBytes(),behavior: .metadata429(String(repeating: "9",count: 300)))
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await service.activateAndRefresh()
        let snapshot = await service.current(), gate = try NativeJSON.decode(AdmissionGate.self,AtomicFile.read(root.appendingPathComponent("gate.json")))
        XCTAssertEqual(snapshot.nextEligibleAt,initial.addingTimeInterval(86400)); XCTAssertEqual(gate.deadline,snapshot.nextEligibleAt)
        clock.advance(380)
        for _ in 0..<15 { await service.refreshIfEligible(); await service.setViewerVisible(false); await service.activateAndRefresh() }
        let count = await http.count(); XCTAssertEqual(count,1)
        await service.shutdown()
        let reopened = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await reopened.activateAndRefresh(); let after = await http.count(); XCTAssertEqual(after,1)
        await reopened.shutdown()
    }
    func testRepairOrphanTempsAndSymlinksRemainAccountedAndUntouched() throws {
        let root = try temporary(), outside = root.appendingPathComponent("retained-data")
        try AtomicFile.write(Data(repeating: 1,count: 3000),to: outside)
        let orphan = root.appendingPathComponent(".write-\(UUID().uuidString)")
        try AtomicFile.write(Data(repeating: 2,count: 3000),to: orphan)
        let symlink = root.appendingPathComponent(".write-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink,withDestinationURL: outside)
        let disk = DiskCache(root: root,budget: 6500), lock = try CycleLock(root: root); disk.beginCycle()
        XCTAssertThrowsError(try disk.reserve(1000)); XCTAssertEqual(disk.inventoryScans,1)
        XCTAssertEqual(try AtomicFile.read(orphan).count,3000); XCTAssertEqual(try AtomicFile.read(outside).count,3000)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path),outside.path)
        disk.endCycle(); withExtendedLifetime(lock) {}
    }
    func testRepairDisplayedContentLeaseSurvivesSameIDReplacementAndBudgetPressure() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let original = try fixture(), observations = original.frames.filter { $0.id.kind == .observation }
        let selected = try XCTUnwrap(observations.last { frame in
            let others = Set(original.frames.filter { $0.id != frame.id }.flatMap { $0.tiles.map(\.sha256) })
            return frame.tiles.contains { !others.contains($0.sha256) }
        })
        let others = Set(original.frames.filter { $0.id != selected.id }.flatMap { $0.tiles.map(\.sha256) })
        let leasedHashes = Set(selected.tiles.map(\.sha256)).subtracting(others)
        let clock = TestClock(try date("10/07/2026 06:30Z")), http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        await service.protectDisplayed([selected.id]); _ = try await service.weather(for: selected.id)
        let replacements = original.frames.flatMap(\.tiles).filter { !selected.tiles.map(\.sha256).contains($0.sha256) }
        let first = try XCTUnwrap(replacements.first)
        let second = try XCTUnwrap(replacements.first { $0.sha256 != first.sha256 })
        let disk = DiskCache(root: root); var current = try disk.load()
        for source in [first,second] {
            let data = try AtomicFile.read(MeteocatResources.previewFixtureDirectory.appendingPathComponent(source.relativePath))
            var refs = [TileReference]()
            for c in TileCoordinate.grid { refs.append(try disk.store(data,coordinate: c,key: selected.id.storageKey+":\(c.z):\(c.x):\(c.yTMS)")) }
            let replacement = try CachedFrame(id: selected.id,tiles: refs)
            current.frames = current.frames.map { $0.id == selected.id ? replacement : $0 }
            try disk.persist(current)
        }
        for hash in leasedHashes { try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970: 1)],ofItemAtPath: root.appendingPathComponent("tiles/\(hash).png").path) }
        func pressure() throws {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey]))
            var total = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
                if values.isRegularFile == true { total += values.fileSize ?? 0 }
            }
            let padding = root.appendingPathComponent("tiles/"+String(repeating: "f",count: 64)+".png")
            XCTAssertTrue(FileManager.default.createFile(atPath: padding.path,contents: nil))
            let file = try FileHandle(forWritingTo: padding); defer { try? file.close() }
            let size = 192*1024*1024-total-1024*1024
            guard size > 0 else { throw MeteocatError("La fixture de pressió ja és plena.") }
            try file.truncate(atOffset: UInt64(size))
        }
        try pressure(); await service.activateAndRefresh()
        for hash in leasedHashes { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("tiles/\(hash).png").path),"Old displayed bytes must survive eviction after previous rotates") }
        await service.protectDisplayed([]); await service.setViewerVisible(false)
        try pressure(); clock.advance(380); await service.activateAndRefresh()
        for hash in leasedHashes { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tiles/\(hash).png").path),"Released old content can be reclaimed") }
        await service.shutdown()
    }
}

extension CoreTests {
    func testRepairInventoryCountsWritesOverwritesCrashTempsAndNewCycles() throws {
        let root = try temporary(), disk = DiskCache(root: root,budget: 20000), lock = try CycleLock(root: root)
        disk.beginCycle()
        try disk.reserve(1); disk.reserved -= 1
        let owned = root.appendingPathComponent("metadata.json")
        try disk.reserve(8000); try disk.write(Data(repeating: 0,count: 8000),to: owned); disk.reserved -= 8000
        XCTAssertThrowsError(try disk.reserve(13000),"An owned write must consume bytes in the existing inventory")
        try disk.reserve(4000); try disk.write(Data(repeating: 0,count: 4000),to: owned); disk.reserved -= 4000
        try disk.reserve(14000); disk.reserved -= 14000
        XCTAssertEqual(disk.inventoryScans,1)
        disk.endCycle()
        // Another process's files are accounted when a new owned cycle begins.
        try AtomicFile.write(Data(repeating: 0,count: 8000),to: root.appendingPathComponent(".write-left-after-crash"))
        disk.beginCycle(); XCTAssertThrowsError(try disk.reserve(10000)); XCTAssertEqual(disk.inventoryScans,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".write-left-after-crash").path))
        disk.endCycle(); withExtendedLifetime(lock) {}
    }
    func testRepairInventoryLargeCacheOnlyScansOncePerCycle() throws {
        let root = try temporary(), tiles = root.appendingPathComponent("tiles")
        try FileManager.default.createDirectory(at: tiles,withIntermediateDirectories: true)
        let data = Data(repeating: 0,count: 1024)
        for i in 0..<30000 { try data.write(to: tiles.appendingPathComponent(String(format: "%064x",i)+".png")) }
        let disk = DiskCache(root: root), lock = try CycleLock(root: root); disk.beginCycle()
        let initial = Date(); try disk.reserve(100); disk.reserved -= 100
        let scan = Date().timeIntervalSince(initial), start = Date()
        for _ in 0..<200 { try disk.reserve(100); disk.reserved -= 100 }
        let reservations = Date().timeIntervalSince(start)
        XCTAssertEqual(disk.inventoryScans,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tiles.path).count,30000)
        print("Cache inventory: files=30000 initialScanMs=\(scan*1000) subsequent200ReservationsMs=\(reservations*1000)")
        disk.endCycle(); withExtendedLifetime(lock) {}
    }
    func testRepairSameIdentityNewContentInvalidatesGenerationAndRGBA() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let clock = TestClock(try date("10/07/2026 06:30Z")), http = FakeHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { clock.now() }, scheduler: clock.scheduler)
        let before = await service.current(), id = before.observations.last!.id
        await service.protectDisplayed([id]); let oldImage = try await service.weather(for: id)
        let disk = DiskCache(root: root), cached = try disk.load(), data = try tileBytes()
        var refs = [TileReference]()
        for coordinate in TileCoordinate.grid { refs.append(try disk.store(data,coordinate: coordinate,key: id.storageKey+":\(coordinate.z):\(coordinate.x):\(coordinate.yTMS)")) }
        let replacement = try CachedFrame(id: id,tiles: refs)
        try disk.persist(CacheManifest(frames: cached.frames.map { $0.id == id ? replacement : $0 },checkedAt: clock.now()))
        await service.activateAndRefresh(); let after = await service.current(), newImage = try await service.weather(for: id)
        XCTAssertEqual(after.revision,before.revision+1)
        XCTAssertEqual(after.observations.map(\.id),before.observations.map(\.id)); XCTAssertNotEqual(newImage.bytes,oldImage.bytes)
        await service.shutdown()
    }
    func testRepairForecastCorruptionDropsWholeBlockKeepsIntactObservations() throws {
        let root = try temporary(); try copyFixture(to: root)
        let manifest = try fixture(), observations = manifest.frames.filter { $0.id.kind == .observation }
        let observationHashes = Set(observations.flatMap { $0.tiles.map(\.sha256) })
        let victim = try XCTUnwrap(manifest.frames.filter { $0.id.kind == .forecast }.flatMap(\.tiles).first { !observationHashes.contains($0.sha256) })
        try FileManager.default.copyItem(at: root.appendingPathComponent("active.json"),to: root.appendingPathComponent("previous.json"))
        let url = root.appendingPathComponent(victim.relativePath); var damaged = try AtomicFile.read(url); damaged[30] ^= 1; try AtomicFile.write(damaged,to: url)
        let disk = DiskCache(root: root), recovered = try disk.load(); try recovered.validate()
        XCTAssertEqual(recovered.frames.map(\.id),observations.map(\.id))
        XCTAssertNotNil(disk.recoveryNotice)
        for frame in recovered.frames { for ref in frame.tiles { XCTAssertNoThrow(try disk.tile(ref)) } }
    }
    func testRepairFreshnessBoundsIncludeExactHourAndFutureSixMinutes() async throws {
        for reference in [try date().addingTimeInterval(3600),try date().addingTimeInterval(-360)] {
            let http = FakeHTTP(body: metadata(),tile: try tileBytes())
            let service = try await RadarService.open(cacheRoot: try temporary(),mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
            await service.activateAndRefresh(); let snap = await service.current(), count = await http.count()
            XCTAssertNil(snap.observationError); XCTAssertEqual(snap.observations.count,11); XCTAssertGreaterThan(count,1)
            await service.shutdown()
        }
    }
}

extension CoreTests {
    func testRepairCorruptionAfterOpenNeverPromotesUnvalidatedLeasedFrames() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let reference = try date("10/07/2026 06:30Z"), http = PausedMetadataHTTP(body: metadata(),tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root,mode: .live,client: http,now: { reference }, scheduler: .fixedJitter)
        let initial = await service.current(), old = initial.observations.first!.id
        await service.protectDisplayed([old])
        _ = try await service.weather(for: old)
        let victim = initial.observations.first!.tiles.first!, url = root.appendingPathComponent(victim.relativePath)
        var damaged = try AtomicFile.read(url); damaged[30] ^= 1; try AtomicFile.write(damaged,to: url)
        let refresh = Task { await service.activateAndRefresh() }
        await http.waitForMetadata()
        let recovering = await service.current(), verifier = DiskCache(root: root)
        XCTAssertFalse(recovering.observations.contains { $0.id == old },"An invalid leased identity cannot re-enter the published manifest")
        XCTAssertNotNil(recovering.observationError)
        for frame in recovering.observations + recovering.forecast { for ref in frame.tiles { XCTAssertNoThrow(try verifier.tile(ref)) } }
        do { _ = try await service.weather(for: old); XCTFail("Detected corruption must invalidate even the previously cached RGBA") } catch { }
        await http.resume(); await refresh.value; let snap = await service.current()
        XCTAssertEqual(snap.observations.count,11); XCTAssertEqual(snap.forecast.count,10)
        let disk = DiskCache(root: root), persisted = try NativeJSON.decode(CacheManifest.self,AtomicFile.read(root.appendingPathComponent("active.json")))
        for frame in persisted.frames { for ref in frame.tiles { XCTAssertNoThrow(try disk.tile(ref)) } }
        if let prior = try? NativeJSON.decode(CacheManifest.self,AtomicFile.read(root.appendingPathComponent("previous.json"))) {
            for frame in prior.frames { for ref in frame.tiles { XCTAssertNoThrow(try disk.tile(ref)) } }
        }
        await service.shutdown()
    }
}

import Foundation

private struct ObservationMissing: Error {}

public actor RadarService {
    private let disk: DiskCache, mode: DataMode, client: any HTTPClient, now: @Sendable () -> Date
    private var manifest: CacheManifest, gate = AdmissionGate(), metadataRecord: MetadataRecord?
    private var state: SourceState = .cached, revision: UInt64 = 0, observationError: String?, forecastError: String?
    private var stopped = false, refreshActive = false
    private var lifecycleRevision: UInt64?
    private let scheduler: RefreshScheduler
    private var elapsedDeadline: TimeInterval = 0
    private var retryAt: Date = .distantPast
    private var timerGeneration: UInt64 = 0
    private var refreshTask: Task<Void,Never>?, wake: Task<Void,Never>?
    private var streams = [UUID: AsyncStream<RadarSnapshot>.Continuation]()
    private var frames = [FrameID:CachedFrame](), displayed = Set<FrameID>()
    private var displayLeases = [FrameID:Set<String>]()
    private var decodeLeases = [UUID:(id: FrameID, hashes: Set<String>)]()
    private var decodeWorkers = [UUID: Task<RGBAImage, Error>]()
    private var generationContent: [FrameID: [TileCoordinate: String]]
    private var rgba = [FrameID:RGBAImage](), rgbaOrder = [FrameID]()
    private init(disk: DiskCache, mode: DataMode, client: any HTTPClient, now: @escaping @Sendable () -> Date, manifest: CacheManifest, scheduler: RefreshScheduler) {
        self.scheduler = scheduler
        self.disk = disk; self.mode = mode; self.client = client; self.now = now; self.manifest = manifest; generationContent = manifest.content
        frames = Dictionary(uniqueKeysWithValues: manifest.frames.map { ($0.id,$0) })
        if case .fixture(_,let reference) = mode { state = .recorded(capturedAt: reference) }
    }
    public static func open(cacheRoot: URL, mode: DataMode, client: any HTTPClient, now: @escaping @Sendable () -> Date) async throws -> RadarService {
        try await open(cacheRoot: cacheRoot, mode: mode, client: client, now: now, scheduler: .system)
    }
    static func open(cacheRoot: URL, mode: DataMode, client: any HTTPClient, now: @escaping @Sendable () -> Date, scheduler: RefreshScheduler) async throws -> RadarService {
        let root: URL
        if case .fixture(let directory,_) = mode { root = directory } else { root = cacheRoot; try NativeDestination.validate(root) }
        let disk = DiskCache(root: root), manifest = try disk.load()
        let service = RadarService(disk: disk,mode: mode,client: client,now: now,manifest: manifest,scheduler: scheduler)
        await service.initialize()
        return service
    }
    private func initialize() {
        if case .live = mode {
            // Read-only open: a malformed gate is fail-closed in memory; admission repairs under flock.
            let url = disk.root.appendingPathComponent("gate.json")
            if FileManager.default.fileExists(atPath: url.path) {
                if let value = try? NativeJSON.decode(AdmissionGate.self,AtomicFile.read(url,maximum: 4096)) { gate = value }
                else { gate = AdmissionGate(nextCycleAt: now().addingTimeInterval(360),blockedUntil: now().addingTimeInterval(360)); state = .unavailable(message: "El límit local de consultes no és vàlid. Cal esperar sis minuts.") }
            }
            if let value = try? NativeJSON.decode(MetadataRecord.self,AtomicFile.read(disk.root.appendingPathComponent("metadata.json"),maximum: 4*1024*1024)), let parsed = try? RadarMetadata.parse(value.body), parsed.observationUTC == value.metadata.observationUTC, parsed.originUTC == value.metadata.originUTC, parsed.serverUTC == value.metadata.serverUTC { metadataRecord = value }
        }
        if let message = disk.recoveryNotice { observationError = message; state = .unavailable(message: message) }
        expire()
    }
    private var clock: Date { if case .fixture(_,let date) = mode { return date }; return now() }
    public func current() -> RadarSnapshot {
        expire()
        let obs = manifest.frames.filter { $0.id.kind == .observation }.sorted { $0.id.validUTC < $1.id.validUTC }
        let forecast = manifest.frames.filter { $0.id.kind == .forecast && !$0.id.isExpired(at: clock) }.sorted { $0.id.validUTC < $1.id.validUTC }
        return RadarSnapshot(revision: revision,observations: obs,forecast: forecast,checkedAt: manifest.checkedAt,nextEligibleAt: effectiveDeadline > now() ? effectiveDeadline : nil,sourceState: state,historyComplete: obs.count == 11,observationError: observationError,forecastError: forecastError)
    }
    public func snapshots() -> AsyncStream<RadarSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !stopped else { continuation.finish(); return }
            streams[id] = continuation; continuation.yield(current())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeStream(id) } }
        }
    }
    private func removeStream(_ id: UUID) { streams[id] = nil }
    private func publish() { let snapshot = current(); for continuation in streams.values { continuation.yield(snapshot) } }
    private func expire() {
        let previous = manifest.frames.count
        manifest.frames.removeAll { $0.id.isExpired(at: clock) }
        if previous != manifest.frames.count { forecastError = "La previsió ha caducat. Es mostra l'última observació."; syncProtection() }
        updateGeneration()
    }
    private func updateGeneration() {
        let content = manifest.content
        guard content != generationContent else { return }
        revision &+= 1
        for id in rgba.keys where content[id] != generationContent[id] { rgba[id] = nil; rgbaOrder.removeAll { $0 == id } }
        generationContent = content
    }
    /// Presentation only: hiding never cancels useful cache work or activates HTTP.
    public func setViewerVisible(_ value: Bool) async {
        guard !stopped else { return }
        if value { expire(); publish() }
    }
    public func setRefreshActive(_ active: Bool, revision: UInt64) async {
        guard !stopped, lifecycleRevision.map({ revision > $0 }) ?? true else { return }
        lifecycleRevision = revision
        refreshActive = active
        cancelWake()
        if !active { refreshTask?.cancel(); return }
        expire(); publish()
        startEligibleCycle()
    }
    private var effectiveDeadline: Date {
        max(gate.deadline, retryAt, now().addingTimeInterval(max(0, elapsedDeadline - scheduler.elapsed())))
    }
    public func refreshIfEligible() async {
        startEligibleCycle()
        // Callers can wait, but only the cycle owner clears its slot after cleanup.
        if let task = refreshTask { await task.value }
    }
    private func startEligibleCycle() {
        guard !stopped, refreshActive, case .live = mode, refreshTask == nil else { return }
        if effectiveDeadline > now() { state = .deferred(until: effectiveDeadline); publish(); scheduleWake(); return }
        cancelWake()
        refreshTask = Task {
            await self.runCycle()
            self.refreshTask = nil
            self.syncProtection()
            self.scheduleWake()
        }
    }
    private func cancelWake() {
        timerGeneration &+= 1
        wake?.cancel(); wake = nil
    }
    private func scheduleWake() {
        cancelWake()
        guard refreshActive, !stopped, refreshTask == nil, case .live = mode else { return }
        expire()
        let expiry = manifest.frames.first(where: { $0.id.kind == .forecast })?.id.originUTC?.addingTimeInterval(3600) ?? .distantFuture
        let deadline = min(effectiveDeadline, expiry)
        let seconds = max(0.05, deadline.timeIntervalSince(now()))
        let generation = timerGeneration, scheduler = scheduler
        wake = Task {
            do {
                try await scheduler.sleep(min(seconds, 86400 * 365))
                try checkCycle()
                guard generation == self.timerGeneration, self.refreshActive, !self.stopped else { return }
                self.wake = nil
                self.expire(); self.publish()
                self.startEligibleCycle()
            } catch { }
        }
    }
    private func checkCycle() throws {
        try Task.checkCancellation()
        guard refreshActive, !stopped else { throw CancellationError() }
    }
    private func runCycle() async {
        var lock: CycleLock?
        defer { if lock != nil { disk.endCycle() }; withExtendedLifetime(lock) {} }
        var fetchingForecast = false
        do {
            try checkCycle()
            do { lock = try CycleLock(root: disk.root) } catch is CycleBusy {
                retryAt = now().addingTimeInterval(30); state = .deferred(until: effectiveDeadline); publish(); return
            }
            disk.beginCycle()
            gate = try disk.gate(now: now())
            guard effectiveDeadline <= now() else { state = .deferred(until: gate.deadline); publish(); return }
            let other = try disk.load()
            // Reconcile validated disk content even if a rollback/salvage has an older
            // checkedAt. Retained display/decode leases must not re-enter the timeline.
            manifest = other
            var cycleFrames = Set(other.frames.map(\.id))
            for f in other.frames { frames[f.id] = f }
            disk.staged = []; syncProtection()
            // Reconcile active/previous protections before any budgeted write, so a
            // different service's successful promotion cannot be evicted on admission.
            // Durable admission still occurs before the first HTTP request.
            let interval = 360 + min(40, max(20, scheduler.jitter()))
            gate.nextCycleAt = now().addingTimeInterval(interval); try persistGate()
            elapsedDeadline = scheduler.elapsed() + interval
            retryAt = .distantPast
            if let value = try? NativeJSON.decode(MetadataRecord.self,AtomicFile.read(disk.root.appendingPathComponent("metadata.json"),maximum: 4*1024*1024)), let parsed = try? RadarMetadata.parse(value.body), parsed.observationUTC == value.metadata.observationUTC, parsed.originUTC == value.metadata.originUTC, parsed.serverUTC == value.metadata.serverUTC { metadataRecord = value }
            state = .refreshing; observationError = disk.recoveryNotice; forecastError = nil; publish()
            var headers = [String:String]()
            if let tag = metadataRecord?.etag { headers["If-None-Match"] = tag }
            if let modified = metadataRecord?.lastModified { headers["If-Modified-Since"] = modified }
            let response = try await obtainMetadata(headers: headers)
            try checkCycle()
            let metadata: Metadata, record: MetadataRecord
            if response.status == 304 {
                guard let stored = metadataRecord else { throw MeteocatError("Meteocat indica que les dades no han canviat, però no hi ha cap còpia local.") }
                metadata = stored.metadata
                record = MetadataRecord(body: stored.body,metadata: metadata,etag: response.headers["etag"] ?? stored.etag,lastModified: response.headers["last-modified"] ?? stored.lastModified,checkedAt: now())
            } else {
                metadata = try RadarMetadata.parse(response.body)
                record = MetadataRecord(body: response.body,metadata: metadata,etag: response.headers["etag"],lastModified: response.headers["last-modified"],checkedAt: now())
            }
            let checked = now()
            guard metadata.serverUTC >= checked.addingTimeInterval(-3600), metadata.serverUTC <= checked.addingTimeInterval(360) else { throw MeteocatError("Les metadades de Meteocat tenen una data no vàlida. Es conserva l'últim radar.") }
            let newest = manifest.frames.filter { $0.id.kind == .observation }.map(\.id.validUTC).max()
            if let newest, metadata.observationUTC < newest { throw MeteocatError("Les metadades de Meteocat són anteriors al radar desat. Es conserva l'últim radar.") }
            metadataRecord = record
            if let record = metadataRecord {
                let body = try NativeJSON.encode(record); try disk.reserve(body.count); defer { disk.reserved -= body.count }
                try disk.write(body,to: disk.root.appendingPathComponent("metadata.json"))
            }
            manifest.checkedAt = now()
            let candidates = try RadarMetadata.candidates(metadata)
            // newest complete sample is published first; retain a contiguous suffix only.
            for id in candidates.observations.reversed() {
                let frame: CachedFrame
                do { frame = try await obtainFrame(id) }
                catch is ObservationMissing {
                    observationError = id == candidates.observations.last ? "L'última observació encara no està disponible. Es conserva l'últim radar." : "L'historial disponible és parcial; falten observacions antigues."
                    break
                }
                try checkCycle()
                frames[id] = frame; cycleFrames.insert(id)
                var contiguous = [CachedFrame](), cursor = candidates.observations.last!.validUTC
                for _ in 0..<11 {
                    let key = try FrameID(kind: .observation,validUTC: cursor)
                    guard cycleFrames.contains(key), let f = frames[key] else { break }; contiguous.insert(f,at: 0); cursor = cursor.addingTimeInterval(-360)
                }
                if !contiguous.isEmpty {
                    let forecasts = manifest.frames.filter { $0.id.kind == .forecast && !$0.id.isExpired(at: clock) }
                    try promote(contiguous + forecasts)
                }
            }
            let newestForecastOrigin = manifest.frames.compactMap { $0.id.originUTC }.max()
            let forecastDoesNotRegress = newestForecastOrigin.map { metadata.originUTC >= $0 } ?? true
            if forecastDoesNotRegress, !candidates.forecast[0].isExpired(at: clock) {
                fetchingForecast = true
                var stagedForecast = [CachedFrame]()
                for id in candidates.forecast { try checkCycle(); let frame = try await obtainFrame(id); try checkCycle(); stagedForecast.append(frame); frames[id] = frame }
                try checkCycle()
                if !stagedForecast[0].id.isExpired(at: clock) { try promote(manifest.frames.filter { $0.id.kind == .observation } + stagedForecast) }
            }
            try checkCycle()
            try disk.persist(manifest)
            if let notice = disk.recoveryNotice, observationError == notice { observationError = nil }
            disk.recoveryNotice = nil
            state = .cached; disk.staged = []; syncProtection(); publish()
        } catch {
            if Task.isCancelled || error is CancellationError { state = .cached }
            else {
                gate.blockedUntil = max(gate.blockedUntil,now().addingTimeInterval(360)); gate.nextCycleAt = max(gate.nextCycleAt,gate.blockedUntil)
                do { try persistGate() } catch { observationError = "No s'ha pogut desar l'espera de seguretat. No es faran més peticions."; stopped = true }
                let message = (error as? MeteocatError)?.message ?? "No s'han pogut actualitzar les dades de Meteocat. Es conserva l'últim radar complet."
                state = .unavailable(message: message)
                if fetchingForecast { forecastError = message } else { observationError = observationError ?? message }
            }
            disk.staged = []; syncProtection(); publish()
        }
    }
    private func persistGate() throws {
        do { try disk.writeGate(gate) }
        catch {
            stopped = true; refreshActive = false; cancelWake()
            observationError = "No s'ha pogut desar l'espera de seguretat. No es faran més peticions."
            throw error
        }
    }
    private func obtainMetadata(headers: [String:String]) async throws -> HTTPResponse {
        try disk.reserve(PNGDecoder.maximumBytes); defer { disk.reserved -= PNGDecoder.maximumBytes }
        return try await dispatch(HTTPRequest(url: RadarMetadata.url,headers: headers),allow304: true)
    }
    private func dispatch(_ request: HTTPRequest, allow304: Bool = false, observation: Bool = false) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard refreshActive, !stopped else { throw CancellationError() }
        guard now() >= gate.blockedUntil else { throw MeteocatError("Les consultes a Meteocat estan en pausa després d'un error.") }
        do {
            let response = try await client.send(request)
            guard response.body.count <= PNGDecoder.maximumBytes else { throw MeteocatError("Resposta de Meteocat massa gran.") }
            if response.status == 200 || (allow304 && response.status == 304) { return response }
            if observation && (response.status == 404 || response.status == 410) { throw ObservationMissing() }
            let until = response.status == 429 ? RadarMetadata.retryDeadline(response.headers["retry-after"],now: now()) : now().addingTimeInterval(360)
            gate.blockedUntil = max(gate.blockedUntil,until); gate.nextCycleAt = max(gate.nextCycleAt,gate.blockedUntil)
            try persistGate()
            throw MeteocatError(response.status == 429 ? "Meteocat limita les peticions. Es conserva el radar i s'espera fins al termini indicat." : "Meteocat ha retornat un error HTTP \(response.status). Es conserva el radar complet.")
        } catch {
            if error is ObservationMissing { throw error }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            gate.blockedUntil = max(gate.blockedUntil,now().addingTimeInterval(360)); gate.nextCycleAt = max(gate.nextCycleAt,gate.blockedUntil)
            try persistGate()
            throw error
        }
    }
    private func obtainFrame(_ id: FrameID) async throws -> CachedFrame {
        await Task.yield()
        try checkCycle()
        if let frame = frames[id] {
            if frame.tiles.allSatisfy({ (try? disk.tile($0)) != nil }) { return frame }
            // A damaged cached identity is repaired from verified new bytes under cycle lock.
            frames[id] = nil; rgba[id] = nil; rgbaOrder.removeAll { $0 == id }
        }
        var refs = [TileReference]()
        var missing = [TileCoordinate]()
        for coordinate in TileCoordinate.grid {
            let key = id.storageKey + ":\(coordinate.z):\(coordinate.x):\(coordinate.yTMS)"
            if let ref = disk.index[key], (try? disk.tile(ref)) != nil { refs.append(ref); disk.staged.insert(ref.sha256) } else { missing.append(coordinate) }
        }
        // A finite plan, batches of three. Every individual dispatch rechecks global backoff.
        for start in stride(from: 0,to: missing.count,by: 3) {
            try checkCycle()
            let batch = Array(missing[start..<min(start+3,missing.count)])
            let values = try await withThrowingTaskGroup(of: TileReference.self) { group in
                for coordinate in batch { group.addTask { try await self.downloadTile(id,coordinate: coordinate) } }
                var values = [TileReference](); for try await value in group { values.append(value) }; return values
            }
            refs.append(contentsOf: values)
        }
        try checkCycle()
        return try CachedFrame(id: id,tiles: refs.sorted { a,b in a.coordinate.yTMS == b.coordinate.yTMS ? a.coordinate.x < b.coordinate.x : a.coordinate.yTMS < b.coordinate.yTMS })
    }
    private func downloadTile(_ id: FrameID, coordinate: TileCoordinate) async throws -> TileReference {
        try disk.reserve(PNGDecoder.maximumBytes); defer { disk.reserved -= PNGDecoder.maximumBytes }
        let response = try await dispatch(HTTPRequest(url: RadarMetadata.tileURL(id,coordinate: coordinate)),observation: id.kind == .observation)
        // Valid in-flight bytes may settle atomically while system cancellation drains.
        return try disk.store(response.body,coordinate: coordinate,key: id.storageKey + ":\(coordinate.z):\(coordinate.x):\(coordinate.yTMS)")
    }
    private func promote(_ values: [CachedFrame]) throws {
        try checkCycle()
        let candidate = CacheManifest(frames: values,checkedAt: manifest.checkedAt)
        guard candidate.content != manifest.content else { return }
        try disk.persist(candidate); manifest = candidate; syncProtection(); publish()
    }
    private func syncProtection() {
        let keep = displayed.union(decodeLeases.values.map(\.id))
        // A frame identity can receive new bytes while its old image is still on screen
        // or being decoded. Keep each leased content version until its owner releases it.
        for id in displayed {
            if let frame = frames[id] { displayLeases[id,default: []].formUnion(frame.tiles.map(\.sha256)) }
        }
        disk.protected = Set(displayLeases.values.flatMap { $0 }).union(decodeLeases.values.flatMap { $0.hashes })
        let active = Set(manifest.frames.map(\.id)).union(keep)
        // Retain previous frame identities while a refresh runs; prune on completion.
        if refreshTask == nil { frames = frames.filter { active.contains($0.key) } }
    }
    public func protectDisplayed(_ ids: Set<FrameID>) async {
        displayed = ids; displayLeases = displayLeases.filter { ids.contains($0.key) }; syncProtection()
    }
    public func weather(for id: FrameID) async throws -> RGBAImage {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try id.validate(); guard !id.isExpired(at: clock), let frame = frames[id] else { throw MeteocatError("Fotograma absent o caducat.") }
        if let value = rgba[id] { return value }
        let lease = UUID(); decodeLeases[lease] = (id,Set(frame.tiles.map(\.sha256)))
        syncProtection(); defer { decodeWorkers[lease] = nil; decodeLeases[lease] = nil; syncProtection() }
        let root = disk.root
        let worker = Task.detached(priority: .userInitiated) {
            let local = DiskCache(root: root)
            var tiles = [TileCoordinate:RGBAImage]()
            for ref in frame.tiles { try Task.checkCancellation(); tiles[ref.coordinate] = try local.decodedTile(ref) }
            try Task.checkCancellation()
            return try WeatherRasterizer.rasterize(tiles)
        }
        decodeWorkers[lease] = worker
        let image = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !stopped, !id.isExpired(at: clock), let current = frames[id], CacheManifest(frames: [current],checkedAt: nil).content == CacheManifest(frames: [frame],checkedAt: nil).content else { throw MeteocatError("El fotograma ha canviat durant la descodificació.") }
        rgba[id] = image; rgbaOrder.removeAll { $0 == id }; rgbaOrder.append(id)
        while rgbaOrder.count > 3 { rgba[rgbaOrder.removeFirst()] = nil }
        return image
    }
    public func shutdown() async {
        stopped = true; refreshActive = false; cancelWake(); refreshTask?.cancel()
        let workers = Array(decodeWorkers.values)
        workers.forEach { $0.cancel() }
        if let refreshTask { await refreshTask.value }; self.refreshTask = nil
        for worker in workers { _ = try? await worker.value }
        for c in streams.values { c.finish() }; streams = [:]; rgba = [:]; rgbaOrder = []
    }
}

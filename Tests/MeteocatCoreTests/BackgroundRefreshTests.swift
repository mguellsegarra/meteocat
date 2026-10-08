import XCTest
import Foundation
@testable import MeteocatCore

extension RefreshScheduler {
    static var fixedJitter: RefreshScheduler {
        var result = system; result.jitter = { 20 }; return result
    }
}
extension TestClock {
    var scheduler: RefreshScheduler {
        RefreshScheduler(elapsed: { self.now().timeIntervalSince1970 }, sleep: RefreshScheduler.system.sleep, jitter: { 20 })
    }
}
extension RadarService {
    /// Legacy service regressions explicitly opt into app-owned refresh admission.
    func activateAndRefresh() async {
        await setRefreshActive(true, revision: 1)
        await setViewerVisible(true)
        await refreshIfEligible()
    }
}

/// Responses ignore cancellation until released, reproducing late transport delivery
/// and letting the test inspect the draining slot without timing guesses.
actor BarrierHTTP: HTTPClient {
    var requests = 0
    private var arrivals = [CheckedContinuation<Void, Never>]()
    private var responses = [CheckedContinuation<HTTPResponse, Never>]()
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        arrivals.forEach { $0.resume() }; arrivals = []
        return await withCheckedContinuation { responses.append($0) }
    }
    func arrived() async {
        if requests > 0 { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release(_ response: HTTPResponse) {
        let pending = responses; responses = []; pending.forEach { $0.resume(returning: response) }
    }
    func count() -> Int { requests }
}

private final class JitterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    let value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
    func sample() -> TimeInterval { lock.lock(); defer { lock.unlock() }; samples += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
}

extension CoreTests {
    func testBackgroundVisibilityDoesNotAdmitAndHiddenCycleCompletes() async throws {
        let root = try temporary(), clock = TestClock(try date())
        let http = PausedMetadataHTTP(body: metadata(), tile: try tileBytes())
        let service = try await RadarService.open(cacheRoot: root, mode: .live, client: http, now: { clock.now() }, scheduler: clock.scheduler)
        await service.setViewerVisible(true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gate.json").path))
        await service.setRefreshActive(true, revision: 1)
        await http.waitForMetadata()
        await service.setViewerVisible(false)
        await http.resume()
        await service.refreshIfEligible()
        let snapshot = await service.current()
        XCTAssertEqual(snapshot.observations.count, 11)
        XCTAssertEqual(snapshot.forecast.count, 10)
        await service.shutdown()
    }
    func testBackgroundJitterPersistedAndForwardClockCannotBypassMinimum() async throws {
        for jitter in [20.0, 40.0] {
            let root = try temporary(), wall = TestClock(try date()), elapsed = TestClock(try date())
            let probe = JitterProbe(jitter)
            let admittedAt = wall.now()
            let http = FakeHTTP(body: metadata(), tile: try tileBytes(), preflight: {
                let gate = try NativeJSON.decode(AdmissionGate.self, AtomicFile.read(root.appendingPathComponent("gate.json")))
                guard gate.nextCycleAt == admittedAt.addingTimeInterval(360 + jitter) else { throw MeteocatError("Jitter no desat abans del GET.") }
            })
            let scheduler = RefreshScheduler(elapsed: { elapsed.now().timeIntervalSince1970 }, sleep: RefreshScheduler.system.sleep, jitter: { probe.sample() })
            let service = try await RadarService.open(cacheRoot: root, mode: .live, client: http, now: { wall.now() }, scheduler: scheduler)
            XCTAssertEqual(probe.count, 0)
            await service.setRefreshActive(true, revision: 1)
            await service.refreshIfEligible()
            let gate = try NativeJSON.decode(AdmissionGate.self, AtomicFile.read(root.appendingPathComponent("gate.json")))
            XCTAssertEqual(gate.nextCycleAt, wall.now().addingTimeInterval(360 + jitter))
            let reopenedHTTP = FakeHTTP(body: metadata(), tile: try tileBytes())
            let reopened = try await RadarService.open(cacheRoot: root, mode: .live, client: reopenedHTTP, now: { wall.now() }, scheduler: scheduler)
            await reopened.activateAndRefresh()
            let reopenedCount = await reopenedHTTP.count(); XCTAssertEqual(reopenedCount, 0)
            await reopened.shutdown()
            wall.advance(-60)
            await service.refreshIfEligible()
            let rollbackGate = try NativeJSON.decode(AdmissionGate.self, AtomicFile.read(root.appendingPathComponent("gate.json")))
            XCTAssertEqual(rollbackGate.nextCycleAt, gate.nextCycleAt)
            wall.advance(10_060)
            await service.refreshIfEligible()
            let count = await http.count(); XCTAssertEqual(count, 127)
            let snapshot = await service.current()
            XCTAssertEqual(snapshot.nextEligibleAt, wall.now().addingTimeInterval(360 + jitter))
            await service.setRefreshActive(false, revision: 2)
            await service.setRefreshActive(true, revision: 1) // stale callback cannot reactivate
            elapsed.advance(20_000)
            await service.refreshIfEligible()
            let inactiveCount = await http.count(); XCTAssertEqual(inactiveCount, 127)
            XCTAssertEqual(probe.count, 1)
            await service.shutdown()
        }
    }
    func testBackgroundSuspendFastResumeDrainsLate429AndQuitIsTerminal() async throws {
        let root = try temporary(), clock = TestClock(try date()), http = BarrierHTTP()
        let service = try await RadarService.open(cacheRoot: root, mode: .live, client: http, now: { clock.now() }, scheduler: clock.scheduler)
        await service.setRefreshActive(true, revision: 1)
        await http.arrived()
        await service.setRefreshActive(false, revision: 2)
        clock.advance(1000)
        await service.setRefreshActive(true, revision: 3)
        let duringDrain = await http.count(); XCTAssertEqual(duringDrain, 1)
        await http.release(HTTPResponse(status: 429, headers: ["retry-after": "1200"]))
        await service.refreshIfEligible()
        let gate = try NativeJSON.decode(AdmissionGate.self, AtomicFile.read(root.appendingPathComponent("gate.json")))
        XCTAssertEqual(gate.blockedUntil, clock.now().addingTimeInterval(1200))
        for revision in 4...10 { await service.setRefreshActive(true, revision: UInt64(revision)); await service.refreshIfEligible() }
        let deferred = await http.count(); XCTAssertEqual(deferred, 1)
        await service.shutdown()
        clock.advance(10_000)
        await service.setRefreshActive(true, revision: 100)
        await service.refreshIfEligible()
        let terminal = await http.count(); XCTAssertEqual(terminal, 1)
        let reopened = try await RadarService.open(cacheRoot: root, mode: .live, client: FakeHTTP(body: metadata(), tile: try tileBytes()), now: { gate.blockedUntil.addingTimeInterval(-1) }, scheduler: .fixedJitter)
        await reopened.activateAndRefresh()
        let snapshot = await reopened.current(); XCTAssertEqual(snapshot.nextEligibleAt, gate.blockedUntil)
        await reopened.shutdown()
    }
    func testBackgroundFixtureActivationAndQuitNeverHTTP() async throws {
        let http = BarrierHTTP(), reference = try date()
        let service = try await RadarService.open(cacheRoot: try temporary(), mode: .fixture(directory: MeteocatResources.previewFixtureDirectory, referenceUTC: reference), client: http, now: { .distantFuture })
        for revision in 1...6 { await service.setRefreshActive(revision % 2 == 1, revision: UInt64(revision)); await service.refreshIfEligible() }
        await service.shutdown()
        let count = await http.count(); XCTAssertEqual(count, 0)
    }
}

actor ManualRefreshSleeper {
    private var sleepers = [UUID: CheckedContinuation<Void, Error>]()
    private var cancelled = Set<UUID>()
    private var arrivals = [(Int, CheckedContinuation<Void, Never>)]()
    private(set) var delays = [TimeInterval]()
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil { continuation.resume(throwing: CancellationError()); return }
                sleepers[id] = continuation
                delays.append(delay)
                let ready = arrivals.filter { $0.0 <= delays.count }
                arrivals.removeAll { $0.0 <= delays.count }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let continuation = sleepers.removeValue(forKey: id) { continuation.resume(throwing: CancellationError()) }
        else { cancelled.insert(id) }
    }
    func scheduled(_ count: Int) async {
        if delays.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func tick() {
        let current = sleepers.values; sleepers = [:]
        current.forEach { $0.resume() }
    }
}

actor SuspendedTileHTTP: HTTPClient {
    let body: Data
    private var responses = [CheckedContinuation<HTTPResponse, Never>]()
    private var waiting: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private(set) var count = 0, cancellations = 0
    init(body: Data) { self.body = body }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        if request.url == RadarMetadata.url { return HTTPResponse(status: 200, body: body) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                responses.append(continuation)
                if responses.count == 3 { waiting?.resume(); waiting = nil }
            }
        } onCancel: { Task { await self.cancelled() } }
    }
    private func cancelled() {
        cancellations += 1
        if cancellations == 3 { cancellationWaiter?.resume(); cancellationWaiter = nil }
    }
    func batchStarted() async {
        if responses.count == 3 { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func batchCancelled() async {
        if cancellations == 3 { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
    func release(_ body: Data) {
        let pending = responses; responses = []
        pending.forEach { $0.resume(returning: HTTPResponse(status: 200, body: body)) }
    }
}

extension CoreTests {
    func testBackgroundControlledTimerHiddenSuccessorNoCatchupBurst() async throws {
        let root = try temporary(); try copyFixture(to: root)
        let clock = TestClock(try date("10/07/2026 06:30Z")), sleeper = ManualRefreshSleeper()
        let http = FakeHTTP(body: metadata(), tile: try tileBytes())
        let scheduler = RefreshScheduler(elapsed: { clock.now().timeIntervalSince1970 }, sleep: { try await sleeper.sleep($0) }, jitter: { 20 })
        let service = try await RadarService.open(cacheRoot: root, mode: .live, client: http, now: { clock.now() }, scheduler: scheduler)
        await service.setRefreshActive(true, revision: 1)
        await service.refreshIfEligible()
        await sleeper.scheduled(1)
        let delays = await sleeper.delays; XCTAssertEqual(delays, [380])
        await service.setViewerVisible(false)
        clock.advance(10_000)
        await http.change(.metadata429("1200"))
        await sleeper.tick()
        await sleeper.scheduled(2) // cycle completion, rather than a real-time delay
        for revision in 2...10 {
            await service.setRefreshActive(true, revision: UInt64(revision))
            await service.setViewerVisible(true); await service.setViewerVisible(false)
            await service.refreshIfEligible()
        }
        let count = await http.count(); XCTAssertEqual(count, 2)
        let allDelays = await sleeper.delays
        XCTAssertTrue(allDelays.allSatisfy { $0 >= 380 }, "Expired forecasts cannot cause a 50 ms timer loop")
        await service.shutdown()
    }
    func testBackgroundTileCancellationReachesAllThreeAndCannotPromote() async throws {
        for warm in [false, true] {
            let root = try temporary()
            if warm { try copyFixture(to: root) }
            let clock = TestClock(try date(warm ? "10/07/2026 06:30Z" : "10/07/2026 06:12Z"))
            let http = SuspendedTileHTTP(body: metadata(origin: warm ? "10/07/2026 06:12Z" : "10/07/2026 06:00Z"))
            let service = try await RadarService.open(cacheRoot: root, mode: .live, client: http, now: { clock.now() }, scheduler: clock.scheduler)
            await service.setRefreshActive(true, revision: 1)
            await http.batchStarted()
            await service.setRefreshActive(false, revision: 2)
            await http.batchCancelled()
            await service.setRefreshActive(true, revision: 3)
            let count = await http.count; XCTAssertEqual(count, 4)
            await http.release(try tileBytes())
            await service.refreshIfEligible()
            let finalCount = await http.count; XCTAssertEqual(finalCount, 4)
            let snapshot = await service.current()
            XCTAssertEqual(snapshot.observations.count, warm ? 11 : 0)
            XCTAssertEqual(snapshot.forecast.count, warm ? 10 : 0)
            if warm { XCTAssertTrue(snapshot.forecast.allSatisfy { $0.id.originUTC == (try? date("10/07/2026 06:00Z")) }) }
            // The owner released the flock only after the entire batch settled.
            let lock = try CycleLock(root: root); withExtendedLifetime(lock) {}
            await service.shutdown()
        }
    }
}

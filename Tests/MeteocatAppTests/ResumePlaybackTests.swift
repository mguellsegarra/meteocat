import XCTest
import MeteocatCore
@testable import MeteocatApp

private actor ForbiddenHTTPClient: HTTPClient {
    private(set) var requests = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
final class ResumePlaybackTests: XCTestCase {
    private func withModel(_ body: (RadarViewModel) async throws -> Void) async throws {
        try await withFixtureModel { model, _ in try await body(model) }
    }

    private func withFixtureModel(_ body: (RadarViewModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: MeteocatResources.previewFixtureDirectory, to: fixture)
        let info = try NativeJSON.decode(SnapshotInfo.self, AtomicFile.read(fixture.appendingPathComponent("snapshot-info.json")))
        let client = ForbiddenHTTPClient()
        let service = try await RadarService.open(cacheRoot: root.appendingPathComponent("cache"),
            mode: .fixture(directory: fixture, referenceUTC: info.capturedAt), client: client, now: { Date() })
        let store = try await SettingsStore.open(at: root.appendingPathComponent("settings.json"))
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let model = RadarViewModel(service: service, store: store, settings: await store.load(), recoveryNotice: nil,
            geography: nil, projection: projection, fixtureCapture: info.capturedAt)
        await model.start()
        do {
            model.setViewerVisible(true)
            try await eventually { model.playback.weather != nil }
            try await body(model, fixture)
        } catch {
            model.setViewerVisible(false)
            await model.shutdown()
            throw error
        }
        model.setViewerVisible(false)
        await model.shutdown()
        let requests = await client.requests
        XCTAssertEqual(requests, 0, "Fixture presentation must never request HTTP")
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Presentation did not reach the expected state", file: file, line: line)
    }

    func testRetainedForecastKeepsIndicatorDuringPendingAndFailedObservationFallback() async throws {
        try await withFixtureModel { model, fixture in
            let playback = model.playback
            playback.pause()
            let original = try XCTUnwrap(model.snapshot)
            let forecastIndex = try XCTUnwrap(playback.timeline.firstIndex { $0.kind == .forecast })
            let forecastID = playback.timeline[forecastIndex]
            playback.seek(toIndex: forecastIndex)
            try await eventually { playback.selectedID == forecastID }
            let forecast = try XCTUnwrap(playback.weather)
            XCTAssertTrue(playback.showsForecast)
            XCTAssertFalse(playback.isPlaying)

            // The oldest observation has never been presented or decoded by this controller.
            // Remove a tile only in its temporary fixture copy, after the service has indexed it.
            let observation = try XCTUnwrap(original.observations.first)
            XCTAssertNotEqual(observation.id, original.observations.last?.id)
            let tile = fixture.appendingPathComponent(try XCTUnwrap(observation.tiles.first).relativePath)
            let tileBytes = try Data(contentsOf: tile)
            try FileManager.default.removeItem(at: tile)
            defer { try? tileBytes.write(to: tile) }
            let replacement = RadarSnapshot(revision: original.revision + 1,
                observations: [observation], forecast: [], checkedAt: original.checkedAt,
                nextEligibleAt: nil, sourceState: original.sourceState, historyComplete: false,
                observationError: nil, forecastError: nil)
            playback.replaceTimeline(snapshot: replacement)

            // No await: the MainActor load task cannot finish before these pending-state checks.
            XCTAssertEqual(playback.timeline, [observation.id])
            XCTAssertEqual(playback.selectedID, forecastID)
            XCTAssertNil(playback.selectedIndex)
            XCTAssertNil(playback.frameError)
            XCTAssertEqual(playback.desiredProtection, Set([forecastID, observation.id]))
            XCTAssertEqual(playback.weather?.serial, forecast.serial)
            XCTAssertEqual(playback.weather?.endpoint.bytes, forecast.endpoint.bytes)
            XCTAssertNil(playback.transition)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertTrue(playback.showsForecast, "A pending fallback still displays the forecast")

            try await eventually { playback.frameError != nil }
            XCTAssertEqual(playback.selectedID, forecastID)
            XCTAssertNil(playback.selectedIndex)
            XCTAssertEqual(playback.weather?.serial, forecast.serial)
            XCTAssertEqual(playback.weather?.endpoint.bytes, forecast.endpoint.bytes)
            XCTAssertEqual(playback.desiredProtection, Set([forecastID]))
            XCTAssertFalse(playback.isPlaying)
            XCTAssertTrue(playback.showsForecast, "A failed fallback retains the forecast indication")

            // Restore the source tile and let the real service decode/present the observation.
            try tileBytes.write(to: tile)
            playback.replaceTimeline(snapshot: replacement)
            try await eventually { playback.selectedID == observation.id }
            XCTAssertEqual(playback.selectedIndex, 0)
            XCTAssertNil(playback.frameError)
            XCTAssertGreaterThan(try XCTUnwrap(playback.weather?.serial), forecast.serial)
            XCTAssertNotEqual(playback.weather?.endpoint.bytes, forecast.endpoint.bytes)
            XCTAssertFalse(playback.showsForecast)
            XCTAssertFalse(playback.isPlaying)
        }
    }

    func testShowInSameMainActorTurnAsResumeRecoversPlaybackAndSeek() async throws {
        try await withModel { model in
            model.setViewerVisible(false)
            model.setSystemSuspended(true)
            model.setSystemSuspended(false)
            // No await here: the show supersedes presentation before resume can cross the service actor.
            model.setViewerVisible(true)
            try await eventually { model.playback.isPlaying }
            model.playback.seek(toIndex: 0)
            try await eventually { model.playback.selectedIndex == 0 }
            model.playback.play()
            XCTAssertTrue(model.playback.isPlaying)
        }
    }

    func testHideInSameMainActorTurnAsResumeThenLaterShowRecovers() async throws {
        try await withModel { model in
            model.setSystemSuspended(true)
            model.setSystemSuspended(false)
            model.setViewerVisible(false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(model.playback.isPlaying)
            model.setViewerVisible(true)
            try await eventually { model.playback.isPlaying }
        }
    }

    func testShowWhileSuspendedAutoplaysOnResume() async throws {
        try await withModel { model in
            model.setViewerVisible(false)
            model.setSystemSuspended(true)
            model.setViewerVisible(true)
            XCTAssertFalse(model.playback.isPlaying)
            model.setSystemSuspended(false)
            try await eventually { model.playback.isPlaying }
        }
    }

    func testExplicitlyPausedVisibleViewerResumesPaused() async throws {
        try await withModel { model in
            model.playback.pause()
            let selected = model.playback.selectedID
            model.setSystemSuspended(true)
            model.setSystemSuspended(false)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(model.playback.isPlaying)
            XCTAssertEqual(model.playback.selectedID, selected)
            model.playback.play()
            try await eventually { model.playback.isPlaying }
        }
    }

    func testExplicitPauseAfterSuspendedShowWinsEvenWhileHidden() async throws {
        try await withModel { model in
            model.setViewerVisible(false)
            model.setSystemSuspended(true)
            model.setViewerVisible(true)
            model.setViewerVisible(false)
            model.playback.pause()
            model.setSystemSuspended(false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(model.playback.isPlaying)
            // A new ordinary show is a new autoplay intent.
            model.setViewerVisible(true)
            try await eventually { model.playback.isPlaying }
        }
    }

    func testExplicitPauseAfterSuspendedShowResumesVisibleButPaused() async throws {
        try await withModel { model in
            model.setViewerVisible(false)
            model.setSystemSuspended(true)
            model.setViewerVisible(true)
            model.playback.pause()
            model.setSystemSuspended(false)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(model.playback.isPlaying)
            model.playback.play()
            try await eventually { model.playback.isPlaying }
        }
    }

    func testRedundantSuspendedShowPreservesExplicitPauseIntent() async throws {
        try await withModel { model in
            let playback = model.playback
            model.setViewerVisible(false)
            playback.setSuspended(true)
            model.setViewerVisible(true)
            playback.pause()
            model.setViewerVisible(true)
            playback.setSuspended(false)
            XCTAssertFalse(playback.isPlaying, "A redundant visibility notification must not replace an explicit pause")
            XCTAssertNil(playback.transition)
        }
    }

    func testStaleResumeCannotUndoLatestResuspension() async throws {
        try await withModel { model in
            model.setSystemSuspended(true)
            model.setSystemSuspended(false)
            model.setSystemSuspended(true)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(model.playback.isPlaying)
            model.playback.play()
            XCTAssertFalse(model.playback.isPlaying, "A stale resume must leave the latest suspension in force")
            model.setSystemSuspended(false)
            try await eventually { model.playback.isPlaying }
        }
    }
}

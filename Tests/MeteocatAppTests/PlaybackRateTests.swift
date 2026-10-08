import XCTest
import AppKit
import QuartzCore
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
final class PlaybackRateTests: XCTestCase {
    private func withModel(_ body: (RadarViewModel) async throws -> Void) async throws {
        try await withFixtureModel { model, _ in try await body(model) }
    }

    private func withFixtureModel(_ body: (RadarViewModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-rate-test-\(UUID().uuidString)")
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
            model.playback.pause()
            // Warm exactly the three frames used by pacing tests. The real service still performs each
            // `weather` call, but deterministic cache hits exercise the decoded deadline wait even on slow builds.
            for id in model.playback.timeline.prefix(3) { _ = try await service.weather(for: id) }
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
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "Presentation did not reach the expected state", file: file, line: line)
    }

    func testManualRefreshShowsFeedbackForCacheOnlyResultAndCoalescesClicks() async throws {
        try await withModel { model in
            let before = model.snapshot
            let started = ContinuousClock.now
            model.refresh()
            XCTAssertTrue(model.refreshPending, "Feedback must start synchronously")
            XCTAssertTrue(model.isRefreshing)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(model.refreshPending, "A cache-only refresh must remain visible")
            model.refresh()
            try await eventually { !model.refreshPending }
            XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(1500))
            XCTAssertLessThan(started.duration(to: .now), .milliseconds(2200), "Repeated clicks must coalesce")
            XCTAssertEqual(model.snapshot?.checkedAt, before?.checkedAt, "Feedback must not invent a successful server check")
            XCTAssertEqual(model.snapshot?.revision, before?.revision)
            model.refresh()
            XCTAssertTrue(model.refreshPending, "Refresh must be available again after feedback ends")
            try await eventually { !model.refreshPending }
        }
    }

    func testRescalingPreservesProgressIdentitiesAndDeadlineContinuity() throws {
        let from = try FrameID(kind: .observation, validUTC: Date(timeIntervalSince1970: 0), originUTC: nil)
        let to = try FrameID(kind: .observation, validUTC: Date(timeIntervalSince1970: 360), originUTC: nil)
        for p in [0.0, 0.3, 0.999] {
            for factor in [0.25, 0.5, 2.0, 4.0] {
                let original = MediaTransition(from: from, to: to, start: 100, duration: 1)
                let now = 100 + p
                let retimed = original.rescaled(by: factor, at: now)
                XCTAssertEqual(retimed.from, from); XCTAssertEqual(retimed.to, to)
                XCTAssertEqual(retimed.progress(at: now), p, accuracy: 0.00000001)
                XCTAssertEqual(retimed.end, now + (1 - p) * factor, accuracy: 0.00000001)
                let deadline = MediaTransition.rescaledTime(original.end, by: factor, at: now)
                XCTAssertEqual(deadline, retimed.end, accuracy: 0.00000001)
                XCTAssertEqual(retimed.visualDate(progress: retimed.progress(at: now)).timeIntervalSince1970,
                    original.visualDate(progress: p).timeIntervalSince1970, accuracy: 0.000001)
                XCTAssertEqual(retimed.position(progress: retimed.progress(at: now), fromIndex: 3, toIndex: 4),
                    3 + p, accuracy: 0.00000001)
            }
        }
    }

    private func startAtFirstObservation(_ playback: PlaybackController) async throws {
        playback.seek(toIndex: 0)
        try await eventually { playback.selectedIndex == 0 }
        playback.play()
    }

    func testPlayStartsRetainedFrameStepWithoutInitialDeadlineHold() async throws {
        try await withModel { model in
            let playback = model.playback
            playback.seek(toIndex: 0)
            try await eventually { playback.selectedIndex == 0 }
            let source = try XCTUnwrap(playback.selectedID)
            let target = playback.timeline[1]
            playback.setRate(.half)
            playback.play()
            // Before the load task can run, the next frame is already owned, with no paced deadline.
            XCTAssertEqual(playback.selectedID, source)
            XCTAssertEqual(playback.desiredProtection, Set([source, target]))
            XCTAssertNil(playback.stepDeadline)
            XCTAssertFalse(playback.isWaitingForStepDeadline)
            try await eventually { playback.selectedID == target }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let transition = try XCTUnwrap(playback.transition)
                XCTAssertEqual(transition.from, source)
                XCTAssertEqual(transition.to, target)
                XCTAssertEqual(transition.duration, 2)
                XCTAssertEqual(playback.weather?.blend?.transition, transition)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(playback.selectedID, target, "Subsequent steps keep their paced interval")
        }
    }

    func testShowStartsRetainedLastFrameLoopWithoutInitialDeadlineHold() async throws {
        try await withModel { model in
            let playback = model.playback
            playback.seek(toIndex: playback.timeline.count - 1)
            try await eventually { playback.selectedIndex == playback.timeline.count - 1 }
            let source = try XCTUnwrap(playback.selectedID)
            let target = playback.timeline[0]
            model.setViewerVisible(false)
            model.setViewerVisible(true)
            XCTAssertEqual(playback.selectedID, source)
            XCTAssertEqual(playback.desiredProtection, Set([source, target]))
            XCTAssertNil(playback.stepDeadline)
            // The wrap cut may be followed at once by the blend out of the first frame, so record what the
            // poll sees instead of waiting to catch the first frame alone.
            var crossfadedIntoFirst = false
            try await eventually {
                if playback.transition?.to == target { crossfadedIntoFirst = true }
                return playback.selectedIndex == 1
            }
            XCTAssertFalse(crossfadedIntoFirst, "Loop wraps still cut to the original endpoint")
        }
    }

    func testRedundantShowRetainsActiveTransitionAndPacedTarget() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Blends are intentionally disabled by the system Reduce Motion setting")
        }
        try await withModel { model in
            let playback = model.playback
            playback.setRate(.half)
            try await startAtFirstObservation(playback)
            try await eventually { playback.transition != nil && playback.isWaitingForStepDeadline }
            let target = try XCTUnwrap(playback.selectedID)
            let transition = try XCTUnwrap(playback.transition)
            let serial = try XCTUnwrap(playback.weather?.serial)
            let deadline = try XCTUnwrap(playback.stepDeadline)
            let protected = playback.desiredProtection

            // A show and its deminiaturize notification may report the same visibility twice.
            model.setViewerVisible(true)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.stepDeadline, deadline)
            XCTAssertTrue(playback.isWaitingForStepDeadline)
            XCTAssertEqual(playback.desiredProtection, protected)
            try await eventually { playback.isWaitingForStepDeadline || playback.selectedID != target }
            XCTAssertEqual(playback.selectedID, target)
            XCTAssertEqual(playback.transition, transition)
            XCTAssertEqual(playback.weather?.blend?.transition, transition)
            XCTAssertEqual(playback.weather?.serial, serial)
        }
    }

    func testRedundantShowPreservesExplicitPause() async throws {
        try await withModel { model in
            let playback = model.playback
            let target = playback.selectedID
            let serial = playback.weather?.serial
            model.setViewerVisible(true)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.selectedID, target)
            XCTAssertEqual(playback.weather?.serial, serial)
            XCTAssertEqual(playback.desiredProtection, Set([try XCTUnwrap(target)]))
        }
    }

    func testPauseCancelsImmediatePlayBeforeItCanPresent() async throws {
        try await withModel { model in
            let playback = model.playback
            playback.seek(toIndex: 0)
            try await eventually { playback.selectedIndex == 0 }
            let source = try XCTUnwrap(playback.selectedID), serial = playback.weather?.serial
            playback.play()
            playback.pause()
            XCTAssertEqual(playback.desiredProtection, Set([source]))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(playback.selectedID, source)
            XCTAssertEqual(playback.weather?.serial, serial)
            XCTAssertNil(playback.stepDeadline)
        }
    }

    func testContinuousLoopWrapsAtRateAdjustedStepDeadline() async throws {
        try await withModel { model in
            let playback = model.playback
            playback.seek(toIndex: playback.timeline.count - 2)
            try await eventually { playback.selectedIndex == playback.timeline.count - 2 }
            playback.setRate(.quadruple)
            playback.play()
            try await eventually { playback.selectedIndex == playback.timeline.count - 1 }
            let presentedAt = playback.transition?.start ?? CACurrentMediaTime()
            let last = playback.selectedID
            try await eventually { playback.stepDeadline != nil }
            XCTAssertEqual(try XCTUnwrap(playback.stepDeadline), presentedAt + PlaybackController.stepDuration / 4, accuracy: 0.01)
            XCTAssertEqual(playback.selectedID, last)
            let first = playback.timeline[0]
            var crossfadedIntoFirst = false
            try await eventually {
                if playback.transition?.to == first { crossfadedIntoFirst = true }
                return playback.selectedIndex == 1
            }
            XCTAssertFalse(crossfadedIntoFirst, "Loop wraps cut to the original first endpoint")
        }
    }

    func testLoopWrapStartsFirstFrameStepWithoutStationaryHold() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Blends are intentionally disabled by the system Reduce Motion setting")
        }
        try await withModel { model in
            let playback = model.playback
            let timeline = playback.timeline
            // Two-second steps keep the bound well clear of a debug-build decode.
            let interval = PlaybackController.stepDuration / PlaybackRate.half.rawValue
            playback.seek(toIndex: timeline.count - 2)
            try await eventually { playback.selectedIndex == timeline.count - 2 }
            playback.setRate(.half)
            playback.play()
            try await eventually { playback.selectedIndex == timeline.count - 1 }
            let lastStart = try XCTUnwrap(playback.transition?.start, "The fixture's last step is an eligible blend")
            var crossfadedIntoFirst = false
            var firstSeen: CFTimeInterval?
            try await eventually {
                if playback.transition?.to == timeline[0] { crossfadedIntoFirst = true }
                if playback.selectedIndex == 0, firstSeen == nil { firstSeen = CACurrentMediaTime() }
                return playback.selectedIndex == 1
            }
            XCTAssertFalse(crossfadedIntoFirst, "The wrap must cut, never blend last -> first")
            let step = try XCTUnwrap(playback.transition)
            XCTAssertEqual(step.from, timeline[0])
            XCTAssertEqual(step.duration, interval)
            // A first frame too brief for the poll to see had no hold to measure.
            let wrap = firstSeen ?? step.start
            XCTAssertGreaterThanOrEqual(wrap, lastStart + interval - 0.01, "The last frame keeps its full step")
            // Only the decode of the next frame may separate the cut from the blend; the old schedule held a full step.
            XCTAssertLessThan(step.start - wrap, interval / 2, "The first frame must not hold still for a step of its own")
        }
    }

    func testSlowdownDuringPacedLoadKeepsSharedPresentationAndExtendsDeadline() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Blends are intentionally disabled by the system Reduce Motion setting")
        }
        try await withModel { model in
            let playback = model.playback
            try await startAtFirstObservation(playback)
            // `go` has started the next paced load, while the current transition is still displayed.
            try await eventually { playback.transition != nil && playback.isWaitingForStepDeadline }
            let old = try XCTUnwrap(playback.transition)
            let oldDeadline = try XCTUnwrap(playback.stepDeadline)
            let weather = try XCTUnwrap(playback.weather)
            let id = playback.selectedID
            let protected = playback.desiredProtection
            let now = CACurrentMediaTime()
            XCTAssertLessThan(now, oldDeadline)
            let instant = PresentationInstant.at(now, selected: id, selectedIndex: playback.selectedIndex,
                transition: old, timeline: playback.timeline)
            playback.setRate(.half, now: now)
            let retimed = try XCTUnwrap(playback.transition)
            let after = PresentationInstant.at(now, selected: playback.selectedID, selectedIndex: playback.selectedIndex,
                transition: retimed, timeline: playback.timeline)
            XCTAssertEqual(after.date!.timeIntervalSince1970, instant.date!.timeIntervalSince1970, accuracy: 0.000001)
            XCTAssertEqual(after.position!, instant.position!, accuracy: 0.00000001)
            XCTAssertEqual(after.interpolated, instant.interpolated)
            XCTAssertEqual(retimed.duration, 2)
            XCTAssertEqual(playback.stepDeadline!, now + (oldDeadline - now) * 2, accuracy: 0.000001)
            XCTAssertEqual(playback.weather?.blend?.transition, retimed)
            XCTAssertEqual(playback.weather?.serial, weather.serial + 1)
            XCTAssertEqual(playback.weather?.endpoint.bytes, weather.endpoint.bytes)
            XCTAssertEqual(playback.weather?.blend?.from.bytes, weather.blend?.from.bytes)
            XCTAssertEqual(playback.desiredProtection, protected)
            playback.setRate(.half, now: now)
            XCTAssertEqual(playback.weather?.serial, weather.serial + 1, "Selecting the current rate is a no-op")
            // Check after the obsolete deadline but before the extended one: neither old cut nor old load may win.
            let checkAt = (oldDeadline + retimed.end) / 2
            try await Task.sleep(for: .seconds(max(0, checkAt - CACurrentMediaTime())))
            XCTAssertEqual(playback.selectedID, id)
            XCTAssertEqual(playback.transition, retimed)
            try await eventually { playback.selectedID != id }
            XCTAssertEqual(playback.transition?.duration, 2)
        }
    }

    func testPausedRateChangePreservesEndpointAndResumeUsesNewRate() async throws {
        try await withModel { model in
            let playback = model.playback
            playback.pause()
            let id = playback.selectedID, serial = playback.weather?.serial, bytes = playback.weather?.endpoint.bytes
            playback.setRate(.quadruple)
            XCTAssertEqual(playback.rate, .quadruple)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.selectedID, id)
            XCTAssertEqual(playback.weather?.serial, serial)
            XCTAssertEqual(playback.weather?.endpoint.bytes, bytes)
            XCTAssertNil(playback.transition)
            XCTAssertNil(playback.stepDeadline)
            try await startAtFirstObservation(playback)
            try await eventually { playback.selectedIndex == 1 }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertEqual(playback.transition?.duration, 0.25)
            }
            playback.pause()
            let stopped = playback.weather?.serial
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(playback.weather?.serial, stopped, "Cancelled cut and step tasks must not change a paused endpoint")
        }
    }

    func testWaitingStepRateChangeRetimesResumeWithoutRestartingInterval() async throws {
        try await withModel { model in
            let playback = model.playback
            try await startAtFirstObservation(playback)
            try await eventually { playback.selectedIndex == 1 }
            let started = CACurrentMediaTime()
            try await Task.sleep(for: .milliseconds(700))
            let now = CACurrentMediaTime()
            playback.setRate(.quadruple, now: now)
            try await eventually { playback.stepDeadline != nil }
            let expected = MediaTransition.rescaledTime(started + 1, by: 0.25, at: now)
            XCTAssertEqual(try XCTUnwrap(playback.stepDeadline), expected, accuracy: 0.01,
                "A rate change must retime the remaining paced step, rather than restart a full interval")
            try await eventually { playback.selectedIndex == 2 }
        }
    }

    func testHideAndSuspendCancelRetimedWorkAndRetainSessionRateAndLease() async throws {
        try await withModel { model in
            let playback = model.playback
            try await startAtFirstObservation(playback)
            try await eventually { playback.selectedIndex == 1 }
            playback.setRate(.half)
            model.setSystemSuspended(true)
            let id = try XCTUnwrap(playback.selectedID), serial = playback.weather?.serial
            XCTAssertNil(playback.transition)
            XCTAssertNil(playback.stepDeadline)
            XCTAssertEqual(playback.desiredProtection, Set([id]))
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(playback.weather?.serial, serial)
            model.setSystemSuspended(false)
            XCTAssertEqual(playback.rate, .half)
            model.setViewerVisible(false)
            playback.setRate(.double)
            XCTAssertEqual(playback.desiredProtection, Set([id]))
            XCTAssertNil(playback.stepDeadline)
            XCTAssertNil(playback.transition)
            model.setViewerVisible(true)
            XCTAssertEqual(playback.rate, .double)
            try await eventually { playback.selectedID != id }
        }
    }
}

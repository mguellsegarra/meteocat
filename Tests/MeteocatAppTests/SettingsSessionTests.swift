import AppKit
import CoreLocation
import XCTest
import MeteocatCore
@testable import MeteocatApp

@MainActor
private final class SettingsPersistenceFake {
    var settings: UserSettings
    var writes = 0
    var failure: LocalizedMessage?
    var suspend = false
    var waiter: CheckedContinuation<Void, Never>?
    init(_ settings: UserSettings) { self.settings = settings }
    func update(_ change: @escaping (inout UserSettings) -> Void) async -> LocalizedMessage? {
        writes += 1
        if suspend { await withCheckedContinuation { waiter = $0 } }
        if let failure { return failure }
        var next = settings; change(&next)
        do { try SettingsStore.validate(next); settings = next; return nil }
        catch { return .core(error.localizedDescription) }
    }
}

@MainActor
private final class SettingsLocationManagerFake: LocationManaging {
    var delegate: CLLocationManagerDelegate?
    var authorizationStatus = CLAuthorizationStatus.authorizedAlways
    var servicesEnabled = true
    var authorizations = 0
    var requests = 0
    var cancellations = 0
    func requestAuthorization() { authorizations += 1 }
    func requestLocation() { requests += 1 }
    func cancelRequest() { cancellations += 1 }
}

@MainActor
final class SettingsSessionTests: XCTestCase {
    private let exact = GeoPoint(lon: 2.158991234, lat: 41.388791234)
    private func make(_ settings: UserSettings? = nil, locator: LocationLocator? = nil) throws -> (SettingsSession, SettingsPersistenceFake) {
        let settings = settings ?? UserSettings(cities: [City(id: "a", name: "Barcelona", point: exact),
            City(id: "b", name: "Girona", point: GeoPoint(lon: 2.82, lat: 41.98))], pin: exact)
        let persistence = SettingsPersistenceFake(settings)
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        return (SettingsSession(settings: settings, projection: projection, locator: locator ?? LocationLocator()) {
            await persistence.update($0)
        }, persistence)
    }
    func testAppearanceWritePreservesConcurrentDraftsAndLatestUnrelatedDomains() async throws {
        let (session, persistence) = try make()
        session.beginEdit("a")
        var editor = try XCTUnwrap(session.editor)
        editor.draft.name = "Nom pendent"; session.editor = editor
        session.pinLon = "pendent" // Invalid partial draft cannot autosave.
        session.search = "Barcelona"; session.selection = ["a"]
        persistence.suspend = true
        let task = try XCTUnwrap(session.setAppearance(.light))
        XCTAssertTrue(session.appearancePending)
        XCTAssertEqual(session.appearance, .automatic)
        XCTAssertNil(session.setAppearance(.dark))
        await waitForWrite(persistence)
        // Another domain publishes while the appearance transaction is waiting to read latest.
        persistence.settings.labelsVisible = false
        persistence.settings.showsInDock = false
        persistence.settings.cities[1].name = "Girona actualitzada"
        persistence.settings.pin = GeoPoint(lon: 2.2, lat: 41.4)
        session.reconcile(persistence.settings)
        persistence.suspend = false
        let waiter = persistence.waiter; persistence.waiter = nil; waiter?.resume()
        await task.value
        session.reconcile(persistence.settings)
        XCTAssertEqual(persistence.settings.appearance, .light)
        XCTAssertFalse(persistence.settings.labelsVisible)
        XCTAssertFalse(persistence.settings.showsInDock)
        XCTAssertEqual(persistence.settings.cities[1].name, "Girona actualitzada")
        XCTAssertEqual(persistence.settings.pin, GeoPoint(lon: 2.2, lat: 41.4))
        XCTAssertEqual(session.editor?.draft.name, "Nom pendent")
        XCTAssertEqual(session.pinLon, "pendent")
        XCTAssertEqual(session.search, "Barcelona")
        XCTAssertEqual(session.selection, ["a"])
        XCTAssertFalse(session.appearancePending)
        XCTAssertEqual(session.appearance, .light)
        XCTAssertEqual(persistence.writes, 1)
    }
    func testAppearanceFailureKeepsCommittedChoiceAndAllowsRetry() async throws {
        let (session, persistence) = try make()
        persistence.failure = .core("write failed")
        await session.setAppearance(.dark)?.value
        XCTAssertEqual(session.appearance, .automatic)
        XCTAssertEqual(persistence.settings.appearance, .automatic)
        XCTAssertEqual(session.appearanceMessage, L10n.coreMessage("write failed"))
        XCTAssertFalse(session.appearancePending)
        persistence.failure = nil
        await session.setAppearance(.dark)?.value
        XCTAssertEqual(session.appearance, .dark)
        XCTAssertNil(session.appearanceMessage)
        XCTAssertEqual(persistence.writes, 2)
    }
    func testAutomaticRestoresAppKitInheritance() {
        XCTAssertNil(AppAppearance.automatic.nativeAppearance)
        XCTAssertEqual(AppAppearance.light.nativeAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nativeAppearance?.name, .darkAqua)
    }
    func testPresenceLocksBothControlsUntilSaveAndKeepsEntriesOnFailure() async throws {
        let (session, persistence) = try make()
        persistence.suspend = true
        let task = try XCTUnwrap(session.setShowsInDock(false))
        XCTAssertTrue(session.presencePending)
        XCTAssertTrue(session.dockOptionDisabled && session.menuBarOptionDisabled)
        XCTAssertTrue(session.showsInDock && session.showsInMenuBar)
        XCTAssertNil(session.setShowsInMenuBar(false))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while persistence.waiter == nil, ContinuousClock.now < deadline { await Task.yield() }
        guard let waiter = persistence.waiter else {
            persistence.suspend = false; task.cancel()
            XCTFail("Presence write did not reach its suspension"); return
        }
        persistence.failure = .core("write failed")
        session.close {}
        waiter.resume(); persistence.waiter = nil
        await task.value
        XCTAssertTrue(session.showsInDock && session.showsInMenuBar)
        XCTAssertTrue(persistence.settings.showsInDock && persistence.settings.showsInMenuBar)
        XCTAssertFalse(session.presencePending)
        XCTAssertEqual(session.presenceMessage, L10n.coreMessage("write failed"))
        XCTAssertEqual(persistence.writes, 1)
        persistence.failure = nil; persistence.suspend = false
        await session.setShowsInDock(false)?.value
        XCTAssertFalse(session.showsInDock)
        XCTAssertTrue(session.menuBarOptionDisabled)
        XCTAssertFalse(session.dockOptionDisabled)
        XCTAssertNil(session.setShowsInMenuBar(false))
        XCTAssertEqual(persistence.writes, 2)
        await session.setShowsInDock(true)?.value
        await session.setShowsInMenuBar(false)?.value
        XCTAssertTrue(session.dockOptionDisabled)
        XCTAssertFalse(session.menuBarOptionDisabled)
        XCTAssertEqual(persistence.settings.pin, exact)
        XCTAssertEqual(persistence.settings.cities.count, 2)
    }
    func testRecordingCancellationOnlyWhenLeavingGeneralAndOnClose() throws {
        let (session, _) = try make()
        var cancellations = 0
        session.select(.general) { cancellations += 1 }
        XCTAssertEqual(cancellations, 0)
        session.select(.location) { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
        session.select(.map) { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
        session.select(.general) { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
        session.close { cancellations += 1 }
        XCTAssertEqual(cancellations, 2)
    }
    func testCoordinateAndIDValidation() throws {
        let (session, _) = try make()
        var draft = session.cities[0]
        for name in ["", "\nBarcelona", String(repeating: "x", count: 41), "bad\u{01}name"] {
            draft.name = name
            XCTAssertNil(CoordinateText.cities([draft], projection: session.projection).cities)
        }
        draft = session.cities[0]; draft.id = "bad id"
        XCTAssertNil(CoordinateText.cities([draft], projection: session.projection).cities)
        for lon in ["nan", "inf", "200", "not numeric"] {
            if case .success = CoordinateText.parse(lon: lon, lat: "41.4", original: nil, projection: session.projection) { XCTFail(lon) }
        }
        XCTAssertEqual(try CoordinateText.parse(lon: session.pinLon, lat: session.pinLat, original: exact, projection: session.projection).get(), exact)
    }
    func testNarrowRecorderNavigationForwarding() {
        XCTAssertEqual(Shortcut.defaultShortcut.keyCode, 15)
        XCTAssertEqual(Shortcut.defaultShortcut.carbonModifiers, 0x1800)
        XCTAssertTrue(ShortcutText.string(.defaultShortcut).hasPrefix("⌃⌥"))
        XCTAssertTrue(ShortcutRecorderModel.forwardsNavigation(keyCode: 48, flags: []))
        XCTAssertTrue(ShortcutRecorderModel.forwardsNavigation(keyCode: 48, flags: .shift))
        XCTAssertTrue(ShortcutRecorderModel.forwardsNavigation(keyCode: 13, flags: .command))
        XCTAssertFalse(ShortcutRecorderModel.forwardsNavigation(keyCode: 48, flags: .command))
        XCTAssertFalse(ShortcutRecorderModel.forwardsNavigation(keyCode: 13, flags: [.command, .shift]))
        XCTAssertFalse(ShortcutRecorderModel.forwardsNavigation(keyCode: 53, flags: []))
    }
    func testRealModelSerializesFieldScopedSavesInTemporaryStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: MeteocatResources.previewFixtureDirectory, to: fixture)
        let reference = try MeteocatResources.fixtureReferenceUTC()
        let client = SettingsForbiddenHTTP()
        let service = try await RadarService.open(cacheRoot: root.appendingPathComponent("cache"),
            mode: .fixture(directory: fixture, referenceUTC: reference), client: client, now: { Date() })
        let store = try await SettingsStore.open(at: root.appendingPathComponent("settings.json"))
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let model = RadarViewModel(service: service, store: store, settings: await store.load(), recoveryNotice: nil,
            geography: nil, projection: projection, fixtureCapture: reference)
        let session = SettingsSession(model: model)
        var publications: [UserSettings] = []
        let observation = model.observeSettings { publications.append($0) }
        XCTAssertEqual(publications, [model.settings])
        let shortcutController = GlobalShortcut()
        let recorder = ShortcutRecorderModel(model: model, shortcut: shortcutController)
        let firstRecording = try XCTUnwrap(recorder.start(monitorKeys: false))
        XCTAssertNil(recorder.start(monitorKeys: false))
        recorder.cancel(session: firstRecording + 1)
        XCTAssertTrue(recorder.isRecording)
        recorder.cancel(session: firstRecording)
        XCTAssertEqual(recorder.phase, .idle)
        let secondRecording = try XCTUnwrap(recorder.start(monitorKeys: false))
        recorder.cancel(session: firstRecording)
        XCTAssertTrue(recorder.isRecording)
        recorder.cancel()
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNotEqual(firstRecording, secondRecording)
        XCTAssertNil(shortcutController.registered)
        let firstID = try XCTUnwrap(session.cities.first?.id)
        let cityTask = try XCTUnwrap(session.setVisible(false, id: firstID))
        session.pinLon = CoordinateText.format(exact.lon); session.pinLat = CoordinateText.format(exact.lat)
        let pinTask = try XCTUnwrap(session.savePin())
        let labelTask = try XCTUnwrap(session.setLabels(false))
        let presenceTask = try XCTUnwrap(session.setShowsInDock(false))
        let shortcut = Shortcut(keyCode: 16, carbonModifiers: 0x1800)
        let shortcutTask = Task { await model.updateSettings { $0.shortcut = shortcut } }
        session.close {}
        await cityTask.value; await pinTask.value; await labelTask.value; await presenceTask.value
        let failure = await shortcutTask.value
        XCTAssertNil(failure)
        let committed = await store.load()
        XCTAssertEqual(committed, model.settings)
        XCTAssertFalse(committed.labelsVisible)
        XCTAssertFalse(committed.showsInDock)
        XCTAssertTrue(committed.showsInMenuBar)
        XCTAssertEqual(publications.count, 6, "Initial state and five serialized commits")
        XCTAssertEqual(publications.last, committed)
        let invalidFailure = await model.updateSettings { $0.showsInMenuBar = false }
        XCTAssertNotNil(invalidFailure)
        XCTAssertEqual(model.settings, committed)
        XCTAssertEqual(publications.count, 6, "Failed persistence must not route a presence change")
        model.removeSettingsObserver(observation)
        let nextFailure = await model.updateSettings { $0.showsInDock = true }
        XCTAssertNil(nextFailure)
        XCTAssertEqual(publications.count, 6, "Removed observation must not be called")
        // Restore the state used for the round-trip assertions below.
        let restoreFailure = await model.updateSettings { $0.showsInDock = false }
        XCTAssertNil(restoreFailure)
        XCTAssertEqual(committed.cities.first?.id, firstID)
        XCTAssertEqual(committed.cities.first?.visible, false)
        XCTAssertEqual(committed.pin?.lon, Double(CoordinateText.format(exact.lon)))
        XCTAssertEqual(committed.shortcut, shortcut)
        XCTAssertEqual(try NativeJSON.decode(UserSettings.self, AtomicFile.read(root.appendingPathComponent("settings.json"))), committed)
        XCTAssertFalse(session.citiesPending || session.pinPending || session.labelsPending || session.presencePending)
        var failurePublications: [UserSettings] = []
        let failureObservation = model.observeSettings { failurePublications.append($0) }
        let playbackSelection = model.playback.selectedID
        let viewerVisible = model.viewerVisible
        let settingsURL = root.appendingPathComponent("settings.json")
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
        let diskFailure = await model.updateSettings { $0.showsInDock = true }
        XCTAssertNotNil(diskFailure)
        XCTAssertEqual(model.settings, committed)
        let afterDiskFailure = await store.load()
        XCTAssertEqual(afterDiskFailure, committed)
        XCTAssertEqual(failurePublications, [committed], "A real failed atomic write must retain the live entries")
        XCTAssertEqual(model.playback.selectedID, playbackSelection)
        XCTAssertEqual(model.viewerVisible, viewerVisible)
        model.removeSettingsObserver(failureObservation)
        await service.shutdown()
        let requests = await client.requests
        XCTAssertEqual(requests, 0)
    }
    func testWindowTabMappingAndCloseIdentityWithoutShowing() async throws {
        guard NSApp != nil else {
            throw XCTSkip("No existing NSApplication context; do not create one or show a window for this offline test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-settings-window-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try MeteocatResources.fixtureReferenceUTC()
        let client = SettingsForbiddenHTTP()
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: MeteocatResources.previewFixtureDirectory, to: fixture)
        let service = try await RadarService.open(cacheRoot: root.appendingPathComponent("cache"),
            mode: .fixture(directory: fixture, referenceUTC: reference),
            client: client, now: { Date() })
        let store = try await SettingsStore.open(at: root.appendingPathComponent("settings.json"))
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        let model = RadarViewModel(service: service, store: store, settings: await store.load(), recoveryNotice: nil,
            geography: nil, projection: projection, fixtureCapture: reference)
        let shortcut = GlobalShortcut()
        let recorder = ShortcutRecorderModel(model: model, shortcut: shortcut)
        let controller = SettingsWindowController(model: model, shortcut: shortcut, recorder: recorder)
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertFalse(window.isVisible)
        _ = try XCTUnwrap(recorder.start(monitorKeys: false))
        tabs.selectedTabViewItemIndex = SettingsSession.Section.location.rawValue
        XCTAssertEqual(controller.session.section, .location)
        XCTAssertEqual(recorder.phase, .idle)
        tabs.selectedTabViewItemIndex = SettingsSession.Section.map.rawValue
        XCTAssertEqual(controller.session.section, .map)
        tabs.selectedTabViewItemIndex = SettingsSession.Section.general.rawValue
        XCTAssertEqual(controller.session.section, .general)
        _ = try XCTUnwrap(recorder.start(monitorKeys: false))
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: otherWindow))
        XCTAssertTrue(recorder.isRecording)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(shortcut.registered)
        XCTAssertFalse(window.isVisible)
        await service.shutdown()
        let requests = await client.requests
        XCTAssertEqual(requests, 0)
    }
    func testLocationDenialAndInvalidFixKeepDraft() throws {
        let fake = SettingsLocationManagerFake()
        let locator = LocationLocator { fake }
        let (session, persistence) = try make(locator: locator)
        session.select(.location) {}
        fake.authorizationStatus = .denied
        session.acquireLocation()
        if case .failed = locator.state {} else { XCTFail("Denial must fail without a fix") }
        XCTAssertEqual(fake.requests, 0)
        fake.authorizationStatus = .authorizedAlways
        session.acquireLocation()
        let poor = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 41.4, longitude: 2.2), altitude: 0,
            horizontalAccuracy: 6_000, verticalAccuracy: 10, timestamp: Date())
        locator.received([poor], generation: 2)
        if case .failed = locator.state {} else { XCTFail("Poor accuracy must fail") }
        session.acquireLocation()
        let old = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 41.4, longitude: 2.2), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date().addingTimeInterval(-120))
        locator.received([old], generation: 3)
        XCTAssertEqual(session.pinExact, exact)
        XCTAssertEqual(persistence.writes, 0)
        XCTAssertFalse(locator.isPending)
    }
    private func waitForCities(_ session: SettingsSession) async {
        await session.saveCities()?.value
    }
    private func waitForWrite(_ persistence: SettingsPersistenceFake) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while persistence.waiter == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(persistence.waiter)
    }
    func testEveryCityActionAutosavesAndCancelledSheetDoesNot() async throws {
        let (session, persistence) = try make()
        session.beginEdit("a")
        var copy = try XCTUnwrap(session.editor)
        copy.draft.name = "Cancelled"
        session.editor = nil
        XCTAssertEqual(persistence.writes, 0)
        await session.setVisible(false, id: "b")?.value
        XCTAssertFalse(persistence.settings.cities[1].visible)
        session.beginEdit("a")
        copy = try XCTUnwrap(session.editor)
        copy.draft.name = "Barcelona nova"; copy.draft.lat = "41,4"
        XCTAssertNil(session.accept(copy)); XCTAssertTrue(session.citiesPending)
        await waitForCities(session)
        XCTAssertEqual(persistence.settings.cities[0].name, "Barcelona nova")
        XCTAssertEqual(persistence.settings.cities[0].point.lon, exact.lon)
        session.beginAdd(); let added = try XCTUnwrap(session.editor)
        XCTAssertNil(session.accept(added)); await waitForCities(session)
        XCTAssertEqual(persistence.settings.cities.count, 3)
        session.selection = [added.draft.id]
        await session.deleteSelection()?.value
        XCTAssertEqual(persistence.settings.cities.count, 2)
        XCTAssertEqual(persistence.writes, 4)
        XCTAssertEqual(persistence.settings.pin, exact)
    }
    func testLatestCityTransactionPreservesConcurrentChangesAndRejectsDeletedID() async throws {
        let (session, persistence) = try make()
        persistence.suspend = true
        let task = try XCTUnwrap(session.setVisible(false, id: "a"))
        XCTAssertTrue(session.citiesPending)
        XCTAssertNil(session.setVisible(true, id: "a"))
        await waitForWrite(persistence)
        persistence.settings.cities[1].name = "Girona latest"
        persistence.settings.knownDefaultCityIDs = ["a", "removed-default"]
        persistence.settings.showsInDock = false
        persistence.waiter?.resume(); persistence.waiter = nil
        await task.value
        XCTAssertEqual(persistence.settings.cities[1].name, "Girona latest")
        XCTAssertEqual(persistence.settings.knownDefaultCityIDs, ["a", "removed-default"])
        XCTAssertFalse(persistence.settings.showsInDock)
        session.beginEdit("a"); var stale = try XCTUnwrap(session.editor)
        stale.draft.name = "Must not return"
        persistence.settings.cities.removeAll { $0.id == "a" }
        persistence.suspend = false
        XCTAssertNil(session.accept(stale)); await waitForCities(session)
        XCTAssertEqual(session.citiesMessage, L10n.text("La ciutat ja no existeix."))
        XCTAssertEqual(persistence.settings.cities.map(\.id), ["b"])
        XCTAssertEqual(session.cities.map(\.id), ["b"])
    }
    func testAddRevalidatesLatestLimitAndDuplicate() async throws {
        for duplicate in [false, true] {
            let (session, persistence) = try make()
            session.beginAdd(); let copy = try XCTUnwrap(session.editor)
            if duplicate { persistence.settings.cities.append(City(id: copy.draft.id, name: "Existing", point: exact)) }
            else { persistence.settings.cities = (0..<60).map { City(id: "c\($0)", name: "City", point: exact) } }
            XCTAssertNil(session.accept(copy)); await waitForCities(session)
            XCTAssertNotNil(session.citiesMessage)
            XCTAssertEqual(persistence.settings.cities.count, duplicate ? 3 : 60)
        }
    }
    func testCitySearchRestrictsDeletionToVisibleSelectedIDs() async throws {
        let (session, persistence) = try make()
        session.selection = ["b"]; session.search = "Barc"
        XCTAssertTrue(session.selection.isEmpty)
        XCTAssertNil(session.deleteSelection()); XCTAssertEqual(persistence.writes, 0)
        session.selection = ["a", "b"]
        await session.deleteSelection()?.value
        XCTAssertEqual(persistence.settings.cities.map(\.id), ["b"])
    }
    func testInvalidPartialCoordinatesNeverWriteAndUntouchedAxisIsExact() async throws {
        let (session, persistence) = try make()
        session.pinLat = "-"
        try await Task.sleep(for: .milliseconds(450))
        session.close {}
        XCTAssertEqual(persistence.writes, 0)
        session.pinLat = "41,4"
        await session.flushPin()?.value
        XCTAssertEqual(persistence.settings.pin?.lat, 41.4)
        XCTAssertEqual(persistence.settings.pin?.lon, exact.lon)
        XCTAssertFalse(session.pinDirty)
    }
    func testDebounceCoalescesAndCloseBeforeDelayFlushesValidPair() async throws {
        let (session, persistence) = try make()
        session.select(.location) {}
        session.pinLat = "41.4"; session.pinLon = "2.2"; session.pinLon = "2.21"
        try await Task.sleep(for: .milliseconds(450))
        await session.flushPin()?.value
        XCTAssertEqual(persistence.writes, 1)
        XCTAssertEqual(persistence.settings.pin, GeoPoint(lon: 2.21, lat: 41.4))
        session.pinLat = "41.5"
        session.close {}
        await session.flushPin()?.value
        XCTAssertEqual(persistence.writes, 2)
        XCTAssertEqual(persistence.settings.pin?.lat, 41.5)
        session.pinLat = "41.6"
        session.select(.map) {}
        await session.flushPin()?.value
        XCTAssertEqual(persistence.settings.pin?.lat, 41.6)
    }
    func testSuspendedWriteDoesNotNormalizeNewerTextAndCloseFinishesLatest() async throws {
        let (session, persistence) = try make()
        persistence.suspend = true
        session.pinLat = "41.4"
        let first = try XCTUnwrap(session.flushPin())
        await waitForWrite(persistence)
        session.pinLat = "41.51234567"
        session.close {}
        let waiter = persistence.waiter; persistence.waiter = nil; waiter?.resume()
        await first.value
        XCTAssertEqual(session.pinLat, "41.51234567", "Older completion must not replace newer text")
        await waitForWrite(persistence)
        let latest = session.flushPin()
        persistence.suspend = false
        let latestWaiter = persistence.waiter; persistence.waiter = nil; latestWaiter?.resume()
        await latest?.value
        XCTAssertEqual(persistence.settings.pin?.lat, 41.51234567)
        XCTAssertEqual(persistence.settings.pin?.lon, exact.lon)
        XCTAssertEqual(persistence.writes, 2)
    }
    func testInvalidNewerTextSurvivesEarlierWriteCompletion() async throws {
        let (session, persistence) = try make()
        persistence.suspend = true
        session.pinLat = "41.4"
        let task = try XCTUnwrap(session.flushPin())
        await waitForWrite(persistence)
        session.pinLat = "-"; session.close {}
        persistence.suspend = false
        let waiter = persistence.waiter; persistence.waiter = nil; waiter?.resume()
        await task.value
        XCTAssertEqual(session.pinLat, "-")
        XCTAssertEqual(session.savedPin?.lat, 41.4)
        XCTAssertEqual(persistence.writes, 1)
    }
    func testPinRemovalFailureRetriesRemovalAndNewerEditSurvivesCompletion() async throws {
        let (session, persistence) = try make()
        persistence.failure = .core("write failed")
        await session.removePin()?.value
        XCTAssertTrue(session.canRetryPin)
        XCTAssertEqual(session.savedPin, exact)
        persistence.failure = nil
        await session.retryPin()?.value
        XCTAssertNil(persistence.settings.pin)
        // Refill, then type while a removal is in flight.
        session.pinLon = "2.2"; session.pinLat = "41.4"
        await session.flushPin()?.value
        persistence.suspend = true
        let task = try XCTUnwrap(session.removePin())
        await waitForWrite(persistence)
        session.pinLat = "41.51234567"; session.close {}
        let waiter = persistence.waiter; persistence.waiter = nil; waiter?.resume()
        await task.value
        XCTAssertEqual(session.pinLat, "41.51234567")
        await waitForWrite(persistence)
        let latest = session.flushPin()
        persistence.suspend = false
        let latestWaiter = persistence.waiter; persistence.waiter = nil; latestWaiter?.resume()
        await latest?.value
        XCTAssertEqual(persistence.settings.pin, GeoPoint(lon: 2.2, lat: 41.51234567))
    }
    func testWriteFailureKeepsChangesForExplicitRetryWithoutLoops() async throws {
        let (session, persistence) = try make()
        persistence.failure = .core("write failed")
        await session.setVisible(false, id: "a")?.value
        XCTAssertFalse(session.cities[0].visible)
        XCTAssertTrue(persistence.settings.cities[0].visible)
        XCTAssertEqual(session.citiesMessage, L10n.coreMessage("write failed"))
        session.pinLat = "41.4"
        await session.flushPin()?.value
        XCTAssertEqual(session.pinLat, "41.4")
        XCTAssertEqual(session.savedPin, exact)
        XCTAssertEqual(session.pinMessage, L10n.coreMessage("write failed"))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(persistence.writes, 2)
        persistence.failure = nil
        await session.saveCities()?.value; await session.flushPin()?.value
        XCTAssertFalse(persistence.settings.cities[0].visible)
        XCTAssertEqual(persistence.settings.pin?.lat, 41.4)
        XCTAssertNil(session.citiesMessage); XCTAssertNil(session.pinMessage)
    }
    func testManualCoordinateAutosavesBeforeSlowFailedLocationRequest() async throws {
        let fake = SettingsLocationManagerFake()
        let locator = LocationLocator { fake }
        let (session, persistence) = try make(locator: locator)
        session.select(.location) {}
        session.pinLat = "41.41234567"
        session.acquireLocation()
        XCTAssertEqual(fake.requests, 1)
        XCTAssertTrue(locator.isPending)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(persistence.writes, 1)
        let manual = GeoPoint(lon: exact.lon, lat: 41.41234567)
        XCTAssertEqual(persistence.settings.pin, manual)
        XCTAssertEqual(session.savedPin, manual)
        locator.failed(CLError(.locationUnknown), generation: 1)
        if case .failed = locator.state {} else { XCTFail("The fake request must fail") }
        locator.received([location(GeoPoint(lon: 2.2, lat: 41.5))], generation: 1)
        XCTAssertEqual(session.savedPin, manual)
        XCTAssertEqual(session.pinExact, manual)
        XCTAssertEqual(session.pinLat, CoordinateText.format(manual.lat))
        XCTAssertEqual(persistence.writes, 1)
        XCTAssertFalse(session.pinDirty)
    }
    func testNewLocationFixSurvivesCompletionOfPreRequestManualWrite() async throws {
        let fake = SettingsLocationManagerFake()
        let locator = LocationLocator { fake }
        let (session, persistence) = try make(locator: locator)
        persistence.suspend = true
        session.select(.location) {}
        session.pinLat = "41.4"
        session.acquireLocation()
        await waitForWrite(persistence)
        let fix = GeoPoint(lon: 2.23456789, lat: 41.51234567)
        locator.received([location(fix)], generation: 1)
        let first = session.flushPin()
        let waiter = persistence.waiter; persistence.waiter = nil; waiter?.resume()
        await first?.value
        XCTAssertEqual(session.pinExact, fix)
        XCTAssertEqual(session.pinLat, CoordinateText.format(fix.lat))
        await waitForWrite(persistence)
        let latest = session.flushPin()
        persistence.suspend = false
        let latestWaiter = persistence.waiter; persistence.waiter = nil; latestWaiter?.resume()
        await latest?.value
        XCTAssertEqual(persistence.settings.pin, fix)
        XCTAssertEqual(session.savedPin, fix)
        XCTAssertEqual(persistence.writes, 2)
    }
    func testFakeLocationAutosavesOnceAndLateCallbackIsIgnored() async throws {
        let fake = SettingsLocationManagerFake()
        let locator = LocationLocator { fake }
        let (session, persistence) = try make(locator: locator)
        session.select(.location) {}
        XCTAssertEqual(fake.requests, 0)
        session.acquireLocation()
        let next = GeoPoint(lon: exact.lon + 0.0000001, lat: exact.lat + 0.0000001)
        locator.received([location(next)], generation: 1)
        await session.flushPin()?.value
        XCTAssertEqual(persistence.settings.pin, next)
        XCTAssertEqual(persistence.writes, 1)
        XCTAssertTrue(session.pinSavedFeedback)
        session.acquireLocation(); session.close {}
        locator.received([location(GeoPoint(lon: 2.2, lat: 41.5))], generation: 2)
        XCTAssertEqual(session.pinExact, next)
        XCTAssertEqual(persistence.writes, 1)
        XCTAssertFalse(locator.isPending)
    }
    func testRemovalCancelsDelayedCoordinatesAndPreservesCityDomain() async throws {
        let (session, persistence) = try make()
        await session.setVisible(false, id: "b")?.value
        session.pinLat = "41.4"
        await session.removePin()?.value
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(persistence.settings.pin)
        XCTAssertEqual(session.pinLat, "")
        XCTAssertFalse(persistence.settings.cities[1].visible)
        XCTAssertEqual(persistence.writes, 2)
    }
    private func location(_ point: GeoPoint) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
    }
}

private actor SettingsForbiddenHTTP: HTTPClient {
    private(set) var requests = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

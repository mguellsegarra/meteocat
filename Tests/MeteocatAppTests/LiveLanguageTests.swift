import AppKit
import CoreLocation
import Observation
import XCTest
import MeteocatCore
@testable import MeteocatApp

private actor LanguageTestHTTP: HTTPClient {
    private(set) var requests = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor private final class DeniedLanguageLocation: LocationManaging {
    var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus { .denied }
    var servicesEnabled: Bool { true }
    func requestAuthorization() { XCTFail("Denied location must not request authorization") }
    func requestLocation() { XCTFail("Denied location must not request a fix") }
    func cancelRequest() {}
}

@MainActor final class LiveLanguageTests: XCTestCase {
    private func withLanguage(_ body: (UserDefaults) async throws -> Void) async throws {
        let snapshot = L10n.current, preference = L10n.preference
        let suite = "MeteocatLiveLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
            L10n.state.install(snapshot, preference: preference)
        }
        try await body(defaults)
    }

    func testImmediateStringsDatesDirectionObservationAndRuntimeOverride() async throws {
        try await withLanguage { defaults in
            defaults.set(["fr"], forKey: "AppleLanguages")
            defaults.setVolatileDomain(["AppleLanguages": ["ar"]], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), ["ar"])
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z"))
            let id = try FrameID(kind: .forecast, validUTC: date, originUTC: date.addingTimeInterval(-360))
            let identity = String(describing: id)
            var dates = [String: String]()
            var notices = [String: String]()
            let notice = LocalizedMessage.core("Meteocat ha retornat un error HTTP 503. Es conserva el radar complet.")
            let diagnostic = LocalizedMessage.core("PNG CRC mismatch at IDAT")
            let shortcut = LocalizedMessage.key("Drecera desada: %1$@.", [.shortcut(Shortcut(keyCode: 49, carbonModifiers: 0))])
            for language in ["en", "ca", "ar", "en"] {
                let changed = expectation(description: "Observable language dependency \(language)")
                withObservationTracking {
                    _ = L10n.text("Configuració")
                    _ = Fmt.day(date)
                } onChange: { changed.fulfill() }
                L10n.setPreference(language, defaults: defaults)
                await fulfillment(of: [changed], timeout: 1)
                XCTAssertEqual(L10n.current.language, language)
                XCTAssertEqual(L10n.text("Configuració"), AppLocalization(bundle: L10n.current.resourceBundle, preferences: [language]).text("Configuració"))
                XCTAssertEqual(L10n.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
                XCTAssertEqual(Fmt.time(date), "14:00")
                XCTAssertEqual(Fmt.leadMinutes(id), 6)
                XCTAssertEqual(String(describing: id), identity)
                let day = Fmt.day(date), full = Fmt.full(date)
                XCTAssertTrue(full.contains("2026") || language == "ar")
                if let previous = dates[language] { XCTAssertEqual(day, previous) }
                dates[language] = day; notices[language] = notice.rendered
                XCTAssertTrue(notice.rendered.contains("503"))
                XCTAssertTrue(diagnostic.rendered.contains("PNG CRC mismatch at IDAT"))
                XCTAssertTrue(shortcut.rendered.contains(ShortcutText.keyName(49)))
                XCTAssertEqual(notice, .core("Meteocat ha retornat un error HTTP 503. Es conserva el radar complet."))
            }
            XCTAssertNotEqual(dates["en"], dates["ca"])
            XCTAssertNotEqual(dates["en"], dates["ar"])
            XCTAssertNotEqual(notices["en"], notices["ca"])
            L10n.setPreference("", defaults: defaults)
            XCTAssertEqual(L10n.current.language, "ar", "Follow System includes macOS launch preferences")
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            L10n.setPreference("", defaults: defaults)
            XCTAssertEqual(L10n.current.language, "fr")
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
            XCTAssertEqual(defaults.string(forKey: AppLanguagePreference.key), "")
        }
    }

    func testMenusRetitleInPlaceAndPreserveWindowEntries() async throws {
        try await withLanguage { defaults in
            L10n.setPreference("en", defaults: defaults)
            let main = NSMenu()
            let windows = LocalizedMenu.make(key: "Finestra")
            let root = NSMenuItem(); root.submenu = windows; main.addItem(root)
            let command = windows.addLocalizedItem(key: "Minimitza", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            let dynamic = NSMenuItem(title: "Marc's radar window", action: nil, keyEquivalent: "")
            dynamic.identifier = NSUserInterfaceItemIdentifier("AppKitWindow.42")
            windows.addItem(dynamic)
            let foreignMenu = NSMenu(title: "Native submenu")
            foreignMenu.identifier = NSUserInterfaceItemIdentifier("AppKitNativeSubmenu.7")
            let foreignRoot = NSMenuItem(title: "Native submenu entry", action: nil, keyEquivalent: "")
            foreignRoot.identifier = NSUserInterfaceItemIdentifier("AppKitNativeItem.7")
            foreignRoot.submenu = foreignMenu
            main.addItem(foreignRoot)
            let itemIDs = windows.items.map(ObjectIdentifier.init)
            for language in ["ca", "ar", "en"] {
                L10n.setPreference(language, defaults: defaults)
                LocalizedMenu.retitle(main)
                XCTAssertTrue(root.submenu === windows)
                XCTAssertEqual(windows.items.map(ObjectIdentifier.init), itemIDs)
                XCTAssertEqual(command.title, L10n.text("Minimitza"))
                XCTAssertEqual(root.title, L10n.text("Finestra"))
                XCTAssertEqual(windows.title, L10n.text("Finestra"))
                XCTAssertEqual(dynamic.title, "Marc's radar window")
                XCTAssertEqual(foreignRoot.title, "Native submenu entry")
                XCTAssertEqual(foreignMenu.title, "Native submenu")
                XCTAssertTrue(foreignRoot.submenu === foreignMenu)
            }
        }
    }

    func testStoredNoticesSessionRecorderPlaybackAndHostsRetainIdentity() async throws {
        try await withLanguage { defaults in
            L10n.setPreference("en", defaults: defaults)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-language-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = root.appendingPathComponent("fixture")
            try FileManager.default.copyItem(at: MeteocatResources.previewFixtureDirectory, to: fixture)
            let info = try NativeJSON.decode(SnapshotInfo.self, AtomicFile.read(fixture.appendingPathComponent("snapshot-info.json")))
            let http = LanguageTestHTTP()
            let service = try await RadarService.open(cacheRoot: root.appendingPathComponent("cache"), mode: .fixture(directory: fixture, referenceUTC: info.capturedAt), client: http, now: { info.capturedAt })
            let store = try await SettingsStore.open(at: root.appendingPathComponent("settings.json"))
            let settings = await store.load()
            let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
            let recoveryKey = "La previsió ha caducat. Es mostra l'última observació."
            let model = RadarViewModel(service: service, store: store, settings: settings, recoveryNotice: recoveryKey, geography: nil, projection: projection, fixtureCapture: info.capturedAt)
            await model.start()
            model.setViewerVisible(true)
            let deadline = ContinuousClock.now + .seconds(10)
            while model.playback.weather == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(model.playback.weather)
            model.presenceErrorToken = .text("No s'ha pogut canviar la presència al Dock. La barra de menús continua disponible.")
            let shortcut = GlobalShortcut()
            let recorder = ShortcutRecorderModel(model: model, shortcut: shortcut)
            let session = SettingsSession(settings: settings, projection: projection) { _ in .core("Disk write failed") }
            session.pinLon = "unfinished longitude"; session.pinLat = "41.7"
            session.search = "user search"
            session.beginAdd()
            let editorID = try XCTUnwrap(session.editor?.id)
            session.editor?.draft.name = "User city name"
            let task = try XCTUnwrap(session.setLabels(!settings.labelsVisible))
            await task.value
            let previousNotice = try XCTUnwrap(session.labelsMessage)
            let pendingSave = try XCTUnwrap(session.setAppearance(.dark))
            var invalidEditor = try XCTUnwrap(session.editor)
            invalidEditor.draft.name = ""
            let validation = try XCTUnwrap(session.accept(invalidEditor))
            let locator = LocationLocator(makeManager: { DeniedLanguageLocation() })
            locator.request { _ in XCTFail("Denied location must not deliver a fix") }
            let deniedState = locator.state
            let recording = try XCTUnwrap(recorder.start(monitorKeys: false))
            let controller = SettingsWindowController(model: model, shortcut: shortcut, recorder: recorder, session: session)
            let window = try XCTUnwrap(controller.window)
            let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
            let hosts = tabs.tabViewItems.compactMap(\.viewController).map(ObjectIdentifier.init)
            let tabIDs = tabs.tabViewItems.map(ObjectIdentifier.init)
            let playback = model.playback
            playback.setRate(.quadruple)
            playback.pause()
            let snapshot = try XCTUnwrap(model.snapshot)
            // Fail a frame which has not been decoded, retaining the last good image and its identity.
            let missing = try XCTUnwrap(snapshot.observations.first)
            let tile = fixture.appendingPathComponent(try XCTUnwrap(missing.tiles.first).relativePath)
            let bytes = try Data(contentsOf: tile)
            try FileManager.default.removeItem(at: tile)
            playback.seek(toIndex: try XCTUnwrap(playback.timeline.firstIndex(of: missing.id)))
            let failureDeadline = ContinuousClock.now + .seconds(10)
            while playback.frameError == nil, ContinuousClock.now < failureDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(playback.frameError)
            try bytes.write(to: tile)
            // The suspended transaction test keeps a save pending throughout the synchronous language changes.
            await pendingSave.value
            let secondPendingSave = try XCTUnwrap(session.setAppearance(.dark))
            let selected = playback.selectedID
            let timeline = playback.timeline, weatherSerial = playback.weather?.serial
            for language in ["ca", "ar", "en"] {
                L10n.setPreference(language, defaults: defaults)
                XCTAssertEqual(locator.state, deniedState, "Message identity must not depend on rendered language")
                if case .failed(let notice) = locator.state {
                    XCTAssertEqual(notice.rendered, L10n.text("Meteocat no té permís per usar la ubicació. Activa'l a Configuració del Sistema > Privadesa i seguretat > Localització."))
                } else { XCTFail("Denied location must retain the error") }
                XCTAssertEqual(validation.rendered, L10n.text("El nom ha de tenir entre 1 i 40 caràcters."))
                XCTAssertTrue(session.appearancePending)
                XCTAssertEqual(playback.frameError, L10n.text("No s'ha pogut mostrar el fotograma de les %1$@.", Fmt.time(missing.id.validUTC)))
                XCTAssertEqual(model.recoveryNotice, L10n.text(recoveryKey))
                XCTAssertEqual(model.presenceError, model.presenceErrorToken?.rendered)
                XCTAssertEqual(session.labelsMessage, LocalizedMessage.core("Disk write failed").rendered)
                XCTAssertEqual(session.pinLon, "unfinished longitude")
                XCTAssertTrue(session.pinDirty)
                XCTAssertFalse(session.labelsPending || session.pinPending || session.citiesPending)
                XCTAssertEqual(session.search, "user search")
                XCTAssertEqual(session.editor?.id, editorID)
                XCTAssertEqual(session.editor?.draft.name, "User city name")
                XCTAssertEqual(recorder.phase, .recording(generation: recording))
                XCTAssertEqual(recorder.message, L10n.text("Inclou ⌘, ⌥ o ⌃. Esc cancel·la."))
                XCTAssertTrue(controller.window === window)
                XCTAssertEqual(tabs.tabViewItems.map(ObjectIdentifier.init), tabIDs)
                XCTAssertEqual(tabs.tabViewItems.compactMap(\.viewController).map(ObjectIdentifier.init), hosts)
                XCTAssertEqual(tabs.selectedTabViewItemIndex, session.section.rawValue)
                for (item, section) in zip(tabs.tabViewItems, SettingsSession.Section.allCases) {
                    XCTAssertEqual(item.label, section.title)
                    XCTAssertEqual(item.viewController?.title, section.title)
                    XCTAssertEqual(item.image?.accessibilityDescription, section.title)
                }
                XCTAssertEqual(window.title, session.section.title)
                XCTAssertEqual(playback.selectedID, selected)
                XCTAssertEqual(playback.rate, .quadruple)
                XCTAssertFalse(playback.isPlaying)
                XCTAssertEqual(playback.timeline, timeline)
                XCTAssertEqual(playback.weather?.serial, weatherSerial)
                XCTAssertEqual(model.snapshot?.revision, snapshot.revision)
                XCTAssertEqual(model.settings, settings)
            }
            // Active playback is also preserved without awaiting a media-clock step.
            playback.play()
            XCTAssertTrue(playback.isPlaying)
            for language in ["en", "ca", "ar", "en"] {
                L10n.setPreference(language, defaults: defaults)
                XCTAssertTrue(playback.isPlaying)
                XCTAssertEqual(playback.rate, .quadruple)
                XCTAssertEqual(playback.selectedID, selected)
                XCTAssertEqual(playback.weather?.serial, weatherSerial)
            }
            playback.pause()
            await secondPendingSave.value
            L10n.setPreference("ca", defaults: defaults)
            XCTAssertNotEqual(session.labelsMessage, previousNotice)
            recorder.cancel()
            model.setViewerVisible(false)
            await model.shutdown()
            let requests = await http.requests
            XCTAssertEqual(requests, 0)
        }
    }
}

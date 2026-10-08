import Foundation
import XCTest
@testable import MeteocatCore

final class DefaultCityUpdateTests: XCTestCase {
    private let additions = ["mun:252192", "mun:431763", "mun:250404", "mun:171479", "mun:081022"]

    private func temporaryURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-default-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("settings.json")
    }

    func testLegacyMigrationPreservesChoicesAndAddsNewDefaultsOnce() async throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaults = try MeteocatResources.defaultSettings()
        var legacy = defaults
        legacy.knownDefaultCityIDs = nil
        legacy.cities = Array(defaults.cities.prefix(2))
        legacy.cities.reverse()
        legacy.cities[0].name = "Nom personalitzat"
        legacy.cities[0].visible = false
        legacy.cities.append(City(id: "custom", name: "Punt propi", point: defaults.cities[0].point))
        legacy.labelsVisible = false
        legacy.pin = defaults.cities[1].point
        legacy.shortcut = Shortcut(keyCode: 16, carbonModifiers: 0x1800)
        legacy.showsInDock = false
        try AtomicFile.write(NativeJSON.encode(legacy), to: url)
        let store = try await SettingsStore.open(at: url)
        let migrated = await store.load()
        XCTAssertEqual(Array(migrated.cities.prefix(3)), legacy.cities)
        XCTAssertEqual(Array(migrated.cities.dropFirst(3)).map(\.id), additions)
        XCTAssertEqual(migrated.pin, legacy.pin)
        XCTAssertEqual(migrated.shortcut, legacy.shortcut)
        XCTAssertEqual(migrated.labelsVisible, legacy.labelsVisible)
        XCTAssertEqual(migrated.showsInDock, legacy.showsInDock)
        XCTAssertEqual(migrated.showsInMenuBar, legacy.showsInMenuBar)
        XCTAssertEqual(migrated.version, 1)
        XCTAssertEqual(Set(migrated.knownDefaultCityIDs ?? []), Set(defaults.cities.map(\.id)))
        let bytes = try AtomicFile.read(url)
        let reopened = try await SettingsStore.open(at: url)
        let again = await reopened.load()
        XCTAssertEqual(again, migrated)
        XCTAssertEqual(try AtomicFile.read(url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["settings.json"])
    }

    func testExistingNewCityIsNotOverwrittenAndDeletedAdditionStaysDeleted() async throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaults = try MeteocatResources.defaultSettings()
        var legacy = defaults
        legacy.knownDefaultCityIDs = nil
        let tarroja = try XCTUnwrap(defaults.cities.first { $0.id == additions[0] })
        var renamed = tarroja
        renamed.name = "Tarroja pròpia"; renamed.visible = false
        legacy.cities = [renamed]
        try AtomicFile.write(NativeJSON.encode(legacy), to: url)
        let store = try await SettingsStore.open(at: url)
        var migrated = await store.load()
        XCTAssertEqual(migrated.cities.first, renamed)
        XCTAssertEqual(migrated.cities.count, 5)
        migrated.cities.removeAll { $0.id == tarroja.id }
        try await store.save(migrated)
        let reopened = try await SettingsStore.open(at: url)
        let loaded = await reopened.load()
        XCTAssertEqual(loaded, migrated)
        XCTAssertFalse(loaded.cities.contains { $0.id == tarroja.id })
    }

    func testCapacityPreservesCustomCitiesAndDoesNotRetrySkippedDefaults() async throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaults = try MeteocatResources.defaultSettings()
        var legacy = defaults
        legacy.knownDefaultCityIDs = nil
        legacy.cities = (0..<59).map { City(id: "custom:\($0)", name: "Ciutat \($0)", point: defaults.cities[0].point) }
        try AtomicFile.write(NativeJSON.encode(legacy), to: url)
        let store = try await SettingsStore.open(at: url)
        var loaded = await store.load()
        XCTAssertEqual(loaded.cities.count, 60)
        XCTAssertEqual(Array(loaded.cities.prefix(59)), legacy.cities)
        XCTAssertEqual(loaded.cities.last?.id, additions[0])
        loaded.cities.removeLast()
        try await store.save(loaded)
        let reopened = try await SettingsStore.open(at: url)
        let again = await reopened.load()
        XCTAssertEqual(again, loaded)
        XCTAssertEqual(again.cities.count, 59)
    }

    func testFreshDefaultsAlreadyRecordCurrentCatalog() async throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try await SettingsStore.open(at: url)
        var initial = await store.load()
        XCTAssertEqual(Set(initial.knownDefaultCityIDs ?? []), Set(initial.cities.map(\.id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        initial.cities.removeAll { $0.id == additions[0] }
        try await store.save(initial)
        let reopened = try await SettingsStore.open(at: url)
        let loaded = await reopened.load()
        XCTAssertEqual(loaded, initial)
    }
}

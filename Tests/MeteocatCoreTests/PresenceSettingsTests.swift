import Foundation
import XCTest
@testable import MeteocatCore

final class PresenceSettingsTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-presence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testOldSettingsMissingPresenceKeysPreserveEveryExistingFieldWithoutRecovery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var original = try MeteocatResources.defaultSettings()
        original.cities = Array(original.cities.prefix(2))
        original.cities[0].name = "Ciutat pròpia"
        original.cities[0].visible = false
        original.labelsVisible = false
        original.pin = original.cities[0].point
        original.shortcut = Shortcut(keyCode: 16, carbonModifiers: 0x1800)
        let encoded = try NativeJSON.encode(original)
        for missing in [["showsInDock", "showsInMenuBar"], ["showsInDock"], ["showsInMenuBar"]] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            for key in missing { json.removeValue(forKey: key) }
            let data = try JSONSerialization.data(withJSONObject: json)
            let url = root.appendingPathComponent("settings.json")
            try AtomicFile.write(data, to: url)
            let store = try await SettingsStore.open(at: url)
            let loaded = await store.load()
            let notice = await store.recoveryNotice()
            XCTAssertEqual(loaded, original)
            XCTAssertNil(notice)
            XCTAssertEqual(try AtomicFile.read(url), data, "Opening old valid settings must not rewrite them")
            try await store.save(loaded)
            let reopened = try await SettingsStore.open(at: url)
            let roundTrip = await reopened.load()
            XCTAssertEqual(roundTrip, original)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["settings.json"])
    }

    func testBothOffLoadRepairsOnlyPresenceAndDefersDiskWriteUntilSave() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var original = try MeteocatResources.defaultSettings()
        original.cities = Array(original.cities.prefix(1))
        original.cities[0].visible = false
        original.pin = original.cities[0].point
        original.shortcut = Shortcut(keyCode: 16, carbonModifiers: 0x1800)
        original.labelsVisible = false
        original.showsInDock = false; original.showsInMenuBar = false
        let bytes = try NativeJSON.encode(original)
        try AtomicFile.write(bytes, to: url)
        var expected = original; expected.showsInMenuBar = true
        for _ in 0..<2 {
            let store = try await SettingsStore.open(at: url)
            let loaded = await store.load()
            let notice = await store.recoveryNotice()
            XCTAssertEqual(loaded, expected)
            XCTAssertNotNil(notice)
            XCTAssertEqual(try AtomicFile.read(url), bytes)
        }
        let store = try await SettingsStore.open(at: url)
        try await store.save(expected)
        let reopened = try await SettingsStore.open(at: url)
        let loaded = await reopened.load()
        let notice = await reopened.recoveryNotice()
        XCTAssertEqual(loaded, expected)
        XCTAssertNil(notice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["settings.json"])
    }

    func testBothOffRejectedAndFailedAtomicWritePreservesCommittedSettings() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = try await SettingsStore.open(at: url)
        var committed = await store.load()
        committed.showsInDock = false
        try await store.save(committed)
        let before = try AtomicFile.read(url)
        var invalid = committed
        invalid.showsInMenuBar = false
        do { try await store.save(invalid); XCTFail("Both entries off must fail") } catch {}
        let afterInvalid = await store.load()
        XCTAssertEqual(afterInvalid, committed)
        XCTAssertEqual(try AtomicFile.read(url), before)
        let reopened = try await SettingsStore.open(at: url)
        let reopenedSettings = await reopened.load()
        XCTAssertEqual(reopenedSettings, committed)
        // A directory at the target makes atomic rename fail deterministically, even when running as root.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var next = committed
        next.showsInDock = true; next.showsInMenuBar = false
        do { try await store.save(next); XCTFail("Replacing a directory with settings must fail") } catch {}
        let afterWriteFailure = await store.load()
        XCTAssertEqual(afterWriteFailure, committed)
    }
}

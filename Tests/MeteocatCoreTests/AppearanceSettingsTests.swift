import Foundation
import XCTest
@testable import MeteocatCore

final class AppearanceSettingsTests: XCTestCase {
    func testMissingAppearanceDefaultsToAutomaticWithoutRewritingOrLosingSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var original = try MeteocatResources.defaultSettings()
        original.cities = Array(original.cities.prefix(2))
        original.cities[0].name = "Ciutat pròpia"; original.cities[0].visible = false
        original.labelsVisible = false; original.pin = original.cities[0].point
        original.showsInDock = false; original.shortcut = Shortcut(keyCode: 16, carbonModifiers: 0x1800)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeJSON.encode(original)) as? [String: Any])
        json.removeValue(forKey: "appearance")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        try AtomicFile.write(legacy, to: url)
        let store = try await SettingsStore.open(at: url)
        let loaded = await store.load(), notice = await store.recoveryNotice()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.appearance, .automatic)
        XCTAssertNil(notice)
        XCTAssertEqual(try AtomicFile.read(url), legacy)
        for appearance in AppAppearance.allCases {
            var expected = original; expected.appearance = appearance
            try await store.save(expected)
            let reopened = try await SettingsStore.open(at: url)
            let persisted = await reopened.load()
            XCTAssertEqual(persisted, expected)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(url)) as? [String: Any])
            XCTAssertEqual(encoded["appearance"] as? String, appearance.rawValue)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["settings.json"])
    }
    func testUnknownAppearanceFallsBackWithoutLosingOtherSettings() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeJSON.encode(MeteocatResources.defaultSettings())) as? [String: Any])
        json["appearance"] = "sepia"
        let decoded = try NativeJSON.decode(UserSettings.self, JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, try MeteocatResources.defaultSettings())
        XCTAssertEqual(decoded.appearance, .automatic)
    }
}

import XCTest
import AppKit
@testable import MeteocatApp

final class WindowPlacementTests: XCTestCase {
    private let key = "radarWindowPlacement.v1"

    private func syntheticDefaults() throws -> UserDefaults {
        let suite = "MeteocatPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testLegacyFallbackCopiesOnceAndSavesOnlyToNewDomain() throws {
        let defaults = try syntheticDefaults()
        let legacy = try syntheticDefaults()
        var placement = WindowPlacement()
        placement.width = 900
        placement.screen = "legacy-display"
        placement.positions["legacy-display"] = .init(x: 37, y: 82)
        let legacyData = try JSONEncoder().encode(placement)
        legacy.set(legacyData, forKey: key)
        let store = WindowPlacementStore(defaults: defaults, legacyDefaults: legacy)

        XCTAssertEqual(store.load(), placement)
        XCTAssertEqual(try JSONDecoder().decode(WindowPlacement.self, from: XCTUnwrap(defaults.data(forKey: key))), placement)
        var updated = placement
        updated.width = 950
        store.save(updated)
        XCTAssertEqual(store.load(), updated)
        XCTAssertEqual(legacy.data(forKey: key), legacyData)

        legacy.set(try JSONEncoder().encode(WindowPlacement()), forKey: key)
        XCTAssertEqual(store.load(), updated)
    }

    func testNewPlacementWinsOverLegacy() throws {
        let defaults = try syntheticDefaults()
        let legacy = try syntheticDefaults()
        var placement = WindowPlacement()
        placement.width = 850
        let newData = try JSONEncoder().encode(placement)
        defaults.set(newData, forKey: key)
        legacy.set(try JSONEncoder().encode(WindowPlacement()), forKey: key)

        XCTAssertEqual(WindowPlacementStore(defaults: defaults, legacyDefaults: legacy).load(), placement)
        XCTAssertEqual(defaults.data(forKey: key), newData)
    }

    func testMalformedNewPlacementDoesNotResurrectLegacy() throws {
        let defaults = try syntheticDefaults()
        let legacy = try syntheticDefaults()
        var placement = WindowPlacement()
        placement.width = 850
        legacy.set(try JSONEncoder().encode(placement), forKey: key)
        for invalid in [Data("broken".utf8), Data(repeating: 32, count: 32_769), Data("{\"width\":1}".utf8)] {
            defaults.set(invalid, forKey: key)
            XCTAssertEqual(WindowPlacementStore(defaults: defaults, legacyDefaults: legacy).load(), WindowPlacement())
            XCTAssertEqual(defaults.data(forKey: key), invalid)
        }
        defaults.set("wrong-type", forKey: key)
        XCTAssertEqual(WindowPlacementStore(defaults: defaults, legacyDefaults: legacy).load(), WindowPlacement())
        XCTAssertEqual(defaults.string(forKey: key), "wrong-type")
    }

    func testInvalidLegacyPlacementIsNotCopied() throws {
        let defaults = try syntheticDefaults()
        let legacy = try syntheticDefaults()
        for invalid in [Data("broken".utf8), Data(repeating: 32, count: 32_769), Data("{\"width\":1}".utf8), Data("{\"positions\":{\"screen\":{\"x\":100001,\"y\":0}}}".utf8)] {
            legacy.set(invalid, forKey: key)
            XCTAssertEqual(WindowPlacementStore(defaults: defaults, legacyDefaults: legacy).load(), WindowPlacement())
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(legacy.data(forKey: key), invalid)
        }
    }

    func testLegacyFallbackMigratesMinimumAndWidthOnlyFormat() throws {
        let defaults = try syntheticDefaults()
        let legacy = try syntheticDefaults()
        let legacyData = Data("{\"width\":600,\"screen\":\"saved-display\",\"positions\":{\"saved-display\":{\"x\":37,\"y\":82}}}".utf8)
        legacy.set(legacyData, forKey: key)

        let restored = WindowPlacementStore(defaults: defaults, legacyDefaults: legacy).load()
        XCTAssertEqual(restored.width, 600)
        XCTAssertEqual(restored.height, 400)
        XCTAssertEqual(restored.screen, "saved-display")
        XCTAssertEqual(restored.positions["saved-display"], .init(x: 37, y: 82))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(legacy.data(forKey: key), legacyData)
        XCTAssertEqual(try JSONDecoder().decode(WindowPlacement.self, from: XCTUnwrap(defaults.data(forKey: key))), restored)
    }

    func testNoLegacyDomainIsReadUnlessInjected() throws {
        let defaults = try syntheticDefaults()
        XCTAssertEqual(WindowPlacementStore(defaults: defaults).load(), WindowPlacement())
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testLegacyMinimumPreservesScreenAndOffsets() throws {
        let suite = "MeteocatPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var placement = WindowPlacement()
        placement.width = 600
        placement.height = 376
        placement.screen = "saved-display"
        placement.positions["saved-display"] = .init(x: 37, y: 82)
        defaults.set(try JSONEncoder().encode(placement), forKey: "radarWindowPlacement.v1")

        let restored = WindowPlacementStore(defaults: defaults).load()
        XCTAssertEqual(restored.width, 600)
        XCTAssertEqual(restored.height, 400)
        XCTAssertEqual(restored.screen, placement.screen)
        XCTAssertEqual(restored.positions, placement.positions)
        XCTAssertTrue(restored.isValid)
    }
}

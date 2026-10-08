import AppKit
import XCTest
@testable import MeteocatApp

@MainActor
final class PanelActivationTests: XCTestCase {
    func testInactiveRequestCompletesOnlyAfterActivationOnce() {
        let notifications = NotificationCenter()
        let application = NSObject()
        let activation = RadarActivationCompletion(notifications: notifications)
        var events: [String] = []
        activation.request(application: application, isActive: false,
                           activate: { events.append("activate") }, completion: { events.append("key") })
        XCTAssertEqual(events, ["activate"])
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: application)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: application)
        XCTAssertEqual(events, ["activate", "key"])
    }
    func testAlreadyActiveCompletesAfterActivationRequest() {
        let activation = RadarActivationCompletion(notifications: NotificationCenter())
        var events: [String] = []
        activation.request(application: nil, isActive: true,
                           activate: { events.append("activate") }, completion: { events.append("key") })
        XCTAssertEqual(events, ["activate", "key"])
    }
    func testCancellationAndReplacementPreventOldWindowTakingFocus() {
        let notifications = NotificationCenter()
        let application = NSObject()
        let activation = RadarActivationCompletion(notifications: notifications)
        var completions: [String] = []
        activation.request(application: application, isActive: false, activate: {}, completion: { completions.append("cancelled") })
        activation.cancel()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: application)
        XCTAssertTrue(completions.isEmpty)
        activation.request(application: application, isActive: false, activate: {}, completion: { completions.append("old") })
        activation.request(application: application, isActive: false, activate: {}, completion: { completions.append("latest") })
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: application)
        XCTAssertEqual(completions, ["latest"])
    }
    func testDeinitRetiresObserverAndWrongApplicationDoesNotComplete() {
        let notifications = NotificationCenter()
        let application = NSObject()
        var activation: RadarActivationCompletion? = RadarActivationCompletion(notifications: notifications)
        var completed = false
        activation?.request(application: application, isActive: false, activate: {}, completion: { completed = true })
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: NSObject())
        XCTAssertFalse(completed)
        activation = nil
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: application)
        XCTAssertFalse(completed)
    }
}

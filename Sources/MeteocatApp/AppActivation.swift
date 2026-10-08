import AppKit
import Carbon

/// Workspace supplies the system activation context that a background app cannot supply itself.
/// An open-application event activates the existing instance without issuing a radar reopen.
@MainActor enum AppActivation {
    private static var pending = false

    static func request() {
        guard !NSApp.isActive, !pending else { return }
        let applicationURL = Bundle.main.bundleURL
        guard applicationURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            NSApp.activate()
            return
        }
        pending = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            Task { @MainActor in
                pending = false
                if let error {
                    let failure = error as NSError
                    NSLog("Workspace activation failed (%@:%ld)", failure.domain, failure.code)
                    NSApp.activate()
                }
            }
        }
    }
}

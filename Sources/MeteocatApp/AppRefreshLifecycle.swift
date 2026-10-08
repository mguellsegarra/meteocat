import AppKit

/// Public workspace signals only. Lock-only events, an already inactive launch and
/// dark wake need native validation; this does not prevent sleep or install a daemon.
@MainActor
final class AppRefreshLifecycle {
    enum Reason: Hashable { case sleep, session, screens }
    private var reasons = Set<Reason>()
    private var observers = [NSObjectProtocol]()
    private weak var model: RadarViewModel?
    private var ready = false, stopped = false
    private var revision: UInt64 = 0

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        let signals: [(Notification.Name, Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .sleep, true),
            (NSWorkspace.didWakeNotification, .sleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .session, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
            (NSWorkspace.screensDidSleepNotification, .screens, true),
            (NSWorkspace.screensDidWakeNotification, .screens, false)
        ]
        for (name, reason, suspended) in signals {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Workspace notifications arrive on the main queue; record the desired
                // state before creating the asynchronous actor delivery.
                MainActor.assumeIsolated { self?.set(reason, suspended: suspended) }
            })
        }
    }
    private let center: NotificationCenter
    func attach(_ model: RadarViewModel) {
        guard !stopped else { return }
        self.model = model; ready = true; deliver()
    }
    func set(_ reason: Reason, suspended: Bool) {
        guard !stopped else { return }
        if suspended { reasons.insert(reason) } else { reasons.remove(reason) }
        deliver()
    }
    private func deliver() {
        revision &+= 1
        model?.setSystemSuspended(!reasons.isEmpty)
        guard let model else { return }
        let active = ready && reasons.isEmpty && !stopped, revision = revision
        Task { await model.service.setRefreshActive(active, revision: revision) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; ready = false
        observers.forEach(center.removeObserver); observers = []
        deliver()
    }
}

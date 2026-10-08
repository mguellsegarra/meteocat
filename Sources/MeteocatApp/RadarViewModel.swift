import AppKit
import MeteocatCore

@MainActor @Observable
final class RadarViewModel {
    let playback: PlaybackController
    let geography: Geography?
    let projection: MapProjection
    /// Non-nil only in recorded fixture mode.
    let fixtureCapture: Date?
    private let recoveryNoticeToken: LocalizedMessage?
    var recoveryNotice: String? { recoveryNoticeToken?.rendered }
    private(set) var snapshot: RadarSnapshot?
    private(set) var settings: UserSettings
    /// True between show and hide of the radar panel; Settings alone never sets it.
    private(set) var viewerVisible = false
    private var systemSuspended = false
    private var presentationRevision: UInt64 = 0
    // Visibility changes cannot invalidate a wake; only a newer suspension transition can.
    private var suspensionRevision: UInt64 = 0
    /// Set synchronously by `refresh()` before its task exists, so a second click in the same run-loop turn is refused.
    private(set) var refreshPending = false
    /// AppKit could not apply a persisted presence preference; a status entry remains available.
    var presenceErrorToken: LocalizedMessage?
    var presenceError: String? { presenceErrorToken?.rendered }

    @ObservationIgnored let service: RadarService
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var settingsQueue: Task<Void, Never>?
    @ObservationIgnored private var settingsObservers: [UUID: @MainActor (UserSettings) -> Void] = [:]

    /// Retained AppKit subscribers receive the initial state and every successful commit, on the main actor.
    /// Unlike a view's onChange, this route remains active while Settings is closed.
    func observeSettings(_ observer: @escaping @MainActor (UserSettings) -> Void) -> UUID {
        let token = UUID()
        settingsObservers[token] = observer
        observer(settings)
        return token
    }
    func removeSettingsObserver(_ token: UUID) { settingsObservers.removeValue(forKey: token) }

    init(service: RadarService, store: SettingsStore, settings: UserSettings, recoveryNotice: String?,
         geography: Geography?, projection: MapProjection, fixtureCapture: Date?) {
        self.service = service; self.store = store; self.settings = settings; self.recoveryNoticeToken = recoveryNotice.map(LocalizedMessage.core)
        self.geography = geography; self.projection = projection; self.fixtureCapture = fixtureCapture
        playback = PlaybackController(service: service)
    }

    /// Subscribes to local snapshots. The stream yields the current snapshot immediately and makes no request.
    func start() async {
        let stream = await service.snapshots()
        install(await service.current())
        streamTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { return }
                self.install(snapshot)
            }
        }
    }
    private func install(_ snapshot: RadarSnapshot) {
        guard snapshot.revision >= (self.snapshot?.revision ?? 0) else { return }
        self.snapshot = snapshot
        playback.replaceTimeline(snapshot: snapshot)
    }

    /// Panel visibility controls local presentation; the app lifecycle owns HTTP.
    func setViewerVisible(_ visible: Bool) {
        viewerVisible = visible
        presentationRevision &+= 1
        let expected = presentationRevision
        // Record show intent synchronously, including a show while suspended.
        playback.setVisible(visible)
        Task { [service] in
            await service.setViewerVisible(visible)
            let snapshot = await service.current()
            guard expected == self.presentationRevision else { return }
            self.install(snapshot)
        }
    }
    func setSystemSuspended(_ suspended: Bool) {
        guard systemSuspended != suspended else { return }
        systemSuspended = suspended
        suspensionRevision &+= 1
        let expected = suspensionRevision
        if suspended { playback.setSuspended(true); return }
        Task {
            let snapshot = await service.current()
            guard expected == suspensionRevision, !systemSuspended else { return }
            install(snapshot)
            playback.setSuspended(false)
        }
    }

    // MARK: - Refresh through the service gate

    /// Shared by the button and ⌘R; presentation feedback also covers a gated local refresh.
    var isRefreshing: Bool {
        if refreshPending { return true }
        if case .refreshing = snapshot?.sourceState { return true }
        return false
    }

    /// The service retains sole admission authority. A quick cache-only result still gets visible feedback.
    func refresh() {
        guard viewerVisible, !refreshPending else { return }
        refreshPending = true
        Task { [service] in
            let feedbackDeadline = ContinuousClock.now + .milliseconds(1500)
            defer { self.refreshPending = false }
            // A queued click must not resume suspended HTTP or wake a hidden viewer.
            if self.viewerVisible, !self.systemSuspended {
                await service.refreshIfEligible()
                self.install(await service.current())
            }
            try? await ContinuousClock().sleep(until: feedbackDeadline)
        }
    }

    /// Flips the latest serialized value, not a copy captured before queueing.
    func toggleLabels() {
        Task { _ = await updateSettings { $0.labelsVisible.toggle() } }
    }

    func shutdown() async {
        streamTask?.cancel()
        await service.shutdown()
    }

    /// Runs whole settings transactions (read latest, change, save, publish, and any shortcut registration with its
    /// rollback) strictly one after another, so a transaction never starts from a copy taken before an earlier save.
    func serialized<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = settingsQueue
        let task = Task { () -> T in
            await previous?.value
            return await work()
        }
        settingsQueue = Task { _ = await task.value }
        return await task.value
    }

    /// Validates and persists through the core store; returns a user-facing error or nil.
    func updateSettings(_ change: @escaping (inout UserSettings) -> Void) async -> LocalizedMessage? {
        await serialized { await self.commit(change) }
    }

    /// One read/change/save/publish step. Call only from inside `serialized` (or `updateSettings`).
    func commit(_ change: (inout UserSettings) -> Void) async -> LocalizedMessage? {
        var next = await store.load()
        change(&next)
        do {
            try await store.save(next)
            settings = next
            // Snapshot callbacks so removing a subscription inside a callback is safe.
            for observer in Array(settingsObservers.values) { observer(next) }
            return nil
        } catch { return .core(error.localizedDescription) }
    }

    /// Compact corner text plus the detail for its tooltip and VoiceOver.
    struct Status: Equatable {
        var text: String
        var compactText: String
        /// Short visible problem word, nil when everything is fine.
        var alert: String?
        var detail: String
    }

    var status: Status {
        var text: String, detail: [String] = []
        if let fixtureCapture {
            text = L10n.text("Dades de prova · %1$@", String(describing: Fmt.time(fixtureCapture)))
            detail.append(L10n.text("Dades de prova del %1$@. En aquest mode no es consulten dades noves.", String(describing: Fmt.full(fixtureCapture))))
        } else if let checked = snapshot?.checkedAt {
            text = L10n.text("Última consulta: %1$@", String(describing: Fmt.time(checked)))
            detail.append(L10n.text("Última consulta correcta a Meteocat: %1$@. No és l'hora del fotograma mostrat i no garanteix que s'hagin baixat totes les imatges.", String(describing: Fmt.full(checked))))
        } else {
            text = L10n.text("Encara sense consulta")
            detail.append(L10n.text("Encara no s'ha pogut consultar Meteocat."))
        }
        var alert: String?
        if let error = playback.frameError { alert = L10n.text("Error"); detail.append(error) }
        if let line = sourceLine {
            alert = alert ?? (snapshot?.observations.isEmpty ?? true ? L10n.text("Sense dades") : sourceAlert)
            detail.append(line)
        }
        if case .refreshing = snapshot?.sourceState { detail.append(L10n.text("Consultant Meteocat…")) }
        let compactText = fixtureCapture.map { L10n.text("Prova · %1$@", Fmt.time($0)) } ?? text
        return Status(text: text, compactText: compactText, alert: alert, detail: detail.joined(separator: "\n"))
    }

    private var sourceAlert: String {
        if case .unavailable = snapshot?.sourceState { return L10n.text("Error") }
        if fixtureCapture == nil, snapshot?.observationsAreStale(at: Date()) == true { return L10n.text("Dades sense actualitzar") }
        return L10n.text("Avís")
    }

    private var sourceLine: String? {
        guard let snapshot else { return nil }
        guard let latest = snapshot.observations.last?.id.validUTC else {
            switch snapshot.sourceState {
            case .unavailable(let message): return L10n.coreMessage(message)
            case .refreshing: return L10n.text("Carregant el radar…")
            default: return L10n.text("Encara no hi ha dades de radar.")
            }
        }
        if fixtureCapture == nil {
            if case .unavailable = snapshot.sourceState { return L10n.text("Dades de les %1$@ · sense connexió", String(describing: Fmt.time(latest))) }
            if snapshot.observationsAreStale(at: Date()) { return L10n.text("Dades de les %1$@ · no actualitzades", String(describing: Fmt.time(latest))) }
        }
        return (snapshot.forecastError ?? snapshot.observationError).map(L10n.coreMessage)
    }
}

/// App-language dates and fixed Europe/Madrid radar times, retaining repeated-hour DST labels.
@MainActor enum Fmt {
    static let zone = TimeZone(identifier: "Europe/Madrid")!
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
    private static let hm = formatter("HH:mm")
    private static var localizedFormatters: (language: String, day: DateFormatter, full: DateFormatter)?
    private static var dateFormatters: (language: String, day: DateFormatter, full: DateFormatter) {
        let localization = L10n.current
        if let cached = localizedFormatters, cached.language == localization.language { return cached }
        let next = (language: localization.language,
                    day: localization.dateFormatter(template: "EEEEdMMMM"),
                    full: localization.dateFormatter(template: "EEEEdMMMMyyyyHHmm"))
        localizedFormatters = next
        return next
    }

    /// HH:mm local; adds the zone only for the repeated hour when DST ends.
    static func time(_ date: Date) -> String {
        let text = hm.string(from: date)
        let ambiguous = [3600.0, -3600.0].contains { hm.string(from: date.addingTimeInterval($0)) == text }
        return ambiguous ? "\(text) \(zone.abbreviation(for: date) ?? "")" : text
    }
    /// `time` split into the HH:mm digits and the DST zone suffix (empty outside the repeated hour).
    static func timeParts(_ date: Date) -> (digits: String, zone: String) {
        let text = time(date)
        return (String(text.prefix(5)), text.count > 5 ? String(text.dropFirst(6)) : "")
    }
    static func day(_ date: Date) -> String { dateFormatters.day.string(from: date) }
    /// Tooltip: kind, full valid date and time, and for a forecast its lead and dated origin.
    static func detail(_ id: FrameID) -> String {
        guard id.kind == .forecast, let origin = id.originUTC else { return L10n.text("Observació · %1$@ · %2$@", String(describing: day(id.validUTC)), String(describing: time(id.validUTC))) }
        return L10n.text("Previsió per a %1$@ a les %2$@ · +%3$@ min · origen %4$@ a les %5$@", String(describing: day(id.validUTC)), String(describing: time(id.validUTC)), String(describing: leadMinutes(id)), String(describing: day(origin)), String(describing: time(origin)))
    }
    static func full(_ date: Date) -> String { dateFormatters.full.string(from: date) }
    /// True when origin and valid time fall on different Europe/Madrid days, so the valid time needs its own date.
    static func crossesDay(_ id: FrameID) -> Bool {
        guard let origin = id.originUTC else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return !calendar.isDate(origin, inSameDayAs: id.validUTC)
    }
    static func leadMinutes(_ id: FrameID) -> Int { Int((id.validUTC.timeIntervalSince(id.originUTC ?? id.validUTC) / 60).rounded()) }

    /// Spoken value: valid time, plus forecast lead and origin.
    static func spoken(_ id: FrameID) -> String {
        guard id.kind == .forecast, let origin = id.originUTC else { return L10n.text("%1$@, observació, %2$@", String(describing: time(id.validUTC)), String(describing: day(id.validUTC))) }
        if crossesDay(id) {
            return L10n.text("%1$@, %2$@, previsió +%3$@ min, origen %4$@", time(id.validUTC), day(id.validUTC), String(leadMinutes(id)), time(origin))
        }
        return L10n.text("%1$@, previsió +%2$@ min, origen %3$@", time(id.validUTC), String(leadMinutes(id)), time(origin))
    }
}

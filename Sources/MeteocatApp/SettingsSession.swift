import Foundation
import Observation
import MeteocatCore

/// One in-memory autosave owner per retained Settings window. Persistence is injected only for offline tests;
/// production always uses RadarViewModel's serialized, read-latest field transaction.
@MainActor @Observable
final class SettingsSession {
    enum Section: Int, CaseIterable { case general, map, location
        var title: String { switch self { case .general: L10n.text("General"); case .map: L10n.text("Mapa"); case .location: L10n.text("Ubicació") } }
        var symbol: String { switch self { case .general: "gearshape"; case .map: "map"; case .location: "location" } }
    }
    struct CityEditor: Identifiable {
        let id = UUID()
        let existingID: String?
        var draft: CityDraft
    }
    typealias Update = @MainActor (@escaping (inout UserSettings) -> Void) async -> LocalizedMessage?

    private(set) var section: Section = .general
    private(set) var cities: [CityDraft] { didSet { pruneSelection() } }
    var search = "" { didSet { pruneSelection() } }
    private var selectedIDs = Set<String>()
    /// Table selection and its actions are restricted to rows visible under the current search.
    var selection: Set<String> {
        get { selectedIDs }
        set { selectedIDs = newValue.intersection(Set(filteredCities.map(\.id))) }
    }
    var editor: CityEditor?
    var pinLon = "" { didSet { coordinatesChanged() } }
    var pinLat = "" { didSet { coordinatesChanged() } }
    private(set) var pinExact: GeoPoint?
    private(set) var savedPin: GeoPoint?
    private(set) var showsInDock: Bool
    private(set) var showsInMenuBar: Bool
    private(set) var presencePending = false
    private var presenceMessageToken: LocalizedMessage?
    var presenceMessage: String? { presenceMessageToken?.rendered }
    private(set) var appearance: AppAppearance
    private(set) var appearancePending = false
    private var appearanceMessageToken: LocalizedMessage?
    var appearanceMessage: String? { appearanceMessageToken?.rendered }
    private(set) var labelsVisible: Bool
    private(set) var citiesPending = false
    private(set) var pinPending = false
    private(set) var labelsPending = false
    private var citiesMessageToken: LocalizedMessage?
    var citiesMessage: String? { citiesMessageToken?.rendered }
    private var pinMessageToken: LocalizedMessage?
    var pinMessage: String? { pinMessageToken?.rendered }
    private var labelsMessageToken: LocalizedMessage?
    var labelsMessage: String? { labelsMessageToken?.rendered }
    private(set) var pinSavedFeedback = false
    let locator: LocationLocator
    let projection: MapProjection
    @ObservationIgnored private var cityBaseline: [CityDraft]
    @ObservationIgnored private let update: Update
    @ObservationIgnored private var locationGeneration = 0
    @ObservationIgnored private var pinRevision = 0
    @ObservationIgnored private var installingPin = false
    @ObservationIgnored private var pinDebounce: Task<Void, Never>?
    @ObservationIgnored private var pinTask: Task<Void, Never>?
    @ObservationIgnored private var flushAfterPinWrite = false
    @ObservationIgnored private var cityRetry: ((inout UserSettings) -> LocalizedMessage?)?
    @ObservationIgnored private var retryPinRemoval = false
    @ObservationIgnored private var cityTask: Task<Void, Never>?

    init(settings: UserSettings, projection: MapProjection, locator: LocationLocator? = nil,
         update: @escaping Update) {
        let initialCities = settings.cities.map(CityDraft.init)
        cities = initialCities; cityBaseline = initialCities
        savedPin = settings.pin; pinExact = settings.pin
        pinLon = settings.pin.map { CoordinateText.format($0.lon) } ?? ""
        pinLat = settings.pin.map { CoordinateText.format($0.lat) } ?? ""
        showsInDock = settings.showsInDock; showsInMenuBar = settings.showsInMenuBar
        appearance = settings.appearance
        labelsVisible = settings.labelsVisible
        self.projection = projection; self.locator = locator ?? LocationLocator(); self.update = update
    }
    convenience init(model: RadarViewModel, locator: LocationLocator? = nil) {
        self.init(settings: model.settings, projection: model.projection, locator: locator) { change in
            await model.updateSettings(change)
        }
    }
    var filteredCities: [CityDraft] { cities.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }
    private func pruneSelection() {
        selectedIDs.formIntersection(Set(filteredCities.map(\.id)))
    }
    var canRetryCities: Bool { citiesMessage != nil && cityRetry != nil }
    var citiesLocked: Bool { citiesPending || canRetryCities }
    var canRetryPin: Bool { pinMessage != nil && (retryPinRemoval || (try? pinResult.get()) != nil) }
    var citiesDirty: Bool { cities != cityBaseline }
    var pinResult: Result<GeoPoint, CoordinateValidationError> {
        CoordinateText.parse(lon: pinLon, lat: pinLat, original: pinExact, projection: projection)
    }
    var pinDirty: Bool {
        if pinLon.isEmpty && pinLat.isEmpty { return savedPin != nil }
        switch pinResult { case .success(let point): return point != savedPin
        case .failure: return true }
    }
    var pinLocked: Bool { pinPending || locator.isPending }
    var cityValidation: (cities: [City]?, errors: [String: LocalizedMessage]) { CoordinateText.cities(cities, projection: projection) }

    /// Reconcile clean domains only. No appearance or unrelated publication may discard another draft.
    func reconcile(_ settings: UserSettings) {
        if !citiesPending {
            let committed = settings.cities.map(CityDraft.init)
            if !citiesDirty && editor == nil {
                cities = committed
            }
            cityBaseline = committed
        }
        if !pinDirty && !pinLocked { installPin(settings.pin) }
        savedPin = settings.pin
        if !appearancePending { appearance = settings.appearance }
        if !labelsPending { labelsVisible = settings.labelsVisible }
        if !presencePending {
            showsInDock = settings.showsInDock; showsInMenuBar = settings.showsInMenuBar
        }
    }
    func select(_ next: Section, cancelRecording: () -> Void) {
        guard section != next else { return }
        if section == .general { cancelRecording() }
        if section == .location { cancelLocation(); flushPin() }
        section = next
    }
    func close(cancelRecording: () -> Void) {
        cancelLocation(); flushPin(); cancelRecording()
    }
    private func cancelLocation() { locationGeneration += 1; locator.cancel() }

    @discardableResult func setVisible(_ visible: Bool, id: String) -> Task<Void, Never>? {
        guard !citiesLocked, let index = cities.firstIndex(where: { $0.id == id }),
              cities[index].visible != visible else { return nil }
        cities[index].visible = visible
        return persistCities { settings in
            guard let index = settings.cities.firstIndex(where: { $0.id == id }) else { return .text("La ciutat ja no existeix.") }
            settings.cities[index].visible = visible
            return nil
        }
    }
    @discardableResult func deleteSelection() -> Task<Void, Never>? {
        guard !citiesLocked else { return nil }
        let ids = selection.intersection(Set(filteredCities.map(\.id)))
        guard !ids.isEmpty else { return nil }
        cities.removeAll { ids.contains($0.id) }; selection.removeAll()
        return persistCities { settings in settings.cities.removeAll { ids.contains($0.id) }; return nil }
    }
    func beginAdd() {
        guard !citiesLocked, cities.count < 60 else { return }
        let centre = (try? projection.unproject(CGPoint(x: 340, y: 190))) ?? GeoPoint(lon: 1.5, lat: 41.7)
        editor = CityEditor(existingID: nil, draft: CityDraft(newAt: centre))
    }
    /// Explicit stable-ID editing remains valid even when a caller is editing a filtered-out row.
    func beginEdit(_ id: String) {
        guard !citiesLocked, let draft = cities.first(where: { $0.id == id }) else { return }
        editor = CityEditor(existingID: id, draft: draft)
    }
    /// A sheet edits a value copy; stale IDs and hidden rows are checked against the canonical array.
    @discardableResult func accept(_ copy: CityEditor) -> LocalizedMessage? {
        guard !citiesLocked else { return .text("Cal esperar que es desin les ciutats o tornar-ho a provar.") }
        let checked = CoordinateText.cities([copy.draft], projection: projection)
        guard let city = checked.cities?.first else { return checked.errors[copy.draft.id] ?? checked.errors["_"] }
        if let id = copy.existingID {
            guard city.id == id, let index = cities.firstIndex(where: { $0.id == id }) else { return .text("La ciutat ja no existeix.") }
            cities[index] = CityDraft(city)
        } else {
            guard cities.count < 60 else { return .text("Com a màxim hi pot haver 60 ciutats.") }
            guard !cities.contains(where: { $0.id == city.id }) else { return .text("Hi ha identificadors repetits.") }
            cities.append(CityDraft(city)); search = ""
        }
        selection = [city.id]; editor = nil
        persistCities { settings in
            if let id = copy.existingID {
                guard let index = settings.cities.firstIndex(where: { $0.id == id }) else { return .text("La ciutat ja no existeix.") }
                settings.cities[index] = city
            } else {
                guard settings.cities.count < 60 else { return .text("Com a màxim hi pot haver 60 ciutats.") }
                guard !settings.cities.contains(where: { $0.id == city.id }) else { return .text("Hi ha identificadors repetits.") }
                settings.cities.append(city)
            }
            return nil
        }
        return nil
    }
    /// Retry the failed ID-scoped operation; never replace a stale whole-city snapshot.
    @discardableResult func saveCities() -> Task<Void, Never>? {
        if citiesPending { return cityTask }
        guard let cityRetry else { return nil }
        return persistCities(cityRetry)
    }
    @discardableResult private func persistCities(_ mutation: @escaping (inout UserSettings) -> LocalizedMessage?) -> Task<Void, Never>? {
        guard !citiesPending else { return nil }
        citiesPending = true; citiesMessageToken = nil; cityRetry = mutation
        let task = Task {
            var committed: [City]?
            var conflict: LocalizedMessage?
            let error = await update { settings in
                conflict = mutation(&settings)
                committed = settings.cities
            }
            citiesMessageToken = error ?? conflict
            if error == nil, let committed {
                cityBaseline = committed.map(CityDraft.init)
                cities = cityBaseline
                cityRetry = nil
            }
            citiesPending = false; cityTask = nil
        }
        cityTask = task
        return task
    }
    @discardableResult func setLabels(_ value: Bool) -> Task<Void, Never>? {
        guard !labelsPending else { return nil }
        let previous = labelsVisible
        labelsVisible = value; labelsPending = true; labelsMessageToken = nil
        return Task {
            let error = await update { $0.labelsVisible = value }
            labelsMessageToken = error
            if error != nil { labelsVisible = previous }
            labelsPending = false
        }
    }
    @discardableResult func setAppearance(_ value: AppAppearance) -> Task<Void, Never>? {
        guard !appearancePending, value != appearance else { return nil }
        // Show only the committed choice; errors leave the current appearance intact.
        appearancePending = true; appearanceMessageToken = nil
        return Task {
            let error = await update { $0.appearance = value }
            appearanceMessageToken = error
            if error == nil { appearance = value }
            appearancePending = false
        }
    }
    var dockOptionDisabled: Bool { presencePending || (showsInDock && !showsInMenuBar) }
    var menuBarOptionDisabled: Bool { presencePending || (showsInMenuBar && !showsInDock) }

    @discardableResult func setShowsInDock(_ value: Bool) -> Task<Void, Never>? {
        setPresence(dock: value, menuBar: nil)
    }
    @discardableResult func setShowsInMenuBar(_ value: Bool) -> Task<Void, Never>? {
        setPresence(dock: nil, menuBar: value)
    }
    private func setPresence(dock: Bool?, menuBar: Bool?) -> Task<Void, Never>? {
        guard !presencePending else { return nil }
        let nextDock = dock ?? showsInDock, nextMenuBar = menuBar ?? showsInMenuBar
        guard nextDock || nextMenuBar else { return nil }
        guard nextDock != showsInDock || nextMenuBar != showsInMenuBar else { return nil }
        // Keep committed entries visible until the write succeeds. Lock both controls synchronously.
        presencePending = true; presenceMessageToken = nil
        return Task {
            let error = await update {
                if let dock { $0.showsInDock = dock }
                if let menuBar { $0.showsInMenuBar = menuBar }
            }
            presenceMessageToken = error
            if error == nil { showsInDock = nextDock; showsInMenuBar = nextMenuBar }
            presencePending = false
        }
    }
    func acquireLocation() {
        guard section == .location, !pinLocked else { return }
        // Persist a valid manual pair before the one-shot request locks coordinate saves.
        flushPin()
        cancelLocation()
        locationGeneration += 1
        let generation = locationGeneration
        pinMessageToken = nil; pinSavedFeedback = false
        locator.request { [weak self] point in
            guard let self, self.section == .location, self.locationGeneration == generation else { return }
            self.installPin(point)
            self.pinRevision += 1
            if case .failure(let error) = self.pinResult { self.pinMessageToken = error.message }
            else { self.flushPin() }
        }
    }
    private func installPin(_ point: GeoPoint?) {
        installingPin = true
        pinExact = point
        pinLon = point.map { CoordinateText.format($0.lon) } ?? ""
        pinLat = point.map { CoordinateText.format($0.lat) } ?? ""
        installingPin = false
    }
    private func coordinatesChanged() {
        guard !installingPin else { return }
        pinRevision += 1; pinSavedFeedback = false; pinMessageToken = nil; retryPinRemoval = false
        pinDebounce?.cancel()
        guard case .success = pinResult, pinDirty else { pinDebounce = nil; return }
        pinDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            self.pinDebounce = nil
            self.flushPin()
        }
    }
    /// Cancel only the delay; an already-started transaction always finishes after close.
    @discardableResult func flushPin() -> Task<Void, Never>? {
        pinDebounce?.cancel(); pinDebounce = nil
        if pinPending { flushAfterPinWrite = true; return pinTask }
        return savePin()
    }
    @discardableResult func savePin() -> Task<Void, Never>? {
        guard !pinPending, !locator.isPending, pinDirty else { return nil }
        guard case .success(let captured) = pinResult else { return nil }
        pinDebounce?.cancel(); pinDebounce = nil
        return persistPin(captured)
    }
    @discardableResult func retryPin() -> Task<Void, Never>? {
        retryPinRemoval ? removePin() : flushPin()
    }
    private func persistPin(_ captured: GeoPoint?) -> Task<Void, Never> {
        let revision = pinRevision
        pinPending = true; pinMessageToken = nil; pinSavedFeedback = false
        let task = Task {
            let error = await update { $0.pin = captured }
            if error == nil {
                savedPin = captured
                if pinRevision == revision { installPin(captured); pinSavedFeedback = true; retryPinRemoval = false }
            }
            if pinRevision == revision { pinMessageToken = error }
            pinPending = false; pinTask = nil
            let shouldFlush = flushAfterPinWrite
            flushAfterPinWrite = false
            if pinRevision != revision, shouldFlush || pinDebounce == nil { flushPin() }
        }
        pinTask = task
        return task
    }
    @discardableResult func removePin() -> Task<Void, Never>? {
        guard !pinLocked, savedPin != nil || !pinLon.isEmpty || !pinLat.isEmpty else { return nil }
        pinDebounce?.cancel(); pinDebounce = nil; pinRevision += 1; retryPinRemoval = true
        return persistPin(nil)
    }
}

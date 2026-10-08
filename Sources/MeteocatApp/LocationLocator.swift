import CoreLocation
import Foundation
import MeteocatCore

/// The slice of CLLocationManager the locator needs, so lifecycle checks can inject a fake.
@MainActor
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var servicesEnabled: Bool { get }
    func requestAuthorization()
    func requestLocation()
    func cancelRequest()
}

extension CLLocationManager: LocationManaging {
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    func requestAuthorization() { requestWhenInUseAuthorization() }
    func cancelRequest() { stopUpdatingLocation() }  // also cancels a pending requestLocation()
}

/// One-shot location lookup, started only by `request`. The manager is created on the first click, never earlier.
/// Each request has a generation; late delegate callbacks, timeouts and cancelled requests are ignored.
@MainActor @Observable
final class LocationLocator {
    enum State: Equatable { case idle, pending, failed(LocalizedMessage) }
    private(set) var state = State.idle

    static let authorizationWait: Duration = .seconds(60)
    static let fixWait: Duration = .seconds(20)
    static let maxAge: TimeInterval = 60
    static let maxAccuracy: CLLocationAccuracy = 5_000

    @ObservationIgnored private let makeManager: @MainActor () -> LocationManaging
    @ObservationIgnored private var manager: LocationManaging?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var awaitingAuthorization = false
    @ObservationIgnored private var onFix: ((GeoPoint) -> Void)?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init(makeManager: @escaping @MainActor () -> LocationManaging = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return manager
    }) {
        self.makeManager = makeManager
    }

    var isPending: Bool { state == .pending }

    /// Starts a single lookup; ignored while one is running. `onFix` runs once, on success only.
    func request(onFix: @escaping (GeoPoint) -> Void) {
        guard !isPending else { return }
        generation += 1
        self.onFix = onFix
        retireManager()
        let manager = makeManager()
        let bridge = Bridge(self, generation: generation)
        manager.delegate = bridge
        self.bridge = bridge
        self.manager = manager
        guard manager.servicesEnabled else { return fail(LocalizedMessage.text("Els serveis d'ubicació estan desactivats al Mac. Activa'ls a Configuració del Sistema > Privadesa i seguretat.")) }
        state = .pending
        switch manager.authorizationStatus {
        case .notDetermined:
            awaitingAuthorization = true
            arm(Self.authorizationWait)
            manager.requestAuthorization()
        case .authorizedAlways: startFix(manager)
        case .denied: fail(Self.deniedMessage)
        case .restricted: fail(LocalizedMessage.text("L'ús de la ubicació està restringit en aquest Mac."))
        @unknown default: fail(LocalizedMessage.text("No es pot accedir a la ubicació."))
        }
    }

    /// Abandons any running request (settings dismissed). Nothing is delivered afterwards.
    func cancel() {
        guard manager != nil else { return }
        generation += 1
        awaitingAuthorization = false
        onFix = nil
        timeout?.cancel(); timeout = nil
        retireManager()
        state = .idle
    }

    private static let deniedMessage = LocalizedMessage.text("Meteocat no té permís per usar la ubicació. Activa'l a Configuració del Sistema > Privadesa i seguretat > Localització.")

    private func startFix(_ manager: LocationManaging) {
        awaitingAuthorization = false
        arm(Self.fixWait)
        manager.requestLocation()
    }

    private func arm(_ duration: Duration) {
        timeout?.cancel()
        let current = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.expire(current)
        }
    }

    private func expire(_ current: Int) {
        guard current == generation, isPending else { return }
        manager?.cancelRequest()
        fail(LocalizedMessage.text("No s'ha pogut obtenir la ubicació a temps. Torna-ho a provar."))
    }

    private func retireManager() {
        manager?.delegate = nil
        manager?.cancelRequest()
        manager = nil
        bridge = nil
    }

    private func fail(_ message: LocalizedMessage) {
        retireManager()
        awaitingAuthorization = false
        onFix = nil
        timeout?.cancel(); timeout = nil
        state = .failed(message)
    }

    // MARK: delegate callbacks (already hopped to the main actor, and ignored when not pending)

    func authorizationChanged(generation current: Int) {
        guard current == generation, isPending, awaitingAuthorization, let manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .authorizedAlways: startFix(manager)
        case .denied: fail(Self.deniedMessage)
        case .restricted: fail(LocalizedMessage.text("L'ús de la ubicació està restringit en aquest Mac."))
        @unknown default: fail(LocalizedMessage.text("No es pot accedir a la ubicació."))
        }
    }

    func received(_ locations: [CLLocation], generation current: Int, now: Date = Date()) {
        guard current == generation, isPending, !awaitingAuthorization else { return }
        guard let location = locations.last else { return fail(LocalizedMessage.text("No s'ha rebut cap ubicació. Torna-ho a provar.")) }
        let c = location.coordinate
        guard CLLocationCoordinate2DIsValid(c), c.latitude.isFinite, c.longitude.isFinite else {
            return fail(LocalizedMessage.text("La ubicació rebuda no és vàlida."))
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maxAccuracy else {
            return fail(LocalizedMessage.text("La ubicació no és prou precisa. Torna-ho a provar."))
        }
        guard abs(location.timestamp.timeIntervalSince(now)) <= Self.maxAge else {
            return fail(LocalizedMessage.text("La ubicació és massa antiga. Torna-ho a provar."))
        }
        let deliver = onFix
        timeout?.cancel(); timeout = nil
        onFix = nil
        retireManager()
        state = .idle
        deliver?(GeoPoint(lon: c.longitude, lat: c.latitude))
    }

    func failed(_ error: Error, generation current: Int) {
        guard current == generation, isPending else { return }
        switch (error as? CLError)?.code {
        case .denied: fail(Self.deniedMessage)
        case .locationUnknown, .network: fail(LocalizedMessage.text("No s'ha pogut determinar la ubicació. Torna-ho a provar."))
        default: fail(LocalizedMessage.text("No s'ha pogut obtenir la ubicació."))
        }
    }

    /// Delegate objects must be NSObjects; this one only forwards to the main actor and owns nothing.
    final class Bridge: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        private weak var owner: LocationLocator?
        private let generation: Int
        init(_ owner: LocationLocator, generation: Int) { self.owner = owner; self.generation = generation }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            Task { @MainActor in owner?.authorizationChanged(generation: generation) }
        }
        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            Task { @MainActor in owner?.received(locations, generation: generation) }
        }
        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            Task { @MainActor in owner?.failed(error, generation: generation) }
        }
    }
}

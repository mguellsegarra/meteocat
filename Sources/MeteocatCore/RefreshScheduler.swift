import Foundation

/// Internal clock seam: wall time remains the persisted contract; elapsed time prevents
/// a forward wall-clock adjustment from admitting another cycle in this process.
struct RefreshScheduler: Sendable {
    var elapsed: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var jitter: @Sendable () -> TimeInterval

    static let system: RefreshScheduler = {
        let clock = ContinuousClock(), origin = clock.now
        return RefreshScheduler(
            elapsed: {
                let parts = origin.duration(to: clock.now).components
                return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            jitter: { Double.random(in: 20...40) }
        )
    }()
}

import Foundation
import QuartzCore
import MeteocatCore

/// The one descriptor of an eligible playback step. The raster blend, the presentation clock and the scrubber knob all
/// derive from it and from `CACurrentMediaTime()`, so they can never advance on their own timers or drift apart.
/// `from`/`to` stay the real frame identities; only the displayed clock between them is a visual interpolation.
struct MediaTransition: Equatable {
    let from: FrameID
    let to: FrameID
    let start: CFTimeInterval
    let duration: CFTimeInterval

    /// Linear, finite and clamped to 0...1. A non-finite clock or a zero duration is the destination endpoint.
    func progress(at now: CFTimeInterval) -> Double {
        guard now.isFinite, start.isFinite, duration.isFinite, duration > 0 else { return 1 }
        let elapsed = now - start
        return elapsed <= 0 ? 0 : elapsed >= duration ? 1 : elapsed / duration
    }

    var end: CFTimeInterval { start + duration }

    /// Rescale a pacing time around the same media instant as the transition.
    static func rescaledTime(_ time: CFTimeInterval, by factor: Double, at now: CFTimeInterval) -> CFTimeInterval {
        now + (time - now) * factor
    }

    /// Keep frame identities and progress at `now`; rescale only the remaining pace.
    func rescaled(by factor: Double, at now: CFTimeInterval) -> MediaTransition {
        MediaTransition(from: from, to: to, start: Self.rescaledTime(start, by: factor, at: now), duration: duration * factor)
    }

    /// Presentation time: linear between the two real `validUTC` values, exactly the real ones at 0 and 1.
    /// Never a measurement or a forecast of that minute.
    func visualDate(progress p: Double) -> Date {
        guard p.isFinite, p > 0 else { return from.validUTC }
        guard p < 1 else { return to.validUTC }
        return from.validUTC.addingTimeInterval(to.validUTC.timeIntervalSince(from.validUTC) * p)
    }

    /// Fractional timeline index of the knob for the same progress.
    func position(progress p: Double, fromIndex: Int, toIndex: Int) -> Double {
        guard p.isFinite, p > 0 else { return Double(fromIndex) }
        guard p < 1 else { return Double(toIndex) }
        return Double(fromIndex) + Double(toIndex - fromIndex) * p
    }
}

/// What the clock and the knob show at one instant. `interpolated` is false whenever the real sample is shown.
struct PresentationInstant: Equatable {
    var date: Date?
    var position: Double?
    var interpolated: Bool

    /// `selected` is always the real destination; without a transition (paused, seeking, cut, Reduce Motion, hidden)
    /// both values are that sample's genuine ones.
    static func at(_ now: CFTimeInterval, selected: FrameID?, selectedIndex: Int?, transition: MediaTransition?, timeline: [FrameID]) -> PresentationInstant {
        guard let transition, let fromIndex = timeline.firstIndex(of: transition.from), let toIndex = timeline.firstIndex(of: transition.to) else {
            return PresentationInstant(date: selected?.validUTC, position: selectedIndex.map(Double.init), interpolated: false)
        }
        let p = transition.progress(at: now)
        return PresentationInstant(date: transition.visualDate(progress: p), position: transition.position(progress: p, fromIndex: fromIndex, toIndex: toIndex),
                                   interpolated: p > 0 && p < 1)
    }
}

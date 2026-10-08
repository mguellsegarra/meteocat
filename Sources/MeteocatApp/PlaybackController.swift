import AppKit
import MeteocatCore

enum PlaybackRate: Double, CaseIterable, Identifiable {
    case half = 0.5, normal = 1, double = 2, quadruple = 4
    var id: Double { rawValue }
    var label: String {
        switch self { case .half: L10n.text("0,5×"); case .normal: "1×"; case .double: "2×"; case .quadruple: "4×" }
    }
    var spoken: String {
        switch self {
        case .half: L10n.text("Mitja velocitat")
        case .normal: L10n.text("Velocitat normal")
        case .double: L10n.text("Doble velocitat")
        case .quadruple: L10n.text("Quàdruple velocitat")
        }
    }
}

/// What the weather surface draws. `endpoint` is always the original straight-RGBA frame;
/// `blend` exists only for the rate-adjusted step interval of an eligible playback step.
struct WeatherPresentation {
    struct Blend { let from: RGBAImage; let transition: MediaTransition }
    let serial: Int
    let endpoint: RGBAImage
    let blend: Blend?
}

/// Timeline, selection and weather presentation. One chain of work at a time:
/// a step sleeps, then `go` decodes, then `present`, then the next step is scheduled.
/// Every pause, seek, hide or timeline replacement bumps `token`, which invalidates the chain.
/// Protection leases follow one desired set (displayed frame, blend source, live load target), installed by a single
/// reconciler that always reads the latest set, so a stale set can never land after a newer one.
@MainActor @Observable
final class PlaybackController {
    /// One step is one transition: the blend, the presentation clock and the knob run for the whole step interval,
    /// so an eligible step has no dead hold. The next step starts after one local decode.
    static let stepDuration: CFTimeInterval = 1.000

    private(set) var timeline: [FrameID] = []
    /// The frame actually displayed. Never set to a frame whose image failed to decode.
    private(set) var selectedID: FrameID?
    private(set) var isPlaying = false
    private(set) var rate: PlaybackRate = .normal
    private(set) var weather: WeatherPresentation?
    private(set) var transition: MediaTransition?
    private var frameErrorToken: LocalizedMessage?
    var frameError: String? { frameErrorToken?.rendered }

    @ObservationIgnored private let service: RadarService
    @ObservationIgnored private var displayedImage: RGBAImage?
    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var generationChanged = false
    @ObservationIgnored private var cursorID: FrameID?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var resumePlaying = false
    @ObservationIgnored private var content = [FrameID: [String]]()
    @ObservationIgnored private var selectedContent: [String]?
    @ObservationIgnored private var stepTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var loadTarget: FrameID?
    @ObservationIgnored private var installedProtection: Set<FrameID> = []
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// Media time of the last present; every next step uses the rate-adjusted step duration.
    @ObservationIgnored private var stepAnchor: CFTimeInterval?
    /// Live deadline of a paced load, including its wait after decoding. Internal read access supports timing tests.
    @ObservationIgnored private(set) var stepDeadline: CFTimeInterval?
    /// Read-only scheduling phase: the current load has decoded and is holding its target lease.
    @ObservationIgnored private(set) var isWaitingForStepDeadline = false
    private var stepInterval: CFTimeInterval { Self.stepDuration / rate.rawValue }
    /// Smoothed local decode latency. The next decode starts this much before the deadline, so the frame is ready
    /// when the previous transition ends and no dead hold remains. No network and no second image kept ahead.
    @ObservationIgnored private var loadLead: CFTimeInterval = 0.05

    init(service: RadarService) { self.service = service }

    /// Nil while the displayed observation has aged out of the timeline: the scrubber then shows no knob and the
    /// readout keeps the real time, so the UI never claims a position the frame does not have.
    var selectedIndex: Int? { selectedID.flatMap { timeline.firstIndex(of: $0) } }
    var lastObservationIndex: Int? { timeline.lastIndex { $0.kind == .observation } }

    func replaceTimeline(snapshot: RadarSnapshot) {
        // visibleTimeline is already observation block + strictly later forecast; this only
        // refuses a duplicate or backward time if that invariant ever breaks.
        var ids: [FrameID] = []
        for frame in snapshot.visibleTimeline where ids.last.map({ frame.id.validUTC > $0.validUTC }) ?? true { ids.append(frame.id) }
        if let revision, revision != snapshot.revision { generationChanged = true; cut() }
        revision = snapshot.revision
        timeline = ids
        content = Dictionary(uniqueKeysWithValues: snapshot.visibleTimeline.map { ($0.id, $0.tiles.map(\.sha256)) })
        // A displayed observation stays (image, identity and protection lease) until the user navigates, even once it
        // has aged out of the timeline; only a forecast that is no longer in it falls back to the latest observation.
        if let selectedID, ids.contains(selectedID) || (visible && selectedID.kind == .observation) { return }
        guard visible else { clearPresentation(); return }
        if selectedID != nil { invalidate(); cut() } else if loadTask != nil { return }
        guard let index = lastObservationIndex ?? (ids.isEmpty ? nil : 0) else { clearPresentation(); return }
        go(to: index, isLoopWrap: false)
    }

    func setVisible(_ value: Bool) {
        guard panelVisible != value else { return }
        panelVisible = value
        // A normal show autoplays, even if presentation must wait for wake.
        // A later explicit pause can still replace this intent.
        if value { resumePlaying = true }
        visible = value && !suspended
        guard visible else { isPlaying = false; invalidate(); cut(); return }
        isPlaying = true
        reconcileEndpoint()
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value {
            resumePlaying = isPlaying
            visible = false; isPlaying = false; invalidate(); cut()
        } else {
            visible = panelVisible
            isPlaying = visible && resumePlaying
            if visible { reconcileEndpoint() }
        }
    }
    private func reconcileEndpoint() {
        stepAnchor = nil
        if selectedIndex == nil || selectedID.flatMap({ content[$0] }) != selectedContent {
            if let index = lastObservationIndex ?? (timeline.isEmpty ? nil : 0) { go(to: index, isLoopWrap: false) }
            else { clearPresentation() }
        } else { scheduleStep(immediately: true) }
    }

    func play() {
        guard visible, !isPlaying else { return }
        isPlaying = true
        stepAnchor = nil
        if loadTask == nil { scheduleStep(immediately: true) }
    }

    /// Stops on the displayed endpoint exactly; any active blend is cut immediately.
    func pause() {
        if suspended { resumePlaying = false }
        isPlaying = false
        // Nothing displayed yet: stop stepping but let the first frame arrive.
        if selectedID == nil, loadTask != nil { stepTask?.cancel(); stepTask = nil; return }
        invalidate(); cut()
    }

    func setRate(_ new: PlaybackRate, now: CFTimeInterval = CACurrentMediaTime()) {
        guard new != rate else { return }
        let factor = rate.rawValue / new.rawValue
        rate = new
        stepAnchor = stepAnchor.map { MediaTransition.rescaledTime($0, by: factor, at: now) }
        stepDeadline = stepDeadline.map { MediaTransition.rescaledTime($0, by: factor, at: now) }
        if let step = transition, let weather, let blend = weather.blend {
            let retimed = step.rescaled(by: factor, at: now)
            serial += 1
            self.weather = WeatherPresentation(serial: serial, endpoint: weather.endpoint,
                blend: .init(from: blend.from, transition: retimed))
            transition = retimed
            armCut(retimed)
        }
        if stepTask != nil { scheduleStep() }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(toIndex index: Int) {
        guard timeline.indices.contains(index) else { return }
        pause()
        if timeline[index] != selectedID { go(to: index, isLoopWrap: false) }
    }

    func step(_ delta: Int) {
        guard !timeline.isEmpty else { return }
        if let selectedIndex { return seek(toIndex: min(max(selectedIndex + delta, 0), timeline.count - 1)) }
        // Out of the timeline: step to the nearest real frame on that side of the displayed time.
        guard let time = selectedID?.validUTC else { return seek(toIndex: min(max(delta, 0), timeline.count - 1)) }
        if delta > 0, let next = timeline.firstIndex(where: { $0.validUTC > time }) { seek(toIndex: next) }
        else if delta < 0, let previous = timeline.lastIndex(where: { $0.validUTC < time }) { seek(toIndex: previous) }
    }

    // MARK: - Chain

    /// The cursor falls back to the displayed frame: an abandoned pending target must not become the resume point.
    private func invalidate() {
        token += 1
        stepAnchor = nil
        stepDeadline = nil
        isWaitingForStepDeadline = false
        cursorID = selectedID
        stepTask?.cancel(); stepTask = nil
        loadTask?.cancel(); loadTask = nil
        loadTarget = nil
        reconcile()
    }

    /// Owns its own invalidation: any pending load or step is cancelled before the image goes, then {} is reconciled.
    private func clearPresentation() {
        invalidate()
        transitionTask?.cancel(); transitionTask = nil
        selectedContent = nil
        selectedID = nil; cursorID = nil; displayedImage = nil; weather = nil; transition = nil
        reconcile()
    }

    private func scheduleStep(immediately: Bool = false) {
        stepTask?.cancel(); stepTask = nil
        guard isPlaying, visible, timeline.count > 1 else { return }
        let atEnd = (cursorID.flatMap { timeline.firstIndex(of: $0) } ?? selectedIndex) == timeline.count - 1
        // Show/play starts from the retained endpoint without a dwell. `go` still owns decoding, leases and
        // cancellation; after presentation its successor uses the normal shared transition deadline.
        if immediately {
            let from = cursorID.flatMap { timeline.firstIndex(of: $0) } ?? selectedIndex ?? -1
            go(to: atEnd ? 0 : from + 1, isLoopWrap: atEnd)
            return
        }
        let expected = token
        let anchor = stepAnchor ?? CACurrentMediaTime()
        stepAnchor = anchor
        let target = anchor + stepInterval
        stepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, target - CACurrentMediaTime() - (self?.loadLead ?? 0))))
            guard let self, !Task.isCancelled, expected == self.token, self.isPlaying, self.visible, !self.timeline.isEmpty else { return }
            let from = self.cursorID.flatMap { self.timeline.firstIndex(of: $0) } ?? self.selectedIndex ?? -1
            let wrap = from >= self.timeline.count - 1
            self.go(to: wrap ? 0 : from + 1, isLoopWrap: wrap, notBefore: target)
        }
    }

    /// `notBefore` (playback steps only): a frame decoded early waits, still the owned load target with its lease, until the
    /// step deadline before it is presented.
    private func go(to index: Int, isLoopWrap: Bool, notBefore: CFTimeInterval? = nil) {
        guard visible else { return }
        invalidate()
        stepDeadline = notBefore
        let id = timeline[index], expected = token, expectedRevision = revision
        cursorID = id
        loadTarget = id
        reconcile()
        loadTask = Task { [weak self] in
            guard let self else { return }
            // The target's lease is installed before decoding. Awaiting is a suspension point: a pause, hide or newer
            // seek may have run meanwhile, so recheck ownership and revision before asking for weather.
            await self.protectionSettled()
            guard self.owns(expected) else { return }
            guard expectedRevision == self.revision else { self.retireStale(id); return }
            let began = CACurrentMediaTime()
            let image = try? await self.service.weather(for: id)
            guard self.owns(expected) else { return } // superseded by pause, seek, hide or a newer step: its owner cleaned up
            if image != nil { self.loadLead = min(0.25, 0.7 * self.loadLead + 0.3 * (CACurrentMediaTime() - began)) }
            if notBefore != nil, image != nil {
                // A slowdown must extend an already decoded frame's wait. A speed-up may wake at the old
                // deadline (at most loadLead late); the endpoint holds without changing the shared progress.
                self.isWaitingForStepDeadline = true
                while let deadline = self.stepDeadline {
                    let remaining = deadline - CACurrentMediaTime()
                    guard remaining > 0 else { break }
                    try? await Task.sleep(for: .seconds(remaining))
                    guard self.owns(expected) else { return }
                }
            }
            self.isWaitingForStepDeadline = false
            self.stepDeadline = nil
            self.loadTask = nil
            self.loadTarget = nil
            self.reconcile() // the target is no longer pending; the latest desired set follows, whatever happens next
            guard expectedRevision == self.revision else { self.retireStale(id); return }
            if let image {
                self.present(id, image, isLoopWrap: isLoopWrap)
            } else {
                // Keep the last good image and its timestamp; only explain the gap.
                self.frameErrorToken = .text("No s'ha pogut mostrar el fotograma de les %1$@.", String(describing: Fmt.time(id.validUTC)))
                self.stepAnchor = CACurrentMediaTime() // a failed frame keeps the normal pace to the next one
                self.reconcile()
            }
            self.scheduleStep()
        }
    }

    /// Only the current load may touch shared load state or schedule its successor.
    private func owns(_ expected: Int) -> Bool { !Task.isCancelled && expected == token && visible }

    /// The current load saw a newer timeline revision: this attempt is cancelled (not a decode error). A surviving
    /// identity reloads under the revision now current; a removed one is retired and the cursor returns to the displayed
    /// frame. The good image stays and stepping resumes only through the usual visible/playing/multi-frame gate.
    private func retireStale(_ id: FrameID) {
        stepDeadline = nil
        isWaitingForStepDeadline = false
        loadTask = nil
        loadTarget = nil
        reconcile()
        if let again = timeline.firstIndex(of: id) { go(to: again, isLoopWrap: false); return }
        cursorID = selectedID
        if selectedID == nil, let first = lastObservationIndex ?? (timeline.isEmpty ? nil : 0) { go(to: first, isLoopWrap: false); return }
        scheduleStep()
    }

    private func present(_ id: FrameID, _ image: RGBAImage, isLoopWrap: Bool) {
        transitionTask?.cancel(); transitionTask = nil
        let source = selectedID, sourceImage = displayedImage
        var blendFrom: (FrameID, RGBAImage)?
        if let source, let sourceImage, sourceImage.width == image.width, sourceImage.height == image.height,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let sourceIndex = timeline.firstIndex(of: source), let targetIndex = timeline.firstIndex(of: id),
           FrameTransition.canCrossfade(from: source, to: id, isAdjacent: sourceIndex + 1 == targetIndex, isPlaying: isPlaying,
                                        isLoopWrap: isLoopWrap, generationChanged: generationChanged) {
            blendFrom = (source, sourceImage)
        }
        generationChanged = false
        selectedContent = content[id]
        selectedID = id; displayedImage = image; frameErrorToken = nil; serial += 1
        let now = CACurrentMediaTime()
        // A wrap cuts to the first frame. When the step out of it will blend, that step is due now, so the frame starts
        // a blend like every other frame instead of holding still. Cut-only playback (Reduce Motion, a gap) keeps the hold.
        let blendsOnward = isLoopWrap && isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            timeline.firstIndex(of: id).map { $0 + 1 < timeline.count &&
                FrameTransition.canCrossfade(from: id, to: timeline[$0 + 1], isAdjacent: true, isPlaying: true,
                                             isLoopWrap: false, generationChanged: false) } == true
        stepAnchor = blendsOnward ? now - stepInterval : now
        if let (source, sourceImage) = blendFrom {
            let step = MediaTransition(from: source, to: id, start: now, duration: stepInterval)
            weather = WeatherPresentation(serial: serial, endpoint: image, blend: .init(from: sourceImage, transition: step))
            transition = step
            armCut(step)
        } else {
            weather = WeatherPresentation(serial: serial, endpoint: image, blend: nil)
            transition = nil
        }
        reconcile()
    }

    private func armCut(_ step: MediaTransition) {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, step.end - CACurrentMediaTime())))
            guard let self, !Task.isCancelled else { return }
            self.cut()
        }
    }

    /// Ends any blend and shows the selected endpoint's original bytes. Always reconciles, even with no blend to end.
    private func cut() {
        transitionTask?.cancel(); transitionTask = nil
        if transition != nil, let image = displayedImage {
            transition = nil; serial += 1
            weather = WeatherPresentation(serial: serial, endpoint: image, blend: nil)
        }
        reconcile()
    }

    // MARK: - Protection

    /// Frames the UI still needs: the displayed endpoint (also while hidden, for reopening), an active blend's source
    /// and the load target that is still current. Nothing displayed and nothing loading means an empty set.
    var desiredProtection: Set<FrameID> {
        var ids = Set<FrameID>()
        if let selectedID { ids.insert(selectedID) }
        if let transition { ids.insert(transition.from) }
        if let loadTarget { ids.insert(loadTarget) }
        return ids
    }

    /// Starts the single reconciler if none runs; a running one re-reads the desired set after every await.
    private func reconcile() {
        guard reconcileTask == nil, desiredProtection != installedProtection else { return }
        reconcileTask = Task { [weak self] in
            while let self {
                let want = self.desiredProtection
                guard want != self.installedProtection else { self.reconcileTask = nil; return }
                await self.service.protectDisplayed(want)
                self.installedProtection = want
            }
        }
    }

    /// Returns once the latest desired set is installed.
    private func protectionSettled() async {
        while let task = reconcileTask { await task.value }
    }
}

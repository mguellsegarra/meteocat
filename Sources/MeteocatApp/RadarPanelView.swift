import AppKit
import SwiftUI
import MeteocatCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

/// The single layout description. Every control frame and every label obstacle comes from here, in points of the panel
/// content (top-left origin), so a city label can never sit under a control. Frames depend only on the window size:
/// nothing moves during playback, status changes or hover. Forecasts change the clock colour only.
@MainActor enum ChromeLayout {
    /// Room kept around each control for its focus indicator and hover fill.
    static let clearance: CGFloat = 4
    static let edge: CGFloat = 16

    /// Gentle response to the window width: 1 at the 750 pt baseline, a quarter of the relative change, kept within
    /// 0.92...1.35 (600 → 0.95, 1200 → 1.15, 1800 → 1.35). Only the clock and the transport follow it; the status
    /// line and refresh button stay fixed.
    static func scale(_ size: CGSize) -> CGFloat { min(1.35, max(0.92, 1 + 0.25 * (size.width / 750 - 1))) }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Status row (fixed)

    static let statusFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    static let statusRowHeight: CGFloat = 22
    static let refreshSize: CGFloat = 22

    // MARK: Clock (scaled)

    static func timeFont(_ scale: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: (28 * scale * 2).rounded() / 2, weight: .semibold) }
    static let zoneFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    /// Fit the ordinary clock without reserving empty space for the rare repeated DST hour.
    static func timeSize(_ scale: CGFloat) -> CGSize {
        CGSize(width: textWidth("00:00", font: timeFont(scale)) + 4, height: ceil(34 * scale))
    }

    static let forecastColor = Color(nsColor: .radarForecast)

    // MARK: Clock card and corner status

    static let cardInset: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let cardVerticalPadding: CGFloat = 5
    static let cardRadius: CGFloat = 14

    /// Fits the clock alone, centred over the scrubber.
    static func card(in size: CGSize) -> CGRect {
        let time = timeSize(scale(size))
        let width = time.width + cardPadding * 2
        let height = time.height + cardVerticalPadding * 2
        let strip = transport(in: size)
        let centerX = strip.midX + 16 * scale(size)
        return CGRect(x: (centerX - width / 2).rounded(),
                      y: strip.minY - 8 - height,
                      width: width, height: height)
    }

    static func status(in size: CGSize, statusText: String = L10n.text("Última consulta: %1$@", "00:00")) -> CGRect {
        let width = textWidth(statusText, font: statusFont) + 2 + refreshSize
        return CGRect(x: size.width - cardInset - width, y: cardInset,
                      width: width, height: statusRowHeight)
    }
    static func settings(in size: CGSize) -> CGRect { CGRect(x: edge, y: size.height - 8 - 28, width: 28, height: 28) }

    /// Equal corner margins; narrow windows shrink the brand to leave room beside the transport.
    static func branding(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 401.0 / 263.0
        let inset = max(12, min(24, min(size.width, size.height) * 0.025))
        let availableWidth = max(0, size.width - inset - speed(in: size).maxX - clearance * 2)
        let width = min(availableWidth, min(180, min(size.width * 0.16, size.height * 0.13 * aspect)))
        let height = width / aspect
        return CGRect(x: size.width - inset - width, y: size.height - inset - height,
                      width: width, height: height)
    }

    // MARK: Transport (scaled)

    static let scrubberWidth: CGFloat = 280
    static func transportSize(_ scale: CGFloat) -> CGSize {
        CGSize(width: ((8 * 2 + 24 + 8 + scrubberWidth) * scale).rounded(), height: (28 * scale).rounded())
    }
    /// Centred translucent pill; its frame is the exact visual and hit footprint.
    static func transport(in size: CGSize) -> CGRect {
        let pill = transportSize(scale(size))
        return CGRect(x: ((size.width - pill.width) / 2).rounded(), y: size.height - 8 - pill.height, width: pill.width, height: pill.height)
    }

    static func speedFont(_ scale: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: 11 * scale, weight: .semibold) }
    /// Reserve the widest label so rate changes never move the control.
    static func speedSize(_ scale: CGFloat) -> CGSize {
        let text = PlaybackRate.allCases.map { textWidth($0.label, font: speedFont(scale)) }.max() ?? 0
        return CGSize(width: (text + 16 * scale).rounded(.up), height: transportSize(scale).height)
    }
    static func speed(in size: CGSize) -> CGRect {
        let strip = transport(in: size), pill = speedSize(scale(size))
        return CGRect(x: strip.maxX + (8 * scale(size)).rounded(), y: strip.minY, width: pill.width, height: pill.height)
    }

    /// Fixed for a given size: labels are placed once per resize or settings change, never per playback step.
    /// The fixed card footprint keeps labels stable during playback.
    /// `native` is the system window buttons' rectangle in the same top-left content points.
    static func obstacles(size: CGSize, native: CGRect, statusText: String = L10n.text("Última consulta: %1$@", "00:00")) -> [CGRect] {
        let strip = transport(in: size)
        return [native, card(in: size), status(in: size, statusText: statusText), settings(in: size), strip, speed(in: size), branding(in: size)]
            .map { $0.insetBy(dx: -clearance, dy: -clearance) }
    }
}

/// Native glass only on the floating controls; the radar remains sharp content behind them.
private struct RadarGlassStyle: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular.tint(Color(nsColor: .radarChromeBackground).opacity(0.4)), in: shape)
        } else {
            content.background {
                shape.fill(Color(nsColor: .radarChromeBackground).opacity(reduceTransparency || contrast == .increased ? 1 : 0.88))
                    .overlay(shape.strokeBorder(Color(nsColor: .radarInk).opacity(contrast == .increased ? 0.35 : 0.07), lineWidth: 0.5))
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var chromeFocus: ChromeFocus?
}

extension View {
    /// Mirrors a chrome button's keyboard focus for the AppKit key route, so Space stays with the focused button.
    func reportsButtonFocus(_ focused: Bool, id: String) -> some View { modifier(ButtonFocusReport(focused: focused, id: id)) }
}

private struct ButtonFocusReport: ViewModifier {
    let focused: Bool
    let id: String
    @Environment(\.chromeFocus) private var chromeFocus
    func body(content: Content) -> some View {
        content
            .onChange(of: focused, initial: true) { _, value in chromeFocus?.set(id, focused: value) }
            .onDisappear { chromeFocus?.set(id, focused: false) }
    }
}

/// Declares the cursor to SwiftUI so AppKit cursor updates agree with the link.
private struct LinkPointer: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hovering = true
                        NSCursor.pointingHand.set()
                    case .ended:
                        hovering = false
                        NSCursor.arrow.set()
                    }
                }
                .onDisappear {
                    if hovering { NSCursor.arrow.set(); hovering = false }
                }
        }
    }
}

/// Native button placement, independent of playback. Until AppKit has
/// laid the buttons out (and in full screen, where they hide) a bounded 70×30 corner stands in.
@MainActor @Observable final class NativeChrome {
    static let fallback = CGRect(x: 0, y: 0, width: 70, height: 30)
    var rect = NativeChrome.fallback
}

extension PlaybackController {
    /// The displayed frame is a forecast, even when retained outside a replacement timeline. Keyed on the selected sample (the real
    /// destination), not on the interpolated clock: forecast pixels start blending at p = 0, so the forecast colour leads the digits
    /// by up to one step on purpose. Do not "fix" this by reading `visualDate`.
    var showsForecast: Bool { selectedID?.kind == .forecast }
}

struct RadarPanelView: View {
    private static let radarURL = URL(string: "https://www.meteo.cat/observacions/radar")!
    private static let brandImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "meteocat-logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled Meteocat logo")
        }
        return image
    }()

    let model: RadarViewModel
    let focus: ChromeFocus
    let chrome: NativeChrome
    let onSettings: () -> Void
    @State private var hovering = false
    @FocusState private var settingsFocused: Bool
    @FocusState private var brandFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size, scale = ChromeLayout.scale(size)
            let gear = ChromeLayout.settings(in: size)
            let transport = ChromeLayout.transport(in: size)
            let speed = ChromeLayout.speed(in: size)
            let brand = ChromeLayout.branding(in: size)
            let brandShape = RoundedRectangle(cornerRadius: min(16, brand.width * 16 / 180), style: .continuous)
            ZStack(alignment: .topLeading) {
                MapLayer(model: model, obstacles: ChromeLayout.obstacles(size: size, native: chrome.rect,
                    statusText: model.status.compactText))

                Button {
                    NSWorkspace.shared.open(Self.radarURL)
                } label: {
                    Image(nsImage: Self.brandImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: brand.width, height: brand.height)
                        .clipShape(brandShape)
                        .contentShape(brandShape)
                }
                    .buttonStyle(.plain)
                    .focused($brandFocused)
                    .reportsButtonFocus(brandFocused, id: "brand")
                    .modifier(LinkPointer())
                    .help(Self.radarURL.absoluteString)
                    .offset(x: brand.minX, y: brand.minY)
                    .accessibilityLabel(L10n.text("Meteocat, Servei Meteorològic de Catalunya"))

                // Clock above the scrubber; unboxed status in the upper-right corner.
                UpdateGroup(model: model, size: size)

                TransportStrip(model: model, scale: scale)
                    .frame(width: transport.width, height: transport.height)
                    .offset(x: transport.minX, y: transport.minY)

                SpeedPill(playback: model.playback, scale: scale)
                    .offset(x: speed.minX, y: speed.minY)

                ChromeButton(symbol: "gearshape", label: L10n.text("Configuració"), help: L10n.text("Configuració (⌘,)"), action: onSettings)
                    .modifier(RadarGlassStyle(radius: gear.width / 2))
                    .focused($settingsFocused)
                    .opacity(hovering || settingsFocused ? 1 : 0)
                    .frame(width: gear.width, height: gear.height)
                    .offset(x: gear.minX, y: gear.minY)
                    // Reopening must reveal the gear at its final position, without a delayed entrance.
                    .transaction {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color(nsColor: .radarMapBackground))
        .ignoresSafeArea() // full-size content: the window frame is the layout space, the system draws shape and border
        .onHover { hovering = $0 }
        .environment(\.locale, L10n.locale)
        // Canvas, offsets, map geography and chronological transport use one physical coordinate space.
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.chromeFocus, focus)
    }
}

/// Reads only the weather presentation and settings, so a playback step does not re-evaluate the chrome.
private struct MapLayer: View {
    let model: RadarViewModel
    let obstacles: [CGRect]
    var body: some View {
        MapView(geography: model.geography, projection: model.projection, weather: model.playback.weather,
                labels: MapLabels(model.settings), obstacles: obstacles)
    }
}

// MARK: - Time

/// The displayed time. Between samples of an eligible step it follows the shared `MediaTransition` (same p as the raster
/// and the knob) through the real valid times; at every other moment it is the selected sample's genuine time.
/// Numeric changes roll in the direction of the presentation date, at the selected playback rate.
private struct TimeReadout: View {
    let playback: PlaybackController
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let forecast = playback.showsForecast
        let selected = playback.selectedID, index = playback.selectedIndex
        let transition = playback.transition, timeline = playback.timeline
        let size = ChromeLayout.timeSize(scale)
        TimelineView(.animation(paused: transition == nil)) { _ in
            let instant = PresentationInstant.at(CACurrentMediaTime(), selected: selected, selectedIndex: index, transition: transition, timeline: timeline)
            let parts = instant.date.map(Fmt.timeParts) ?? (digits: "--:--", zone: "")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // The repeated DST hour keeps its zone label; the digits can shrink slightly in that rare case.
                if !parts.zone.isEmpty {
                    Text(parts.zone).font(Font(ChromeLayout.zoneFont)).foregroundStyle(Color(nsColor: .radarClockZone))
                }
                Text(parts.digits)
                    .font(Font(ChromeLayout.timeFont(scale)))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(forecast ? ChromeLayout.forecastColor : Color(nsColor: .radarTransportInk).opacity(0.95))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: forecast)
                    .contentTransition(reduceMotion ? .identity :
                        .numericText(value: instant.date?.timeIntervalSince1970 ?? 0))
                    .animation(reduceMotion ? nil :
                        .easeOut(duration: 0.12 / playback.rate.rawValue),
                        value: parts.digits)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .trailing)
        .opacity(selected == nil ? 0 : 1)
        .accessibilityHidden(selected == nil)
        .help(Self.detail(selected: selected, transition: transition))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Fotograma mostrat"))
        .accessibilityValue(Self.spoken(selected: selected, transition: transition))
    }

    /// Text that depends on the step, never on p, so it changes once per step and not per frame.
    static func detail(selected: FrameID?, transition: MediaTransition?) -> String {
        guard let selected else { return L10n.text("Encara no hi ha cap fotograma") }
        guard let transition else { return Fmt.detail(selected) }
        return L10n.text("Rellotge visual interpolat entre les mostres reals de les %1$@ i les %2$@; no és una mesura ni una previsió nova. Mostra seleccionada: %3$@", String(describing: Fmt.time(transition.from.validUTC)), String(describing: Fmt.time(transition.to.validUTC)), String(describing: Fmt.detail(transition.to)))
    }

    static func spoken(selected: FrameID?, transition: MediaTransition?) -> String {
        guard let selected else { return L10n.text("Cap fotograma") }
        guard let transition else { return Fmt.spoken(selected) }
        return L10n.text("Rellotge visual interpolat entre les %1$@ i les %2$@. Mostra real seleccionada: %3$@", String(describing: Fmt.time(transition.from.validUTC)), String(describing: Fmt.time(transition.to.validUTC)), String(describing: Fmt.spoken(transition.to)))
    }
}

// MARK: - Update

/// Discreet corner status and refresh, with a separate clock card above the scrubber.
private struct UpdateGroup: View {
    let model: RadarViewModel
    let size: CGSize

    var body: some View {
        let status = model.status
        let refreshing = model.isRefreshing
        let empty = model.playback.selectedID == nil
        let emptyText: String = {
            if model.playback.frameError != nil { return L10n.text("Radar no disponible") }
            switch model.snapshot?.sourceState {
            case .unavailable: return L10n.text("Radar no disponible")
            case .deferred: return L10n.text("Esperant Meteocat…")
            default: return L10n.text("Carregant radar…")
            }
        }()
        let visibleStatus = empty ? emptyText : status.compactText
        let statusFrame = ChromeLayout.status(in: size, statusText: visibleStatus)
        let card = ChromeLayout.card(in: size)
        ZStack(alignment: .topLeading) {
            HStack(alignment: .center, spacing: 0) {
                Text(visibleStatus)
                    .font(Font(ChromeLayout.statusFont).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .radarInk).opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: statusFrame.width - ChromeLayout.refreshSize, height: statusFrame.height, alignment: .trailing)
                    .help(status.detail)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.text("Estat de les dades"))
                    .accessibilityValue(status.detail)

                RefreshButton(refreshing: refreshing) { model.refresh() }
            }
            .frame(width: statusFrame.width, height: statusFrame.height, alignment: .trailing)
            .offset(x: statusFrame.minX, y: statusFrame.minY)
            if !empty {
                TimeReadout(playback: model.playback, scale: ChromeLayout.scale(size))
                    .frame(width: card.width, height: card.height)
                    .modifier(RadarGlassStyle(radius: ChromeLayout.cardRadius))
                    .offset(x: card.minX, y: card.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

}

private struct RefreshButton: View {
    let refreshing: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color(nsColor: .radarInk).opacity(0.7))
                    .accessibilityLabel(L10n.text("Actualitzant el radar"))
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .radarInk).opacity(hovering ? 0.85 : 0.7))
                        .frame(width: ChromeLayout.refreshSize, height: ChromeLayout.refreshSize)
                }
                .buttonStyle(PressFillStyle(hovering: hovering, focused: focused, fills: (0, 0.08, 0.14)))
                .focusEffectDisabled()
                .focused($focused)
                .reportsButtonFocus(focused, id: "refresh")
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hovering = true
                        NSCursor.pointingHand.set()
                    case .ended:
                        hovering = false
                        NSCursor.arrow.set()
                    }
                }
                .onDisappear {
                    if hovering { NSCursor.arrow.set(); hovering = false }
                }
                .help(L10n.text("Actualitza les dades (⌘R)"))
                .accessibilityLabel(L10n.text("Actualitza les dades"))
            }
        }
        .frame(width: ChromeLayout.refreshSize, height: ChromeLayout.refreshSize)
    }
}

// MARK: - Transport

/// Compact bottom-centre pill: play/pause and the scrubber on native glass, with an accessible dark fallback. Every part follows the
/// same `scale` as `ChromeLayout.transport`, so the drawn pill is the reserved frame.
private struct TransportStrip: View {
    let model: RadarViewModel
    let scale: CGFloat
    var body: some View {
        let pill = ChromeLayout.transportSize(scale), radius = pill.height / 2
        HStack(spacing: 8 * scale) {
            PlayPauseButton(playback: model.playback, scale: scale)
            TimelineScrubber(playback: model.playback, scale: scale)
                .frame(width: ChromeLayout.scrubberWidth * scale, height: 24 * scale)
        }
        .frame(width: pill.width, height: pill.height)
        .modifier(RadarGlassStyle(radius: radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Reproducció del radar"))
        .accessibilityAction(named: model.settings.labelsVisible ? L10n.text("Amaga les ciutats") : L10n.text("Mostra les ciutats")) { model.toggleLabels() }
    }
}

/// Circle fill on hover/press, plus a thin ring when keyboard-focused (the large native focus rectangle is disabled).
private struct PressFillStyle: ButtonStyle {
    let hovering: Bool
    let focused: Bool
    let fills: (rest: Double, hover: Double, pressed: Double)
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color(nsColor: .radarInk).opacity(configuration.isPressed ? fills.pressed : hovering ? fills.hover : fills.rest)))
            .overlay {
                if focused {
                    Circle().strokeBorder(Color(nsColor: .radarInk).opacity(contrast == .increased ? 1 : 0.8), lineWidth: contrast == .increased ? 2 : 1.5)
                }
            }
            .contentShape(Circle())
    }
}

private struct PlayPauseButton: View {
    let playback: PlaybackController
    let scale: CGFloat
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        let playing = playback.isPlaying
        Button { playback.togglePlay() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(Color(nsColor: .radarTransportInk))
                .shadow(color: Color(nsColor: .radarTransportShadow).opacity(0.6), radius: 1.5)
                .offset(x: playing ? 0 : scale) // optical centring of the play triangle
                .frame(width: 24 * scale, height: 24 * scale)
        }
        .buttonStyle(PressFillStyle(hovering: hovering, focused: focused, fills: (0, 0.14, 0.22)))
        .focusEffectDisabled()
        .focused($focused)
        .reportsButtonFocus(focused, id: "play")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(playing ? L10n.text("Pausa") : L10n.text("Reprodueix"))
        .help(playing ? L10n.text("Pausa (Espai)") : L10n.text("Reprodueix (Espai)"))
    }
}

private struct ChromeButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: .radarInk).opacity(hovering ? 0.85 : 0.55))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PressFillStyle(hovering: hovering, focused: focused, fills: (0, 0.08, 0.12)))
        .focusEffectDisabled()
        .focused($focused)
        .reportsButtonFocus(focused, id: symbol)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
        .help(help)
    }
}

/// Index-based scrubber: one equal step per real frame, snapping on seek. During an eligible step the knob follows the
/// shared `MediaTransition` (same p as the raster and the clock); any cut or seek snaps to the real index. Keyboard
/// focus shows a thin ring around the knob (or the track when nothing is selected) instead of the native rectangle.
private struct TimelineScrubber: View {
    let playback: PlaybackController
    let scale: CGFloat
    @State private var dragIndex: Int?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let frames = playback.timeline
        let lastObservation = playback.lastObservationIndex
        let hasForecast = lastObservation.map { $0 < frames.count - 1 } ?? false
        let selected = playback.selectedID, selectedIndex = playback.selectedIndex, transition = playback.transition
        let strong = contrast == .increased
        GeometryReader { geo in
            let knob = 10 * scale, inset = knob / 2 + 1, bar = 3 * scale
            let width = max(1, geo.size.width - inset * 2), midY = geo.size.height / 2
            let x: (Double) -> CGFloat = { inset + (frames.count > 1 ? CGFloat($0) / CGFloat(frames.count - 1) * width : 0) }
            let observedEnd = hasForecast ? x(Double(lastObservation ?? 0)) : inset + width
            TimelineView(.animation(paused: transition == nil)) { _ in
                let instant = PresentationInstant.at(CACurrentMediaTime(), selected: selected, selectedIndex: selectedIndex, transition: transition, timeline: frames)
                let knobPosition = dragIndex.map(Double.init) ?? instant.position
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let track = Path(roundedRect: CGRect(x: inset, y: midY - bar / 2, width: observedEnd - inset, height: bar), cornerRadius: bar / 2)
                        context.fill(track, with: .color(Color(nsColor: .radarScrubberTrack).opacity(focused ? 0.34 : 0.24)))
                        if let knobPosition {
                            context.fill(Path(roundedRect: CGRect(x: inset, y: midY - bar / 2, width: max(0, min(x(knobPosition), observedEnd) - inset), height: bar), cornerRadius: bar / 2),
                                         with: .color(Color(nsColor: .radarScrubberFill)))
                        }
                        if hasForecast {
                            var dotX = observedEnd + 4
                            while dotX <= inset + width + 0.5 {
                                context.fill(Path(ellipseIn: CGRect(x: dotX - 1.25, y: midY - 1.25, width: 2.5, height: 2.5)),
                                             with: .color(ChromeLayout.forecastColor.opacity(colorScheme == .light ? 1 : 0.55)))
                                dotX += 4
                            }
                        }
                        if focused, knobPosition == nil {
                            // No real selection to ring: mark the track itself.
                            context.stroke(Path(roundedRect: CGRect(x: 1, y: midY - 5, width: size.width - 2, height: 10), cornerRadius: 5),
                                           with: .color(Color(nsColor: .radarTransportInk).opacity(strong ? 1 : 0.7)), lineWidth: strong ? 2 : 1.25)
                        }
                    }
                    .shadow(color: Color(nsColor: .radarTransportShadow).opacity(0.5), radius: 1.5)
                    if let knobPosition {
                        ZStack {
                            if focused {
                                Circle().strokeBorder(Color(nsColor: .radarTransportInk).opacity(strong ? 1 : 0.85), lineWidth: strong ? 2 : 1.5).frame(width: knob + 7, height: knob + 7)
                            }
                            Circle().fill(Color(nsColor: .radarTransportInk)).frame(width: knob, height: knob).shadow(color: Color(nsColor: .radarTransportShadow).opacity(0.5), radius: 1.5, y: 1)
                        }
                        .position(x: x(knobPosition), y: midY)
                    }

                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = Self.index(at: value.location.x - inset, width: width, count: frames.count)
                    guard index != dragIndex else { return }
                    dragIndex = index
                    playback.seek(toIndex: index)
                }
                .onEnded { _ in dragIndex = nil })
            .onChange(of: frames) { _, _ in dragIndex = nil }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in ScrubberKeys.handle(press.modifiers, delta: -1, step: playback.step) }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in ScrubberKeys.handle(press.modifiers, delta: 1, step: playback.step) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Línia de temps"))
        .accessibilityValue(selected == nil ? L10n.text("Sense dades") : TimeReadout.spoken(selected: selected, transition: transition))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.step(1)
            case .decrement: playback.step(-1)
            @unknown default: break
            }
        }
    }

    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0 else { return 0 }
        return min(count - 1, max(0, Int((x / width * CGFloat(count - 1)).rounded())))
    }
}

/// A separate glass menu beside the centred transport; the rate belongs to this app session.
private struct SpeedPill: View {
    let playback: PlaybackController
    let scale: CGFloat
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let size = ChromeLayout.speedSize(scale)
        Menu {
            Picker(L10n.text("Velocitat"), selection: Binding(get: { playback.rate }, set: { playback.setRate($0) })) {
                ForEach(PlaybackRate.allCases) { Text($0.label).accessibilityLabel($0.spoken).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(playback.rate.label)
                .font(Font(ChromeLayout.speedFont(scale)))
                .foregroundStyle(Color(nsColor: .radarTransportInk).opacity(hovering ? 0.95 : 0.8))
                .frame(width: size.width, height: size.height)
                .background(Capsule().fill(Color(nsColor: .radarInk).opacity(hovering ? 0.1 : 0)))
                .overlay { if focused { Capsule().strokeBorder(Color(nsColor: .radarTransportInk).opacity(0.8), lineWidth: 1.5).padding(2) } }
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .focusEffectDisabled()
        .focused($focused)
        .reportsButtonFocus(focused, id: "speed")
        .onHover { hovering = $0 }
        .frame(width: size.width, height: size.height)
        .modifier(RadarGlassStyle(radius: size.height / 2))
        .help(L10n.text("Velocitat de reproducció"))
        .accessibilityLabel(L10n.text("Velocitat de reproducció"))
        .accessibilityValue(playback.rate.spoken)
    }
}

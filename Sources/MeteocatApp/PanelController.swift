import AppKit
import MeteocatCore
import CoreGraphics
import SwiftUI

/// The radar window: an ordinary titled, resizable, full-screen-capable window with a transparent titlebar over the map.
/// Keys reach `keyDown` only when the focused SwiftUI control did not handle them, so a focused button keeps its own
/// Space activation and the scrubber's arrow handler wins: every key has exactly one route.
final class RadarPanel: NSWindow {
    var onClose: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    // Native chrome shares the radar's physical coordinate space in every app language.
    override var windowTitlebarLayoutDirection: NSUserInterfaceLayoutDirection { .leftToRight }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { onClose(); return }
        if !onKey(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

/// Panel keyboard commands. Only unmodified keys (Shift excluded too) and ⌘-only equivalents, so text entry,
/// VoiceOver (⌃⌥) and the Settings recorder (another window, local monitor first) are never intercepted.
@MainActor enum PanelKeys {
    enum Command: Equatable { case togglePlay, step(Int), toggleLabels, refresh, settings, enlarge, shrink, defaultSize }

    static func command(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, buttonFocused: Bool) -> Command? {
        let mods = flags.intersection([.command, .option, .control, .shift])
        if (mods == .command || mods == [.command, .shift]), characters == "+" || characters == "=" { return .enlarge }
        if mods == .command {
            switch characters {
            case ",": return .settings
            case "r": return .refresh
            case "-": return .shrink
            case "0": return .defaultSize
            default: return nil
            }
        }
        guard mods.isEmpty else { return nil }
        switch keyCode {
        case 49: return buttonFocused ? nil : .togglePlay // a focused button activates itself instead
        case 123: return .step(-1)
        case 124: return .step(1)
        default: return characters == "l" ? .toggleLabels : nil
        }
    }
}

/// An ordered-in window may still be behind another app or on a different Space.
/// Toggle hides only a radar that is already presented to the user.
enum RadarPresentation {
    static func shouldHide(visible: Bool, miniaturized: Bool, onActiveSpace: Bool,
                           appActive: Bool, keyWindow: Bool) -> Bool {
        visible && !miniaturized && onActiveSpace && appActive && keyWindow
    }
}

/// Compare actual window-server ordering rather than key focus stolen by the status button.
/// Only numeric identifiers/layers are read; no window titles, content or coordinates are inspected.
enum RadarStatusPresentation {
    static func radarIsFrontmost(_ windows: [[String: Any]]?, pid: Int, window: Int) -> Bool {
        guard let windows else { return false }
        for entry in windows {
            guard let layer = entry[kCGWindowLayer as String] as? NSNumber else { return false }
            guard layer.intValue == NSWindow.Level.normal.rawValue else { continue }
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { return false }
            return owner.intValue == pid && number.intValue == window
        }
        return false
    }
}

/// Complete only the latest window presentation after AppKit finishes activating the app.
/// Notification delivery is on the main queue; cancellation also invalidates an already-enqueued callback.
@MainActor final class RadarActivationCompletion {
    private let notifications: NotificationCenter
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0

    init(notifications: NotificationCenter = .default) { self.notifications = notifications }
    deinit { if let observer { notifications.removeObserver(observer) } }

    func cancel() {
        generation &+= 1
        if let observer { notifications.removeObserver(observer) }
        observer = nil
    }
    func request(application: AnyObject?, isActive: Bool, activate: () -> Void,
                 completion: @escaping @MainActor () -> Void) {
        cancel()
        let current = generation
        if !isActive {
            observer = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                  object: application, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.cancel()
                    completion()
                }
            }
        }
        activate()
        if isActive, generation == current { completion() }
    }
}

/// Which chrome control SwiftUI has focused, mirrored for the AppKit key route. Not observed: it never redraws anything.
@MainActor final class ChromeFocus {
    private var focusedButtons = Set<String>()
    var buttonFocused: Bool { !focusedButtons.isEmpty }
    /// Per control, so a gain and a loss arriving in either order never leave a stale value.
    func set(_ id: String, focused: Bool) { if focused { focusedButtons.insert(id) } else { focusedButtons.remove(id) } }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: RadarPanel?
    private var languageObserver: UUID?
    deinit {
        if let token = languageObserver { Task { @MainActor in L10n.state.removeObserver(token) } }
    }
    private let host: NSHostingView<RadarPanelView>
    private let model: RadarViewModel
    private let placementStore = WindowPlacementStore(legacyDefaults: UserDefaults(suiteName: MeteocatResources.legacyApplicationIdentifier))
    private var placement = WindowPlacement()
    private var savePlacementTask: Task<Void, Never>?
    private var programmaticMove = false
    /// True from just before a full-screen transition until it has fully ended: windowed placement is never overwritten.
    private var fullScreenTransition = false
    private var hideAfterFullScreenExit = false
    private let openSettings: () -> Void
    private let focus = ChromeFocus()
    private let chrome = NativeChrome()
    private let activation = RadarActivationCompletion()

    init(model: RadarViewModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        host = NSHostingView(rootView: RadarPanelView(model: model, focus: focus, chrome: chrome, onSettings: openSettings))
        super.init()
        placement = placementStore.load()
        host.sizingOptions = [] // the window owns its size; SwiftUI content never constrains it
        panel = makePanel()
        languageObserver = L10n.state.observe { [weak self] in self?.panel?.title = L10n.text("Radar Meteocat") }
    }

    /// Each presentation after a completed close needs a new native window identity. The hosting view and radar
    /// state outlive windows, so reopening does not rebuild the model, playback, map or service.
    private func makePanel() -> RadarPanel {
        let panel = RadarPanel(contentRect: NSRect(origin: .zero, size: WindowPlacement.defaultSize),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: true)
        panel.title = L10n.text("Radar Meteocat") // hidden, but it names the window in the Window menu and to VoiceOver
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Let AppKit place the standard window buttons with normal toolbar margins.
        let toolbar = NSToolbar(identifier: "RadarWindowToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.backgroundColor = .radarMapBackground
        panel.isMovableByWindowBackground = false // the map drags explicitly; controls never move the window
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.minSize = WindowPlacement.minimumSize // frame points; the content fills the whole frame
        panel.contentMinSize = WindowPlacement.minimumSize
        panel.delegate = self

        panel.contentView = host

        panel.onClose = { [weak self] in self?.hide() }
        panel.onKey = { [weak self] event in self?.perform(event, equivalent: false) ?? false }
        panel.onKeyEquivalent = { [weak self] event in self?.perform(event, equivalent: true) ?? false }
        return panel
    }

    /// Close before detaching content and retiring callbacks. A fresh toolbar belongs to the next window.
    /// Only call once the window has completely left full screen.
    private func closePanel() {
        guard let panel, !isFullScreen, !fullScreenTransition else { return }
        cancelPendingActivation()
        savePlacementTask?.cancel(); savePlacementTask = nil
        panel.close()
        panel.delegate = nil
        panel.contentView = nil
        panel.onClose = {}
        panel.onKey = { _ in false }
        panel.onKeyEquivalent = { _ in false }
        self.panel = nil
    }

    private func perform(_ event: NSEvent, equivalent: Bool) -> Bool {
        guard let command = PanelKeys.command(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers?.lowercased(),
                                              flags: event.modifierFlags, buttonFocused: focus.buttonFocused) else { return false }
        // Equivalents carry ⌘; plain keys arrive through keyDown. Never act on the same event twice.
        let isEquivalent = command == .refresh || command == .settings || command == .enlarge || command == .shrink || command == .defaultSize
        guard isEquivalent == equivalent else { return false }
        switch command {
        case .togglePlay: model.playback.togglePlay()
        case .step(let delta): model.playback.step(delta)
        case .toggleLabels: model.toggleLabels()
        case .refresh: model.refresh()
        case .settings: openSettings()
        case .enlarge: resize { WindowPlacement.scaled($0, by: 1.2, in: $1) }
        case .shrink: resize { WindowPlacement.scaled($0, by: 1 / 1.2, in: $1) }
        case .defaultSize: resize { _, visible in WindowPlacement.clamped(WindowPlacement.defaultSize, in: visible) }
        }
        return true
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    private var isFullScreen: Bool { panel?.styleMask.contains(.fullScreen) ?? false }
    var isPresented: Bool {
        guard let panel else { return false }
        return RadarPresentation.shouldHide(visible: panel.isVisible, miniaturized: panel.isMiniaturized,
                                     onActiveSpace: panel.isOnActiveSpace,
                                     appActive: NSApp.isActive, keyWindow: panel.isKeyWindow)
    }
    func toggle() { isPresented ? hide() : show() }
    /// A status-bar click takes key focus. Use actual ordinary-window order so a covered
    /// radar is brought forward; only an already-front radar is hidden.
    func shouldHideForStatusClick() -> Bool {
        guard let panel, panel.isVisible, !panel.isMiniaturized, panel.isOnActiveSpace,
              !hideAfterFullScreenExit else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let front = RadarStatusPresentation.radarIsFrontmost(windows, pid: Int(ProcessInfo.processInfo.processIdentifier), window: panel.windowNumber)
        return front
    }

    func performStatusClick(hidePresentedRadar: Bool) {
        hidePresentedRadar ? hide() : show()
    }

    /// Every system open/reopen ends here. Restore a presented window, or create a fresh native window after close,
    /// while retaining playback, placement, the hosting view, model and service.
    func show() {
        let cancelledHide = hideAfterFullScreenExit
        hideAfterFullScreenExit = false
        if cancelledHide { model.setViewerVisible(true) }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.alphaValue = 1
        let wasVisible = panel.isVisible
        let wasMiniaturized = panel.isMiniaturized
        if wasMiniaturized { panel.deminiaturize(nil) }
        if !wasVisible && !wasMiniaturized {
            let screen = NSScreen.screens.first { Self.key($0) == placement.screen }
                ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let screen { place(on: screen) }
        }
        // Keep a visible background window behind the active app until activation completes.
        let raiseOnActivation = wasVisible && !wasMiniaturized
            && panel.isOnActiveSpace && !NSApp.isActive
        if !raiseOnActivation { panel.makeKeyAndOrderFront(nil) }
        if !wasVisible { model.setViewerVisible(true) }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.updateNativeChrome()
        }
        activation.request(application: NSApp, isActive: NSApp.isActive, activate: { AppActivation.request() }) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel,
                  panel.isVisible, !panel.isMiniaturized, !self.hideAfterFullScreenExit else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Settings or another explicit presentation cancels a radar focus request still awaiting activation.
    func cancelPendingActivation() { activation.cancel() }

    /// Close button, Esc and ⌘W all end here: the window hides, the app and its playback stay available. From full
    /// screen the window first leaves it, so no empty full-screen space is left behind.
    func hide() {
        cancelPendingActivation()
        guard let panel, panel.isVisible else { return }
        if isFullScreen || fullScreenTransition {
            guard !hideAfterFullScreenExit else { return }
            hideAfterFullScreenExit = true
            model.setViewerVisible(false)
            if !fullScreenTransition { panel.toggleFullScreen(nil) }
            return
        }
        savePlacement()
        closePanel()
        model.setViewerVisible(false)
    }

    private func place(on screen: NSScreen) {
        guard let panel else { return }
        let frame = placement.frame(in: screen.visibleFrame, screen: Self.key(screen))
        programmaticMove = true
        panel.setFrame(frame, display: false)
        programmaticMove = false
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { hide() }
        return false
    }

    /// Standard zoom fills the display's visible area; the native zoom restores the previous frame.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window === panel else { return newFrame }
        return window.screen?.visibleFrame ?? newFrame
    }

    private func isCurrentWindow(_ notification: Notification) -> Bool {
        guard let window = notification.object as? NSWindow, let panel else { return false }
        return window === panel
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        cancelPendingActivation(); model.setViewerVisible(false)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        model.setViewerVisible(true); updateNativeChrome()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        savePlacement() // the windowed frame, before anything changes it; also cancels a pending debounce
        fullScreenTransition = true
        updateNativeChrome()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        fullScreenTransition = false
        updateNativeChrome()
        if hideAfterFullScreenExit, let panel { fullScreenTransition = true; panel.toggleFullScreen(nil) } // hide was asked meanwhile
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        savePlacementTask?.cancel(); savePlacementTask = nil
        fullScreenTransition = true
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        fullScreenTransition = false
        updateNativeChrome()
        if hideAfterFullScreenExit {
            hideAfterFullScreenExit = false
            closePanel()
        }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === panel else { return }
        fullScreenTransition = false
        updateNativeChrome()
        if hideAfterFullScreenExit {
            hideAfterFullScreenExit = false
            hide()
        }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === panel else { return }
        fullScreenTransition = false
        let wasHiding = hideAfterFullScreenExit
        hideAfterFullScreenExit = false
        if wasHiding { model.setViewerVisible(window.isVisible && !window.isMiniaturized) }
        updateNativeChrome()
    }

    func windowDidMove(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        schedulePlacementSave()
    }
    func windowDidResize(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        updateNativeChrome(); schedulePlacementSave()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        savePlacement()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard isCurrentWindow(notification) else { return }
        guard let panel, let screen = panel.screen, !isFullScreen, !fullScreenTransition, !panel.isZoomed else { return }
        let size = WindowPlacement.clamped(panel.frame.size, in: screen.visibleFrame)
        guard size != panel.frame.size else { return }
        resize { _, _ in size }
    }

    // MARK: Placement

    /// Save the last windowed frame, including native zoom or an external window manager's maximized frame.
    /// Full-screen transitions and minimization must never replace that geometry.
    private var canSave: Bool {
        guard let panel else { return false }
        return !programmaticMove && !fullScreenTransition && !isFullScreen && !panel.isMiniaturized
    }

    private func schedulePlacementSave() {
        guard canSave, isVisible else { return }
        savePlacementTask?.cancel()
        savePlacementTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.savePlacement()
        }
    }

    private func savePlacement() {
        savePlacementTask?.cancel(); savePlacementTask = nil
        guard canSave, let panel, let screen = panel.screen else { return }
        let key = Self.key(screen), visible = screen.visibleFrame
        placement.width = min(WindowPlacement.maximumDimension, max(WindowPlacement.minimumSize.width, panel.frame.width))
        placement.height = min(WindowPlacement.maximumDimension, max(WindowPlacement.minimumSize.height, panel.frame.height))
        placement.screen = key
        placement.positions[key] = .init(x: panel.frame.minX - visible.minX, y: panel.frame.minY - visible.minY)
        placementStore.save(placement)
    }

    /// Keyboard resizing keeps the same window and centre, within the current display's visible area.
    private func resize(_ newSize: (NSSize, NSRect) -> NSSize) {
        guard let panel, !isFullScreen, !fullScreenTransition, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = newSize(panel.frame.size, visible)
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frame = NSRect(x: min(max(centre.x - size.width / 2, visible.minX), visible.maxX - size.width),
                           y: min(max(centre.y - size.height / 2, visible.minY), visible.maxY - size.height),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    // MARK: Native chrome

    /// The system buttons' rectangle in top-left content points, so labels keep clear of them. The real bounds are
    /// converted through the hosting view (flipped or not); otherwise, and in full screen, the bounded fallback.
    private func updateNativeChrome() {
        guard let panel else { return }
        var rect = NativeChrome.fallback
        if !isFullScreen, !fullScreenTransition {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { panel.standardWindowButton($0) }
            let frames = buttons.filter { $0.window === panel && !$0.isHidden }.map { host.convert($0.bounds, from: $0) }
            if let first = frames.first {
                let union = frames.dropFirst().reduce(first) { $0.union($1) }
                let top = host.isFlipped ? union.minY : host.bounds.height - union.maxY
                let converted = CGRect(x: union.minX, y: top, width: union.width, height: union.height)
                if converted.width > 0, converted.height > 0, converted.maxX <= 400, converted.maxY <= 200 { rect = converted }
            }
        }
        if chrome.rect != rect { chrome.rect = rect }
    }

    private static func key(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return screen.localizedName
    }
}

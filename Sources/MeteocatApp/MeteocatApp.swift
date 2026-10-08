import AppKit
import SwiftUI
import MeteocatCore

@main
enum MeteocatApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Launch arguments: `--fixture [directory]` selects recorded data (otherwise live mode). Every normal launch shows the
/// panel, so `--show` is accepted only as a redundant, compatible spelling. Anything else is rejected before any service
/// exists, so a typo can never fall through to live mode. System-injected `-NS…`/`-Apple…` pairs and `-psn_…` are ignored.
/// Fixture time is the snapshot's recorded capture time, so its forecasts stay valid offline.
struct LaunchOptions {
    var mode: DataMode = .live

    static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var fixtureDirectory: URL?
        var fixture = false
        var index = arguments.startIndex + 1 // arguments[0] is the executable path
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--show": break
            case "--fixture":
                fixture = true
                if index < arguments.endIndex, !arguments[index].hasPrefix("-") {
                    fixtureDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                    index += 1
                }
            case _ where argument.hasPrefix("-psn_"): break
            case _ where argument.hasPrefix("-NS") || argument.hasPrefix("-Apple"):
                if index < arguments.endIndex, !arguments[index].hasPrefix("-") { index += 1 }
            default: throw MeteocatError(L10n.text("Argument desconegut: %1$@. S'admeten --fixture [directori] i --show.", String(describing: argument)))
            }
        }
        if fixture {
            let directory = fixtureDirectory ?? MeteocatResources.previewFixtureDirectory
            let info = try NativeJSON.decode(SnapshotInfo.self, AtomicFile.read(directory.appendingPathComponent("snapshot-info.json")))
            options.mode = .fixture(directory: directory, referenceUTC: info.capturedAt)
        }
        return options
    }
}

/// Recorded mode never needs the network; this makes that a guarantee rather than a convention.
private struct OfflineClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw MeteocatError(L10n.text("Mode de prova: sense xarxa.")) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var languageObserver: UUID?
    deinit {
        if let token = languageObserver { Task { @MainActor in L10n.state.removeObserver(token) } }
    }
    private var startupPhase = "launch"
    private var launchFailureWindow: NSWindow?
    private var launchFailureAlert: NSAlert?

    private var refreshLifecycle: AppRefreshLifecycle?
    private var terminating = false
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var model: RadarViewModel?
    private var settingsObservation: UUID?
    private var panel: PanelController?
    private let shortcut = GlobalShortcut()
    private var settingsController: SettingsWindowController?
    private var shortcutRecorder: ShortcutRecorderModel?
    private var keyboardShortcutsController: KeyboardShortcutsWindowController?
    private var aboutController: AboutWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startupPhase = "didFinishLaunching"
        refreshLifecycle = AppRefreshLifecycle()
        installMainMenu()
        languageObserver = L10n.state.observe { [weak self] in
            if let menu = NSApp.mainMenu { LocalizedMenu.retitle(menu) }
            guard let self, let alert = self.launchFailureAlert else { return }
            alert.messageText = L10n.text("No s'ha pogut obrir Meteocat")
            alert.informativeText = L10n.text("Tanca l'app i torna-la a obrir. Codi: %1$@.", self.startupPhase)
            alert.buttons.first?.title = L10n.text("Tanca l'app")
        }
        installStatusItem()
        shortcut.onPress = { [weak self] in self?.panel?.toggle() }
        Task { await bootstrap() }
    }

    /// Local only: settings file, cache manifest and bundled geography. No weather request happens here.
    private func bootstrap() async {
        do {
            startupPhase = "options"
            let mode = try LaunchOptions.parse(CommandLine.arguments).mode
            startupPhase = "settings"
            let store = try await SettingsStore.open(at: MeteocatResources.defaultSettingsURL)
            let settings = await store.load(), notice = await store.recoveryNotice()
            applyPresence(settings)
            var fixtureCapture: Date?
            let client: any HTTPClient
            if case .fixture(_, let reference) = mode { fixtureCapture = reference; client = OfflineClient() } else { client = URLSessionHTTPClient() }
            startupPhase = "service"
            let service = try await RadarService.open(cacheRoot: MeteocatResources.defaultCacheRoot, mode: mode, client: client, now: { Date() })
            let geographyDirectory = MeteocatResources.geographyDirectory
            startupPhase = "projection"
            let projection = try MapProjection(manifestURL: geographyDirectory.appendingPathComponent("projection-manifest.json"))
            var geography: Geography?
            startupPhase = "geography"
            do { geography = try Geography(directory: geographyDirectory, nativeDark: true) } catch { startupPhase = "geography-unavailable" }
            let model = RadarViewModel(service: service, store: store, settings: settings, recoveryNotice: notice,
                                       geography: geography, projection: projection, fixtureCapture: fixtureCapture)
            guard !terminating else { await service.shutdown(); return }
            startupPhase = "model"
            await model.start()
            self.model = model
            settingsObservation = model.observeSettings { [weak self] settings in
                // App-local override covers radar, retained Settings, sheets and native menus.
                // nil restores inheritance and keeps Automatic responsive to system changes.
                NSApp.appearance = settings.appearance.nativeAppearance
                self?.applyPresence(settings)
            }
            startupPhase = "panel"
            panel = PanelController(model: model) { [weak self] in self?.openSettings() }
            shortcutRecorder = ShortcutRecorderModel(model: model, shortcut: shortcut)
            shortcut.register(settings.shortcut)
            // Install the cached presentation before the app lifecycle admits refresh work.
            startupPhase = "show"
            panel?.show()
            refreshLifecycle?.attach(model)
        } catch {
            startupPhase = "failed-" + startupPhase
            showLaunchFailure()
        }
    }

    /// A startup failure must be visible even before a radar panel exists. Reopening brings the same window forward.
    private func showLaunchFailure() {
        if launchFailureWindow == nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("No s'ha pogut obrir Meteocat")
            alert.informativeText = L10n.text("Tanca l'app i torna-la a obrir. Codi: %1$@.", String(describing: startupPhase))
            alert.addButton(withTitle: L10n.text("Tanca l'app"))
            launchFailureAlert = alert
            launchFailureWindow = alert.window
            alert.buttons.first?.target = NSApp
            alert.buttons.first?.action = #selector(NSApplication.terminate(_:))
            launchFailureWindow?.isReleasedWhenClosed = false
            launchFailureWindow?.center()
        }
        AppActivation.request()
        launchFailureWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closing the radar only hides it; the status item, shortcut and menu keep the app useful.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The only reopen route: Raycast, Finder or `open` on the running app always show (never toggle) the same panel.
    /// A visible Settings window does not count as the radar being visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestShow()
        return false
    }

    private func requestShow() {
        if launchFailureWindow != nil { showLaunchFailure(); return }
        guard let panel else { return }
        panel.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        refreshLifecycle?.stop()
        if let settingsObservation { model?.removeSettingsObserver(settingsObservation) }
        settingsObservation = nil
        shortcut.unregister()
        guard let model else { return .terminateNow }
        panel?.hide()
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status item

    private func applyPresence(_ settings: UserSettings) {
        guard !terminating else { return }
        // Establish the status entry before removing the Dock entry.
        if settings.showsInMenuBar { installStatusItem() }
        let policy: NSApplication.ActivationPolicy = settings.showsInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            let accepted = NSApp.setActivationPolicy(policy)
            guard accepted, NSApp.activationPolicy() == policy else {
                installStatusItem()
                let message = LocalizedMessage.text("No s'ha pogut canviar la presència al Dock. La barra de menús continua disponible.")
                model?.presenceErrorToken = message
                return
            }
        }
        model?.presenceErrorToken = nil
        if !settings.showsInMenuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil; statusMenu = nil
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cloud.rain", accessibilityDescription: "Meteocat")
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemPressed() {
        guard let item = statusItem, let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let menu = statusMenu else { return }
            // Let the status item position its pull-down menu beneath the menu bar.
            // Clear it after tracking so left clicks keep their radar action.
            item.menu = menu
            defer { item.menu = nil }
            button.performClick(nil)
        } else {
            // Capture intent before tracking changes ordinary-window ordering.
            let controller = panel
            let hideRadar = controller?.shouldHideForStatusClick() ?? false
            // The status button sends its action from mouse tracking. Activate only after tracking ends.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.terminating else { return }
                    if let controller {
                        guard self.panel === controller else { return }
                        controller.performStatusClick(hidePresentedRadar: hideRadar)
                    } else { self.requestShow() }
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The app menu is hidden while the app has no Dock presence, so About and Help stay reachable here.
        menu.addLocalizedItem(key: "Quant a Meteocat", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("Configuració…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = model != nil
        menu.addItem(settings)
        menu.addLocalizedItem(key: "Dreceres de teclat", action: #selector(showKeyboardShortcuts), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addLocalizedItem(key: "Surt de Meteocat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSettingsAction() { openSettings() }

    /// Independent of the model, so both work during startup and after a launch failure.
    @objc private func showAbout() {
        panel?.cancelPendingActivation()
        AppActivation.request()
        if aboutController == nil { aboutController = AboutWindowController() }
        aboutController?.open(fixtureCapture: model?.fixtureCapture)
    }

    @objc private func showKeyboardShortcuts() {
        panel?.cancelPendingActivation()
        if keyboardShortcutsController == nil { keyboardShortcutsController = KeyboardShortcutsWindowController() }
        keyboardShortcutsController?.open()
    }

    private func openSettings() {
        guard let model, let shortcutRecorder else { return }
        panel?.cancelPendingActivation()
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model, shortcut: shortcut, recorder: shortcutRecorder)
        }
        settingsController?.open()
    }

    /// Standard application and editing commands remain available alongside the status item's options.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addLocalizedItem(key: "Quant a Meteocat", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addLocalizedItem(key: "Configuració…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addLocalizedItem(key: "Surt de Meteocat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = LocalizedMenu.make(key: "Edita")
        edit.addLocalizedItem(key: "Desfés", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addLocalizedItem(key: "Refés", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addLocalizedItem(key: "Retalla", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addLocalizedItem(key: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addLocalizedItem(key: "Enganxa", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addLocalizedItem(key: "Selecciona-ho tot", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addLocalizedItem(key: "Tanca la finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = LocalizedMenu.make(key: "Finestra")
        window.addLocalizedItem(key: "Minimitza", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addLocalizedItem(key: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = window.addLocalizedItem(key: "Pantalla completa", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        window.addItem(.separator())
        window.addLocalizedItem(key: "Porta-ho tot al davant", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        let helpItem = NSMenuItem()
        let help = LocalizedMenu.make(key: "Ajuda")
        help.addLocalizedItem(key: "Dreceres de teclat", action: #selector(showKeyboardShortcuts), keyEquivalent: "").target = self
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }
}

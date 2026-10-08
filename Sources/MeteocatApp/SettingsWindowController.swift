import AppKit
import SwiftUI

/// AppDelegate retains one controller, creates it once, and calls open() for every Settings action.
/// Closing hides the retained window and cancels only acquisition/recording, never persistence tasks.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let session: SettingsSession
    private let model: RadarViewModel
    private let recorder: ShortcutRecorderModel
    private let panes: SettingsTabController
    private var languageObserver: UUID?
    deinit {
        if let token = languageObserver { Task { @MainActor in L10n.state.removeObserver(token) } }
    }

    init(model: RadarViewModel, shortcut: GlobalShortcut, recorder: ShortcutRecorderModel,
         session: SettingsSession? = nil) {
        let session = session ?? SettingsSession(model: model)
        self.session = session; self.model = model; self.recorder = recorder
        panes = SettingsTabController(session: session, recorder: recorder)
        super.init(window: nil)
        panes.tabStyle = .toolbar
        for section in SettingsSession.Section.allCases {
            let host = NSHostingController(rootView: LocalizedSettingsPane(model: model, shortcut: shortcut,
                recorder: recorder, session: session, section: section))
            host.title = section.title
            host.sizingOptions = []
            let item = NSTabViewItem(viewController: host)
            item.identifier = "MeteocatSettingsPane.\(section.rawValue)"
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            panes.addTabViewItem(item)
        }
        panes.selectedTabViewItemIndex = session.section.rawValue
        let window = NSWindow(contentViewController: panes)
        window.styleMask = [.titled, .closable]
        window.collectionBehavior = [.fullScreenNone]
        window.toolbarStyle = .preference
        let contentSize = NSSize(width: 640, height: 480)
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        languageObserver = L10n.state.observe { [weak self] in self?.relocalize() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func relocalize() {
        for (item, section) in zip(panes.tabViewItems, SettingsSession.Section.allCases) {
            item.label = section.title
            item.viewController?.title = section.title
            item.image?.accessibilityDescription = section.title
        }
        if let section = SettingsSession.Section(rawValue: panes.selectedTabViewItemIndex) {
            window?.title = section.title
        }
        for item in window?.toolbar?.items ?? [] {
            if let index = panes.tabViewItems.firstIndex(where: { $0.identifier.map { String(describing: $0) } == item.itemIdentifier.rawValue }),
               let section = SettingsSession.Section(rawValue: index) {
                item.label = section.title; item.paletteLabel = section.title; item.toolTip = section.title
            }
        }
    }
    func open() {
        session.reconcile(model.settings)
        session.select(.general) { recorder.cancel() }
        panes.selectedTabViewItemIndex = SettingsSession.Section.general.rawValue
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivation.request()
        panes.resetScrollPosition()
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        session.close { recorder.cancel() }
    }
}

@MainActor
private final class SettingsTabController: NSTabViewController {
    private let session: SettingsSession
    private let recorder: ShortcutRecorderModel
    init(session: SettingsSession, recorder: ShortcutRecorderModel) {
        self.session = session; self.recorder = recorder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func resetScrollPosition() {
        // AppKit presents the retained hosting view before SwiftUI lays out the grouped Form.
        // Run after that presentation so the document and viewport have their final sizes.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.tabViewItems.indices.contains(self.selectedTabViewItemIndex)
                ? self.tabViewItems[self.selectedTabViewItemIndex] : nil,
                  let view = item.viewController?.view else { return }
            view.layoutSubtreeIfNeeded()
            SettingsScrollPosition.reset(in: view)
        }
    }
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let item = tabViewItem, let index = tabViewItems.firstIndex(of: item),
              let section = SettingsSession.Section(rawValue: index) else { return }
        session.select(section) { recorder.cancel() }
        resetScrollPosition()
    }
}

@MainActor
enum SettingsScrollPosition {
    static func reset(in view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let clip = scroll.contentView
            let y = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            clip.scroll(to: NSPoint(x: document.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            return
        }
        for child in view.subviews { reset(in: child) }
    }
}

/// Read the shared language inside the body, so retained hosts and sheets receive updated environments.
private struct LocalizedSettingsPane: View {
    let model: RadarViewModel
    let shortcut: GlobalShortcut
    let recorder: ShortcutRecorderModel
    let session: SettingsSession
    let section: SettingsSession.Section
    var body: some View {
        SettingsPane(model: model, shortcut: shortcut, recorder: recorder, session: session, section: section)
            .environment(\.locale, L10n.locale)
            .environment(\.layoutDirection, L10n.layoutDirection)
    }
}

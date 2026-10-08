import AppKit
import SwiftUI
import MeteocatCore

/// Data provenance shown in About Meteocat > Sources. Terrain attribution is read from the packaged hillshade's provenance
/// and is omitted when the asset or its provenance is absent.
@MainActor enum Credits {
    static let terrain: String? = {
        let url = MeteocatResources.geographyDirectory.appendingPathComponent("terrain-provenance.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["attribution"] as? String
    }()

    /// Localized at call time. A fixture capture is known only once the model exists.
    static func lines(fixtureCapture: Date?) -> [(text: String, link: URL?)] {
        var lines: [(text: String, link: URL?)] = [
            (L10n.text("Radar: Meteocat"), URL(string: "https://www.meteo.cat")),
            (L10n.text("Límits: ICGC (CC BY 4.0)"), URL(string: "https://www.icgc.cat")),
            (L10n.text("Context: Natural Earth"), URL(string: "https://www.naturalearthdata.com")),
            (L10n.text("Municipis: Idescat."), nil)
        ]
        if let terrain {
            lines.append((terrain, nil))
            lines.append((L10n.text("Relleu: Mapzen Terrain Tiles"), URL(string: "https://registry.opendata.aws/terrain-tiles/")))
        }
        if let fixtureCapture {
            lines.append((L10n.text("Dades de prova desades el %1$@. En aquest mode no es consulten dades noves.",
                Fmt.full(fixtureCapture)), nil))
        }
        return lines
    }
}

/// App menu and status menu > About Meteocat. AppDelegate retains one controller; closing only hides its windows.
/// The card stays short; full provenance lives in a retained Sources window.
@MainActor
final class AboutWindowController: NSWindowController {
    private var languageObserver: UUID?
    private var sourcesWindow: NSWindow?
    private var sourcesHost: NSHostingController<LocalizedSourcesView>?
    private var fixtureCapture: Date?
    deinit {
        if let token = languageObserver { Task { @MainActor in L10n.state.removeObserver(token) } }
    }
    init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let host = NSHostingController(rootView: LocalizedAboutView { [weak self] in self?.showSources() })
        host.sizingOptions = [.standardBounds, .preferredContentSize]
        window.contentViewController = host
        window.center()
        languageObserver = L10n.state.observe { [weak self] in
            // Hidden in the titlebar, still used by the Window menu and VoiceOver.
            self?.window?.title = L10n.text("Quant a Meteocat")
            self?.sourcesWindow?.title = L10n.text("Fonts")
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Fixture mode is decided at startup, so each open refreshes an already existing Sources window too.
    func open(fixtureCapture: Date?) {
        self.fixtureCapture = fixtureCapture
        sourcesHost?.rootView = LocalizedSourcesView(fixtureCapture: fixtureCapture)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func showSources() {
        if sourcesWindow == nil {
            let host = NSHostingController(rootView: LocalizedSourcesView(fixtureCapture: fixtureCapture))
            host.sizingOptions = [.standardBounds, .preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = L10n.text("Fonts")
            window.styleMask = [.titled, .closable]
            window.collectionBehavior = [.fullScreenNone]
            window.isReleasedWhenClosed = false
            window.center()
            sourcesHost = host
            sourcesWindow = window
        }
        sourcesWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct LocalizedAboutView: View {
    let showSources: () -> Void
    var body: some View {
        let _ = L10n.current
        AboutView(showSources: showSources)
            .environment(\.locale, L10n.locale)
            .environment(\.layoutDirection, L10n.layoutDirection)
    }
}

/// A calm, centred card after About This Mac: icon, name, version, one action and the primary data source.
private struct AboutView: View {
    let showSources: () -> Void
    private let info = Bundle.main.infoDictionary ?? [:]
    private var name: String {
        info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Meteocat"
    }
    /// Absent in an unpackaged `swift run` build, where the line is omitted rather than invented.
    private var version: String? {
        guard let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return L10n.text("Versió %1$@ (%2$@)", short, build)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 16)
            if let version {
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            Button(L10n.text("Fonts"), action: showSources)
                .padding(.top, 24)
            Link(L10n.text("Radar: Meteocat"), destination: URL(string: "https://www.meteo.cat")!)
                .font(.footnote)
                .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LocalizedSourcesView: View {
    let fixtureCapture: Date?
    var body: some View {
        let _ = L10n.current
        SourcesView(lines: Credits.lines(fixtureCapture: fixtureCapture))
            .environment(\.locale, L10n.locale)
            .environment(\.layoutDirection, L10n.layoutDirection)
    }
}

/// Full provenance as readable, leading-aligned prose. Linked lines open in the default browser.
private struct SourcesView: View {
    let lines: [(text: String, link: URL?)]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                Group {
                    if let link = line.link {
                        Link(line.text, destination: link)
                    } else {
                        Text(line.text).textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Help > Keyboard Shortcuts. AppDelegate retains one controller; closing only hides the window.
@MainActor
final class KeyboardShortcutsWindowController: NSWindowController {
    private var languageObserver: UUID?
    deinit {
        if let token = languageObserver { Task { @MainActor in L10n.state.removeObserver(token) } }
    }
    init() {
        let host = NSHostingController(rootView: LocalizedKeyboardShortcutsView())
        let window = NSWindow(contentViewController: host)
        window.title = L10n.text("Dreceres de teclat")
        window.styleMask = [.titled, .closable]
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        languageObserver = L10n.state.observe { [weak self] in
            self?.window?.title = L10n.text("Dreceres de teclat")
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivation.request()
    }
}

private struct LocalizedKeyboardShortcutsView: View {
    var body: some View {
        let _ = L10n.current
        KeyboardShortcutsView()
            .environment(\.locale, L10n.locale)
            .environment(\.layoutDirection, L10n.layoutDirection)
    }
}

/// The radar's fixed keys, as handled by PanelKeys. The editable global shortcut stays in Settings.
private struct KeyboardShortcutsView: View {
    var body: some View {
        Form {
            key(L10n.text("Reprodueix o pausa"), L10n.text("Espai"))
            key(L10n.text("Fotograma anterior o següent"), "←", "→")
            key(L10n.text("Mostra o amaga les ciutats"), "L")
            key(L10n.text("Refresca les dades"), "⌘R")
            key(L10n.text("Mida del radar"), "⌘+", "⌘−", "⌘0")
            key(L10n.text("Configuració"), "⌘,")
        }
        .formStyle(.columns)
        .padding(20)
        .fixedSize()
    }
    private func key(_ title: String, _ values: String...) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

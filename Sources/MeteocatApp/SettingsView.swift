import AppKit
import SwiftUI
import MeteocatCore

/// Editable text for one city. Untouched coordinates keep their exact original values on save.
struct CityDraft: Identifiable, Equatable {
    var id: String
    var name: String
    var lon: String
    var lat: String
    var visible: Bool
    var original: GeoPoint?

    init(_ city: City) {
        id = city.id; name = city.name; visible = city.visible; original = city.point
        lon = CoordinateText.format(city.point.lon); lat = CoordinateText.format(city.point.lat)
    }
    init(newAt point: GeoPoint) {
        id = "user:\(UUID().uuidString.lowercased())"; name = L10n.text("Nova ciutat"); visible = true; original = point
        lon = CoordinateText.format(point.lon); lat = CoordinateText.format(point.lat)
    }
}

/// Same constraints as SettingsStore.validate, checked before saving so errors appear next to the field.
struct CoordinateValidationError: Error { let message: LocalizedMessage }

enum CoordinateText {
    static func format(_ value: Double) -> String { String(format: "%.5f", value) }

    static func parse(lon: String, lat: String, original: GeoPoint?, projection: MapProjection) -> Result<GeoPoint, CoordinateValidationError> {
        func number(_ text: String, _ exact: Double?) -> Double? {
            if let exact, text == format(exact) { return exact }
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let x = number(lon, original?.lon), let y = number(lat, original?.lat), x.isFinite, y.isFinite else {
            return .failure(CoordinateValidationError(message: .text("Cal una longitud i una latitud numèriques.")))
        }
        let point = GeoPoint(lon: x, lat: y)
        guard let p = try? projection.project(point), (0...680).contains(p.x), (0...380).contains(p.y) else {
            return .failure(CoordinateValidationError(message: .text("El punt queda fora del mapa.")))
        }
        return .success(point)
    }

    static func cities(_ drafts: [CityDraft], projection: MapProjection) -> (cities: [City]?, errors: [String: LocalizedMessage]) {
        var errors = [String: LocalizedMessage](), cities = [City]()
        for draft in drafts {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.id.isEmpty, draft.id.count <= 80, !draft.id.contains(where: { $0.isWhitespace }) else {
                errors[draft.id] = .text("Identificador de ciutat no vàlid."); continue
            }
            guard (1...40).contains(name.count), !draft.name.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
                errors[draft.id] = .text("El nom ha de tenir entre 1 i 40 caràcters."); continue
            }
            switch parse(lon: draft.lon, lat: draft.lat, original: draft.original, projection: projection) {
            case .success(let point): cities.append(City(id: draft.id, name: name, point: point, visible: draft.visible))
            case .failure(let error): errors[draft.id] = error.message
            }
        }
        if drafts.count > 60 { errors["_"] = .text("Com a màxim hi pot haver 60 ciutats.") }
        if Set(drafts.map(\.id)).count != drafts.count { errors["_"] = .text("Hi ha identificadors repetits.") }
        return (errors.isEmpty ? cities : nil, errors)
    }
}

struct SettingsPane: View {
    let model: RadarViewModel
    let shortcut: GlobalShortcut
    let recorder: ShortcutRecorderModel
    let session: SettingsSession
    let section: SettingsSession.Section
    var body: some View {
        Group {
            switch section {
            case .general: SettingsGeneralPane(model: model, shortcut: shortcut, recorder: recorder, session: session)
            case .map: SettingsMapPane(session: session)
            case .location: SettingsLocationPane(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.settings) { _, settings in session.reconcile(settings) }
    }
}

/// Compact macOS form row: notes and errors stay under their control in the trailing column.
private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsGeneralPane: View {
    let model: RadarViewModel
    let shortcut: GlobalShortcut
    let recorder: ShortcutRecorderModel
    let session: SettingsSession
    var body: some View {
        ScrollView {
            generalForm
        }
    }
    private var generalForm: some View {
        Form {
            if let notice = model.recoveryNotice {
                Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(L10n.text("Idioma")) {
                Picker(L10n.text("Idioma"), selection: Binding(get: { _ = L10n.current; return L10n.preference }, set: { L10n.setPreference($0) })) {
                    Text(L10n.text("Segueix el sistema")).tag("")
                    Divider()
                    ForEach(L10n.supportedLanguages, id: \.self) { language in
                        Text(AppLanguagePreference.names[language] ?? language).tag(language)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(L10n.text("Aparença")) {
                Picker(L10n.text("Aparença"), selection: Binding(get: { session.appearance }, set: { session.setAppearance($0) })) {
                    Text(L10n.text("Automàtica")).tag(AppAppearance.automatic)
                    Divider()
                    Text(L10n.text("Clara")).tag(AppAppearance.light)
                    Text(L10n.text("Fosca")).tag(AppAppearance.dark)
                }
                .labelsHidden().fixedSize()
                .disabled(session.appearancePending)
                SettingsNote(L10n.text("Automàtica segueix l'aparença del sistema."))
                if session.appearancePending { ProgressView(L10n.text("Desant…")).controlSize(.small) }
                if let message = session.appearanceMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            SettingsRow(L10n.text("Presència")) {
                Toggle(L10n.text("Mostra al Dock"), isOn: Binding(get: { session.showsInDock }, set: { session.setShowsInDock($0) }))
                    .disabled(session.dockOptionDisabled)
                Toggle(L10n.text("Mostra a la barra de menús"), isOn: Binding(get: { session.showsInMenuBar }, set: { session.setShowsInMenuBar($0) }))
                    .disabled(session.menuBarOptionDisabled)
                SettingsNote(L10n.text("Cal mantenir visible una de les dues opcions."))
                if session.presencePending { ProgressView(L10n.text("Desant…")).controlSize(.small) }
                if let message = session.presenceMessage ?? model.presenceError {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .toggleStyle(.checkbox)
            ShortcutRecorder(model: model, shortcut: shortcut, recorder: recorder)
        }
        .formStyle(.columns)
        .padding(.horizontal, 32).padding(.vertical, 24)
    }
}

private struct SettingsMapPane: View {
    @Bindable var session: SettingsSession
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle(L10n.text("Mostra les ciutats al mapa"), isOn: Binding(get: { session.labelsVisible }, set: { session.setLabels($0) }))
                    .disabled(session.labelsPending)
                Spacer()
                CitySearchField(text: $session.search, placeholder: L10n.text("Cerca"), accessibilityLabel: L10n.text("Cerca ciutats"), direction: L10n.layoutDirection).frame(width: 200)
                    .disabled(!session.labelsVisible || session.labelsPending)
            }
            Table(session.filteredCities, selection: $session.selection) {
                TableColumn("") { city in
                    Toggle(L10n.text("Mostra %1$@", String(describing: city.name)), isOn: Binding(get: {
                        session.cities.first(where: { $0.id == city.id })?.visible ?? false
                    }, set: { session.setVisible($0, id: city.id) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(session.citiesLocked)
                }.width(28)
                TableColumn(L10n.text("Ciutat")) { city in Text(city.name) }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if session.filteredCities.isEmpty {
                    ContentUnavailableView(session.cities.isEmpty ? L10n.text("Cap ciutat") : L10n.text("Cap resultat"),
                        systemImage: session.cities.isEmpty ? "mappin.slash" : "magnifyingglass",
                        description: Text(session.cities.isEmpty ? L10n.text("Afegeix una ciutat") : L10n.text("Cap ciutat coincideix amb \"%1$@\".", String(describing: session.search))))
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button(L10n.text("Edita…")) { if let id = ids.first { session.beginEdit(id) } }.disabled(!session.labelsVisible || session.labelsPending || ids.count != 1 || session.citiesLocked)
                Button(L10n.text("Esborra")) { session.selection = ids; session.deleteSelection() }.disabled(!session.labelsVisible || session.labelsPending || ids.isEmpty || session.citiesLocked)
            } primaryAction: { ids in
                if session.labelsVisible, !session.labelsPending, !session.citiesLocked,
                   ids.count == 1, let id = ids.first { session.beginEdit(id) }
            }
            .onDeleteCommand {
                guard session.labelsVisible, !session.labelsPending else { return }
                session.deleteSelection()
            }
            .disabled(!session.labelsVisible || session.labelsPending || session.citiesLocked)
            HStack(spacing: 8) {
                Button { session.beginAdd() } label: { Image(systemName: "plus") }
                    .help(L10n.text("Afegeix una ciutat")).accessibilityLabel(L10n.text("Afegeix una ciutat"))
                    .disabled(session.citiesLocked || session.cities.count >= 60)
                Button { session.deleteSelection() } label: { Image(systemName: "minus") }
                    .help(L10n.text("Elimina les ciutats seleccionades")).accessibilityLabel(L10n.text("Elimina les ciutats seleccionades"))
                    .disabled(session.citiesLocked || session.selection.isEmpty)
                Button(L10n.text("Edita…")) { if let id = session.selection.first { session.beginEdit(id) } }
                    .disabled(session.citiesLocked || session.selection.count != 1)
                Spacer()
            }
            .disabled(!session.labelsVisible || session.labelsPending)
            if session.citiesPending { ProgressView(L10n.text("Desant…")).controlSize(.small) }
            if let message = session.labelsMessage { Text(message).foregroundStyle(.red).font(.callout) }
            if let message = session.cityValidation.errors.values.first?.rendered ?? session.citiesMessage {
                HStack {
                    Text(message).foregroundStyle(.red).font(.callout)
                    if session.canRetryCities {
                        Button(L10n.text("Torna-ho a provar")) { session.saveCities() }.disabled(session.citiesPending)
                    }
                }
            }
        }
        .padding(20)
        .sheet(item: $session.editor) { copy in
            CityEditorSheet(copy: copy, projection: session.projection) { session.accept($0) }
        }
    }
}

private struct CityEditorSheet: View {
    @State private var copy: SettingsSession.CityEditor
    @State private var message: LocalizedMessage?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    let projection: MapProjection
    let accept: (SettingsSession.CityEditor) -> LocalizedMessage?
    init(copy: SettingsSession.CityEditor, projection: MapProjection, accept: @escaping (SettingsSession.CityEditor) -> LocalizedMessage?) {
        _copy = State(initialValue: copy); self.projection = projection; self.accept = accept
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy.existingID == nil ? L10n.text("Nova ciutat") : L10n.text("Edita la ciutat")).font(.headline)
            Form {
                TextField(L10n.text("Nom"), text: $copy.draft.name).focused($nameFocused)
                TextField(L10n.text("Latitud"), text: $copy.draft.lat).monospacedDigit()
                TextField(L10n.text("Longitud"), text: $copy.draft.lon).monospacedDigit()
                Toggle(L10n.text("Mostra al mapa"), isOn: $copy.draft.visible)
                Text(L10n.text("Graus decimals (WGS84).")).font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message.rendered).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.text("Cancel·la")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("D'acord")) {
                    message = accept(copy)
                    if message == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { nameFocused = true }
    }
}

private struct SettingsLocationPane: View {
    @Bindable var session: SettingsSession
    var body: some View {
        ScrollView {
            locationForm
        }
    }
    private var locationForm: some View {
        Form {
            SettingsRow(L10n.text("Punt desat")) {
                HStack {
                    Text(session.savedPin.map { "\(CoordinateText.format($0.lat)), \(CoordinateText.format($0.lon))" } ?? L10n.text("Cap"))
                        .foregroundStyle(.secondary).monospacedDigit()
                    if session.savedPin != nil {
                        Button(L10n.text("Esborra"), role: .destructive) { session.removePin() }.disabled(session.pinLocked)
                    }
                }
                SettingsNote(L10n.text("Es mostra com un punt blau al mapa del radar."))
            }
            SettingsRow(L10n.text("Latitud")) { coordinateField(L10n.text("Latitud"), text: $session.pinLat) }
            SettingsRow(L10n.text("Longitud")) { coordinateField(L10n.text("Longitud"), text: $session.pinLon) }
            SettingsRow(L10n.text("Ubicació")) {
                HStack {
                    Button { session.acquireLocation() } label: { Label(L10n.text("Usa la ubicació actual"), systemImage: "location") }
                        .disabled(session.pinLocked)
                        .accessibilityHint(L10n.text("Consulta i desa el punt automàticament si és vàlid."))
                    if session.locator.isPending {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Consultant la ubicació…")).foregroundStyle(.secondary)
                    }
                }
                SettingsNote(L10n.text("Els canvis vàlids es desen automàticament. La ubicació actual es consulta un sol cop."))
                if case .failed(let message) = session.locator.state { Text(message.rendered).foregroundStyle(.red).font(.callout) }
                if session.pinPending { ProgressView(L10n.text("Desant…")).controlSize(.small) }
                if let message = session.pinMessage ?? pinValidationMessage {
                    HStack {
                        Text(message).foregroundStyle(.red).font(.callout)
                        if session.canRetryPin {
                            Button(L10n.text("Torna-ho a provar")) { session.retryPin() }.disabled(session.pinPending)
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(.horizontal, 32).padding(.vertical, 24)
    }
    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).labelsHidden().monospacedDigit().frame(width: 140)
            .disabled(session.locator.isPending)
    }
    private var pinValidationMessage: String? {
        guard !session.pinLon.isEmpty || !session.pinLat.isEmpty else { return nil }
        if case .failure(let error) = session.pinResult { return error.message.rendered }
        return nil
    }
}

private struct CitySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let direction: LayoutDirection
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder; field.setAccessibilityLabel(accessibilityLabel)
        field.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.isEnabled = isEnabled
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CitySearchField
        init(_ parent: CitySearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { searchChanged(field) }
        }
        @objc func searchChanged(_ field: NSSearchField) { parent.text = field.stringValue }
        func searchFieldDidEndSearching(_ sender: NSSearchField) { searchChanged(sender) }
    }
}

/// Owns the recorder's whole lifecycle, outlives the Settings view, and keeps every registration change inside one
/// settings transaction. `pending` is set synchronously before the transaction's Task, so no new recording or reset
/// can start (and capture a stale registration) until the commit or rollback has finished. Each recording session has
/// a generation; cancel and onDisappear only restore the session that is still current.
@MainActor @Observable
final class ShortcutRecorderModel {
    enum Phase: Equatable { case idle, recording(generation: Int), pending }
    private(set) var phase = Phase.idle
    private var messageToken: LocalizedMessage?
    var message: String? { messageToken?.rendered }

    @ObservationIgnored private let model: RadarViewModel
    @ObservationIgnored private let shortcut: GlobalShortcut
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previous: Shortcut?
    @ObservationIgnored private var monitor: Any?

    init(model: RadarViewModel, shortcut: GlobalShortcut) { self.model = model; self.shortcut = shortcut }

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    /// Unregisters the current hotkey so pressing it records it instead of toggling the panel. Refused unless idle.
    @discardableResult
    func start(monitorKeys: Bool = true) -> Int? {
        guard phase == .idle else { return nil }
        generation += 1
        let session = generation
        previous = shortcut.registered
        shortcut.unregister()
        phase = .recording(generation: session)
        messageToken = .text("Inclou ⌘, ⌥ o ⌃. Esc cancel·la.")
        if monitorKeys {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let shouldForward = MainActor.assumeIsolated {
                    if Self.forwardsNavigation(keyCode: event.keyCode, flags: event.modifierFlags) {
                        self?.cancel(session: session)
                        return true
                    }
                    self?.handle(event, session: session)
                    return false
                }
                return shouldForward ? event : nil
            }
        }
        return session
    }

    /// Plain Tab/Shift-Tab and Cmd-W leave the recorder and continue through native focus/close handling.
    static func forwardsNavigation(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        return (keyCode == 48 && (modifiers.isEmpty || modifiers == .shift))
            || (keyCode == 13 && modifiers == .command)
    }

    private func handle(_ event: NSEvent, session: Int) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { cancel(session: session); return }
        guard !flags.intersection([.command, .option, .control]).isEmpty else { messageToken = .text("Cal incloure ⌘, ⌥ o ⌃."); return }
        finish(session: session, with: Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: ShortcutText.carbonModifiers(flags)))
    }

    /// Restores the registration captured when this session started. Nothing can have committed since: starting
    /// requires idle and recording blocks every other shortcut transaction.
    func cancel(session: Int? = nil) {
        guard case .recording(let current) = phase, session == nil || session == current else { return }
        removeMonitor()
        phase = .idle
        if let previous { shortcut.register(previous) }
        messageToken = nil
    }

    func finish(session: Int, with new: Shortcut) {
        guard phase == .recording(generation: session) else { return }
        removeMonitor()
        commit(new, rollback: previous)
    }

    func reset() {
        guard phase == .idle else { return }
        commit(.defaultShortcut, rollback: shortcut.registered)
    }

    /// Register, persist and roll back as one serialized settings transaction. Returns once it has finished.
    @discardableResult
    func commit(_ new: Shortcut, rollback: Shortcut?) -> Task<Void, Never> {
        phase = .pending
        return Task {
            let failure = await model.serialized { [shortcut, model] in
                await shortcut.change(to: new, previous: shortcut.registered ?? rollback) { value in
                    await model.commit { $0.shortcut = value }
                }
            }
            messageToken = failure ?? .key("Drecera desada: %1$@.", [.shortcut(new)])
            phase = .idle
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ShortcutRecorder: View {
    let model: RadarViewModel
    let shortcut: GlobalShortcut
    let recorder: ShortcutRecorderModel

    var body: some View {
        let phase = recorder.phase
        SettingsRow(L10n.text("Drecera global")) {
            Button(recorder.isRecording ? L10n.text("Prem la combinació…") : ShortcutText.string(model.settings.shortcut)) {
                if recorder.isRecording { recorder.cancel() } else { recorder.start() }
            }
            .disabled(phase == .pending)
            .accessibilityLabel(recorder.isRecording ? L10n.text("Cancel·la el canvi de drecera") : L10n.text("Edita la drecera global: %1$@", String(describing: ShortcutText.string(model.settings.shortcut))))
            .accessibilityHint(recorder.isRecording ? L10n.text("Esc cancel·la") : L10n.text("Defineix una drecera nova"))
            SettingsNote(L10n.text("Mostra o amaga el radar"))
            if let error = shortcut.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            if let message = recorder.message { SettingsNote(message) }
        }
        .onDisappear { recorder.cancel() }
    }
}

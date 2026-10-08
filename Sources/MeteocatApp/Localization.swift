import Foundation
import SwiftUI
import Observation
import MeteocatCore

/// Shared language presentation state; domain identity never depends on the language.
/// Domain objects, coordinates, frame identities and stored timestamps never depend on this language.
enum L10n {
    static let supportedLanguages = ["ca", "oc", "es", "eu", "gl", "en", "fr", "de", "it", "pt", "nl", "ro", "ar", "zgh", "ur", "zh-Hans", "uk", "ru", "pl", "pa", "bn"]
    static let state = LanguageState()
    static var current: AppLocalization { state.snapshot }
    @MainActor static var preference: String { state.preference }
    @MainActor static func setPreference(_ language: String, defaults: UserDefaults = .standard) {
        guard language.isEmpty || supportedLanguages.contains(language) else { return }
        defaults.set(language, forKey: AppLanguagePreference.key)
        // An explicit choice during this run supersedes launch arguments. Follow System still uses macOS preferences.
        let preferences = language.isEmpty ? AppLanguagePreference.systemPreferences(defaults: defaults) : [language]
        state.install(AppLocalization(bundle: current.resourceBundle, preferences: preferences), preference: language)
    }
    static var locale: Locale { current.locale }
    static var layoutDirection: LayoutDirection { current.isRightToLeft ? .rightToLeft : .leftToRight }
    static func text(_ key: String, _ arguments: String...) -> String { current.text(key, arguments: arguments) }

    /// Known Core notices are localized at the UI boundary. Unknown technical diagnostics stay intact,
    /// preceded by a localized explanation rather than modifying Core's persistence/error semantics.
    static func coreMessage(_ message: String) -> String {
        if current.hasKey(message) { return text(message) }
        let prefix = "Meteocat ha retornat un error HTTP "
        let suffix = ". Es conserva el radar complet."
        if message.hasPrefix(prefix), message.hasSuffix(suffix) {
            let code = String(message.dropFirst(prefix.count).dropLast(suffix.count))
            if !code.isEmpty, code.allSatisfy(\.isNumber) {
                return text("Meteocat ha retornat un error HTTP %1$@. Es conserva el radar complet.", code)
            }
        }
        return text("No s'ha pogut completar l'operació. Detall tècnic: %1$@", message)
    }
}

struct AppLocalization: Sendable {
    let resourceBundle: Bundle
    let language: String
    let locale: Locale
    private let localizedBundle: Bundle
    private let fallbackBundle: Bundle

    init(bundle: Bundle, preferences: [String]) {
        resourceBundle = bundle
        let resolvedLanguage = Self.resolve(preferences: preferences, available: bundle.localizations)
        language = resolvedLanguage
        locale = Locale(identifier: resolvedLanguage)
        fallbackBundle = bundle.path(forResource: "ca", ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        localizedBundle = bundle.path(forResource: bundle.localizations.first { $0.lowercased() == resolvedLanguage.lowercased() } ?? resolvedLanguage, ofType: "lproj").flatMap(Bundle.init(path:)) ?? fallbackBundle
    }

    /// Ask Foundation to match variants/scripts, one explicit preference at a time. A sentinel detects
    /// Foundation's implicit English fallback so unsupported preferences ultimately fall back to Catalan.
    static func resolve(preferences: [String], available: [String]) -> String {
        let normalized = Set(available.map { $0.replacingOccurrences(of: "_", with: "-").lowercased() })
        let languages = L10n.supportedLanguages.filter { normalized.contains($0.lowercased()) }
        let sentinel = "zz"
        for preference in preferences {
            let match = Bundle.preferredLocalizations(from: [sentinel] + languages,
                forPreferences: [preference, sentinel]).first
            if let match, languages.contains(match) { return match }
        }
        return "ca"
    }

    /// Localized names and date order, with the same Gregorian calendar and Madrid zone as the radar.
    func dateFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Europe/Madrid")!
        formatter.setLocalizedDateFormatFromTemplate(template)
        if language == "oc" {
            // CLDR oc uses Languedoc names. These Aranese forms were checked against Gencat/Conselh Generau.
            let weekdays = ["dimenge", "deluns", "dimars", "dimèrcles", "dijaus", "diuendres", "dissabte"]
            let months = ["gèr", "hereuèr", "març", "abriu", "mai", "junh", "junhsèga", "agost", "seteme", "octobre", "noveme", "deseme"]
            formatter.weekdaySymbols = weekdays
            formatter.standaloneWeekdaySymbols = weekdays
            formatter.dateFormat = template.contains("yyyy") ? "EEEE, d MMMM 'de' yyyy, HH:mm" : "EEEE, d MMMM"
            formatter.monthSymbols = months.map { ["abriu", "agost", "octobre"].contains($0) ? "d'" + $0 : "de " + $0 }
            formatter.standaloneMonthSymbols = months
        }
        return formatter
    }

    var isRightToLeft: Bool { language == "ar" || language == "ur" }
    func hasKey(_ key: String) -> Bool {
        fallbackBundle.localizedString(forKey: key, value: "__missing__", table: "Localizable") != "__missing__"
    }
    func text(_ key: String, arguments: [String] = []) -> String {
        let fallback = fallbackBundle.localizedString(forKey: key, value: key, table: "Localizable")
        let format = localizedBundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments.map { $0 as CVarArg })
    }
}

/// An app-specific override leaves macOS language preferences intact.
enum AppLanguagePreference {
    static let key = "MeteocatPreferredLanguage"
    static let names = ["ca": "Català", "oc": "Aranés", "es": "Castellano", "eu": "Euskara", "gl": "Galego",
        "en": "English", "fr": "Français", "de": "Deutsch", "it": "Italiano", "pt": "Português", "nl": "Nederlands",
        "ro": "Română", "ar": "العربية", "zgh": "ⵜⴰⵎⴰⵣⵉⵖⵜ", "ur": "اردو", "zh-Hans": "简体中文", "uk": "Українська",
        "ru": "Русский", "pl": "Polski", "pa": "ਪੰਜਾਬੀ", "bn": "বাংলা"]

    static func preferences(defaults: UserDefaults) -> [String] {
        if let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String] {
            return arguments
        }
        if let language = defaults.string(forKey: key), L10n.supportedLanguages.contains(language) {
            return [language]
        }
        return systemPreferences(defaults: defaults)
    }
    static func systemPreferences(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    }
}

/// The snapshot is immutable after construction. Its only mutable storage is protected by the lock;
/// callbacks and preference writes are confined to the main actor. Background diagnostics can safely read it.
final class LanguageState: Observable, @unchecked Sendable {
    private let lock = NSLock()
    private let registrar = ObservationRegistrar()
    private var storedSnapshot = AppLocalization(bundle: .module,
        preferences: AppLanguagePreference.preferences(defaults: .standard))
    @MainActor private(set) var preference = UserDefaults.standard.string(forKey: AppLanguagePreference.key) ?? ""
    @MainActor private var observers: [UUID: @MainActor () -> Void] = [:]
    var snapshot: AppLocalization {
        registrar.access(self, keyPath: \.snapshot)
        lock.lock(); defer { lock.unlock() }
        return storedSnapshot
    }
    @MainActor func install(_ snapshot: AppLocalization, preference: String) {
        self.preference = preference
        registrar.withMutation(of: self, keyPath: \.snapshot) {
            lock.lock(); defer { lock.unlock() }
            storedSnapshot = snapshot
        }
        for callback in Array(observers.values) { callback() }
    }
    @MainActor func observe(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; callback(); return id
    }
    @MainActor func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

/// Store a recipe, never a translation. Equality describes the message's identity, independent of language.
enum LocalizedMessage: Equatable {
    enum Argument: Equatable {
        case text(String), shortcut(Shortcut)
        var rendered: String { switch self { case .text(let text): text; case .shortcut(let shortcut): ShortcutText.string(shortcut) } }
    }
    case key(String, [Argument])
    case core(String)
    static func text(_ key: String, _ arguments: String...) -> Self { .key(key, arguments.map(Argument.text)) }
    var rendered: String {
        switch self {
        case .key(let key, let arguments): L10n.current.text(key, arguments: arguments.map(\.rendered))
        case .core(let diagnostic): L10n.coreMessage(diagnostic)
        }
    }
}

@MainActor enum LocalizedMenu {
    static func make(key: String) -> NSMenu {
        let menu = NSMenu(title: L10n.text(key)); menu.identifier = NSUserInterfaceItemIdentifier(key); return menu
    }
    static func retitle(_ menu: NSMenu) {
        if let key = menu.identifier?.rawValue, L10n.current.hasKey(key) { menu.title = L10n.text(key) }
        for item in menu.items {
            if let key = item.identifier?.rawValue, L10n.current.hasKey(key) { item.title = L10n.text(key) }
            if let submenu = item.submenu {
                retitle(submenu)
                if let key = submenu.identifier?.rawValue, L10n.current.hasKey(key) { item.title = L10n.text(key) }
            }
        }
    }
}

@MainActor extension NSMenu {
    @discardableResult func addLocalizedItem(key: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = addItem(withTitle: L10n.text(key), action: action, keyEquivalent: keyEquivalent)
        item.identifier = NSUserInterfaceItemIdentifier(key)
        return item
    }
}

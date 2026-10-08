import XCTest
import Foundation
import MeteocatCore
@testable import MeteocatApp

final class LocalizationTests: XCTestCase {
    func testAppOverridePersistsAndSystemOptionRestoresMacOSPreferences() throws {
        let suite = "MeteocatLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["fr-CA", "en"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), ["fr-CA", "en"])
        for language in L10n.supportedLanguages {
            defaults.set(language, forKey: AppLanguagePreference.key)
            XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), [language])
            XCTAssertNotNil(AppLanguagePreference.names[language])
        }
        defaults.set("", forKey: AppLanguagePreference.key)
        XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), ["fr-CA", "en"])
        defaults.set("unsupported", forKey: AppLanguagePreference.key)
        XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), ["fr-CA", "en"])
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr-CA", "en"])
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        defaults.set("ca", forKey: AppLanguagePreference.key)
        defaults.setVolatileDomain(["AppleLanguages": ["ar"]], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(AppLanguagePreference.preferences(defaults: defaults), ["ar"])
        XCTAssertEqual(defaults.string(forKey: AppLanguagePreference.key), "ca")
    }

    func testPreferenceOrderVariantsScriptsAndCatalanFallback() {
        let all = L10n.supportedLanguages
        for language in all {
            XCTAssertEqual(AppLocalization.resolve(preferences: [language], available: all), language)
        }
        XCTAssertEqual(AppLocalization.resolve(preferences: ["en-GB"], available: all), "en")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["ur-PK"], available: all), "ur")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["zh-CN"], available: all), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["xx", "fr-CA", "en"], available: all), "fr")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["xx"], available: all), "ca")
        XCTAssertEqual(AppLocalization.resolve(preferences: [], available: all), "ca")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["en"], available: ["ca"]), "ca")
        XCTAssertEqual(AppLocalization.resolve(preferences: ["zh-CN"], available: ["ca", "zh-hans"]), "zh-Hans")
    }

    func testExplicitBundleResourcesAndStringPlaceholders() throws {
        let bundle = L10n.current.resourceBundle
        XCTAssertEqual(Set(bundle.localizations.filter { $0.lowercased() != "base" }.map { $0.lowercased() }), Set(L10n.supportedLanguages.map { $0.lowercased() }))
        let english = AppLocalization(bundle: bundle, preferences: ["en"])
        let catalan = AppLocalization(bundle: bundle, preferences: ["ca"])
        XCTAssertEqual(english.text("Configuració"), "Settings")
        XCTAssertEqual(catalan.text("Configuració"), "Configuració")
        XCTAssertEqual(english.text("Observació · %1$@ · %2$@", arguments: ["08:15", "12"]),
                       "Observation · 08:15 · 12")
        XCTAssertEqual(catalan.text("Observació · %1$@ · %2$@", arguments: ["08:15", "12"]),
                       "Observació · 08:15 · 12")
        // A missing key remains readable, and an unavailable language uses the Catalan resource.
        XCTAssertEqual(AppLocalization(bundle: bundle, preferences: ["xx"]).text("Configuració"), "Configuració")
        XCTAssertEqual(english.text("Unknown diagnostic"), "Unknown diagnostic")
        let fallbackDirectory = try XCTUnwrap(bundle.url(forResource: "ca", withExtension: "lproj"))
        let fallback = try XCTUnwrap(NSDictionary(contentsOf: fallbackDirectory.appendingPathComponent("Localizable.strings")) as? [String: String])
        for language in bundle.localizations where language != "Base" {
            let directory = try XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"))
            let strings = try XCTUnwrap(NSDictionary(contentsOf: directory.appendingPathComponent("Localizable.strings")) as? [String: String])
            XCTAssertEqual(Set(strings.keys), Set(fallback.keys), language)
            let localization = AppLocalization(bundle: bundle, preferences: [language])
            for (key, value) in strings {
                let expression = try NSRegularExpression(pattern: "%[0-9]+\\$@")
                func placeholders(_ text: String) -> [String] {
                    expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                        .map { (text as NSString).substring(with: $0.range) }.sorted()
                }
                XCTAssertEqual(placeholders(key), placeholders(value), "\(language): \(key)")
            }
            let permission = try XCTUnwrap(NSDictionary(contentsOf: directory.appendingPathComponent("InfoPlist.strings")) as? [String: String])
            let description = try XCTUnwrap(permission["NSLocationUsageDescription"])
            XCTAssertTrue(description.contains(localization.text("Usa la ubicació actual")), language)
        }
        let chinese = AppLocalization(bundle: bundle, preferences: ["zh-CN"])
        if bundle.localizations.contains(where: { $0.lowercased() == "zh-hans" }) {
            XCTAssertEqual(chinese.language, "zh-Hans")
            XCTAssertNotEqual(chinese.text("Configuració"), "Configuració")
        }
    }

    func testKnownCoreNoticesHTTPCodeAndUnknownTechnicalDetails() {
        let notice = "La previsió ha caducat. Es mostra l'última observació."
        XCTAssertEqual(L10n.coreMessage(notice), L10n.text(notice))
        let result = L10n.coreMessage("Meteocat ha retornat un error HTTP 503. Es conserva el radar complet.")
        XCTAssertTrue(result.contains("503"))
        XCTAssertFalse(result.contains("%1$@"))
        let technical = "PNG CRC mismatch at chunk IDAT"
        XCTAssertTrue(L10n.coreMessage(technical).contains(technical))
    }

    func testRTLUsesAppLanguage() {
        let bundle = L10n.current.resourceBundle
        for language in ["ar", "ur"] {
            XCTAssertTrue(AppLocalization(bundle: bundle, preferences: [language]).isRightToLeft)
        }
        for language in ["ca", "en", "zgh", "pa", "bn", "zh-Hans"] {
            XCTAssertFalse(AppLocalization(bundle: bundle, preferences: [language]).isRightToLeft)
        }
    }

    func testRelocatedResourceBundleStillResolvesTranslations() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("meteocat-localization-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let relocatedURL = temporary.appendingPathComponent("MeteocatNative_MeteocatApp.bundle")
        try FileManager.default.copyItem(at: L10n.current.resourceBundle.bundleURL, to: relocatedURL)
        let relocated = try XCTUnwrap(Bundle(url: relocatedURL))
        XCTAssertEqual(AppLocalization(bundle: relocated, preferences: ["en"]).text("Configuració"), "Settings")
        XCTAssertEqual(AppLocalization(bundle: relocated, preferences: ["xx"]).text("Configuració"), "Configuració")
    }

    func testDateLanguageAndAraneseSymbols() throws {
        let bundle = L10n.current.resourceBundle
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z"))
        let english = AppLocalization(bundle: bundle, preferences: ["en"])
        XCTAssertTrue(english.dateFormatter(template: "EEEEdMMMM").string(from: date).contains("July"))
        if bundle.localizations.contains("oc") {
            let aranese = AppLocalization(bundle: bundle, preferences: ["oc"])
            let value = aranese.dateFormatter(template: "EEEEdMMMM").string(from: date)
            XCTAssertEqual(value, "dimèrcles, 8 de junhsèga")
            XCTAssertEqual(aranese.dateFormatter(template: "EEEEdMMMMyyyyHHmm").string(from: date), "dimèrcles, 8 de junhsèga de 2026, 14:00")
            let autumn = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T04:00:00Z"))
            XCTAssertEqual(aranese.dateFormatter(template: "EEEEdMMMM").string(from: autumn), "dissabte, 3 d'octobre")
        }
    }

    @MainActor func testDatesKeepMadridDSTAndForecastIdentity() throws {
        let iso = ISO8601DateFormatter()
        let summer = try XCTUnwrap(iso.date(from: "2026-10-25T00:30:00Z"))
        let winter = try XCTUnwrap(iso.date(from: "2026-10-25T01:30:00Z"))
        XCTAssertEqual(Fmt.timeParts(summer).digits, "02:30")
        XCTAssertEqual(Fmt.timeParts(winter).digits, "02:30")
        XCTAssertFalse(Fmt.timeParts(summer).zone.isEmpty)
        XCTAssertNotEqual(Fmt.timeParts(summer).zone, Fmt.timeParts(winter).zone)
        let origin = try XCTUnwrap(iso.date(from: "2026-10-08T21:54:00Z"))
        let valid = origin.addingTimeInterval(360)
        let id = try FrameID(kind: .forecast, validUTC: valid, originUTC: origin)
        XCTAssertEqual(Fmt.leadMinutes(id), 6)
        XCTAssertTrue(Fmt.crossesDay(id))
        XCTAssertEqual(id.validUTC, valid)
        XCTAssertEqual(id.originUTC, origin)
        XCTAssertTrue(Fmt.detail(id).contains("+6"))
    }

    func testAppleLanguagesArgumentPairsDoNotDisableOfflineMode() throws {
        for arguments in [
            ["Meteocat", "-AppleLanguages", "(en)", "--fixture"],
            ["Meteocat", "--fixture", "-AppleLanguages", "(ar)", "--show"],
            ["Meteocat", "-AppleLanguages", "--fixture"]
        ] {
            guard case .fixture = try LaunchOptions.parse(arguments).mode else { return XCTFail("Lost fixture mode") }
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["Meteocat", "-AppleLanguages", "(en)", "--unknown"]))
    }
}

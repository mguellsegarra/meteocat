import Foundation
public enum MeteocatResources {
    /// Keep the original settings/cache folder and admission gate across bundle changes and rollback.
    public static let legacyApplicationIdentifier = "cat.marc.meteocat-native"
    public static var geographyDirectory: URL { Bundle.module.resourceURL!.appendingPathComponent("Geography") }
    public static var previewFixtureDirectory: URL { Bundle.module.resourceURL!.appendingPathComponent("PreviewFixture") }
    public static var defaultCacheRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(legacyApplicationIdentifier).appendingPathComponent("radar-v1") }
    public static var defaultSettingsURL: URL { defaultCacheRoot.deletingLastPathComponent().appendingPathComponent("settings.json") }
    public static func defaultSettings() throws -> UserSettings {
        struct LegacyCity: Decodable { let id: String; let name: String; let lon: Double; let lat: Double; let visible: Bool }
        let cities = try JSONDecoder().decode([LegacyCity].self, from: AtomicFile.read(geographyDirectory.appendingPathComponent("default-cities.json")))
        let settings = UserSettings(cities: cities.map { City(id: $0.id, name: $0.name, point: GeoPoint(lon: $0.lon, lat: $0.lat), visible: $0.visible) },
                                    knownDefaultCityIDs: cities.map(\.id))
        try SettingsStore.validate(settings); return settings
    }
    public static func fixtureReferenceUTC() throws -> Date {
        struct Info: Decodable { let capturedAt: Date }
        return try NativeJSON.decode(Info.self, AtomicFile.read(previewFixtureDirectory.appendingPathComponent("snapshot-info.json"))).capturedAt
    }
}
public actor SettingsStore {
    private let url: URL
    private var settings: UserSettings
    private var notice: String?
    // The catalog predating incremental updates. Removed legacy defaults stay removed.
    private static let legacyDefaultCityIDs: Set<String> = [
        "mun:252430", "mun:170792", "mun:431554", "mun:080193", "mun:251207", "mun:431482",
        "mun:252038", "mun:431613", "mun:081136", "mun:082981", "mun:170669", "mun:252347",
        "mun:252075", "mun:430939", "mun:252094", "mun:430141", "mun:080229", "mun:430640",
        "mun:171143", "mun:171411", "mun:252173", "mun:083073"
    ]
    private init(url: URL, settings: UserSettings, notice: String?) { self.url = url; self.settings = settings; self.notice = notice }
    public static func open(at url: URL) async throws -> SettingsStore {
        let defaults = try MeteocatResources.defaultSettings()
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsStore(url: url, settings: defaults, notice: nil) }
        var settings: UserSettings
        let repairedPresence: Bool
        do {
            settings = try NativeJSON.decode(UserSettings.self, AtomicFile.read(url, maximum: 64*1024))
            repairedPresence = !settings.showsInDock && !settings.showsInMenuBar
            if repairedPresence { settings.showsInMenuBar = true }
            try validate(settings)
        } catch {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings-malformed-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
            try AtomicFile.write(NativeJSON.encode(defaults), to: url)
            return SettingsStore(url: url, settings: defaults, notice: "La configuració no era vàlida. S'han restablert els valors inicials i s'ha desat una còpia de l'anterior.")
        }
        let known = settings.knownDefaultCityIDs.map(Set.init) ?? legacyDefaultCityIDs
        let catalogIDs = Set(defaults.cities.map(\.id))
        if settings.knownDefaultCityIDs == nil || !catalogIDs.isSubset(of: known) {
            var existing = Set(settings.cities.map(\.id))
            for city in defaults.cities where !known.contains(city.id) {
                guard settings.cities.count < 60 else { break }
                if existing.insert(city.id).inserted { settings.cities.append(city) }
            }
            settings.knownDefaultCityIDs = known.union(catalogIDs).sorted()
            try validate(settings)
            // Persist even when no cities fit, so deleted entries are never resurrected on reopening.
            try AtomicFile.write(NativeJSON.encode(settings), to: url)
        }
        return SettingsStore(url: url, settings: settings,
            notice: repairedPresence ? "S'ha activat la barra de menús perquè Meteocat continuï accessible." : nil)
    }
    public func load() -> UserSettings { settings }
    public func recoveryNotice() -> String? { notice }
    public func save(_ settings: UserSettings) async throws { try Self.validate(settings); try AtomicFile.write(NativeJSON.encode(settings), to: url); self.settings = settings }
    public static func validate(_ settings: UserSettings) throws {
        guard settings.showsInDock || settings.showsInMenuBar else {
            throw MeteocatError("Cal mostrar Meteocat al Dock o a la barra de menús.")
        }
        guard settings.version == 1, settings.cities.count <= 60, Set(settings.cities.map(\.id)).count == settings.cities.count,
              settings.shortcut.keyCode <= 127, settings.shortcut.carbonModifiers & ~UInt32(0x1f00) == 0,
              settings.shortcut.carbonModifiers & UInt32(0x1900) != 0 else { throw MeteocatError("Configuració no vàlida.") }
        let projection = try MapProjection(manifestURL: MeteocatResources.geographyDirectory.appendingPathComponent("projection-manifest.json"))
        func point(_ p: GeoPoint) throws { let q = try projection.project(p); guard q.x >= 0, q.x <= 680, q.y >= 0, q.y <= 380 else { throw MeteocatError("Coordenades fora del mapa.") } }
        for city in settings.cities {
            guard !city.id.isEmpty, city.id.count <= 80, !city.id.contains(where: { $0.isWhitespace || $0.isNewline }), (1...40).contains(city.name.count), !city.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !city.name.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw MeteocatError("Nom o identificador de ciutat no vàlid.") }
            try point(city.point)
        }
        if let pin = settings.pin { try point(pin) }
    }
}

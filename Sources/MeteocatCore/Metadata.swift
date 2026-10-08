import Foundation
public enum RadarMetadata {
    public static let url = URL(string: "https://www.meteo.cat/observacions/radar")!
    public static func parseUTC(_ text: String) throws -> Date {
        let range = NSRange(text.startIndex..., in: text)
        let legacy = try NSRegularExpression(pattern: "\\A([0-9]{2})/([0-9]{2})/([0-9]{4}) ([0-9]{2}):([0-9]{2})Z\\z")
        let iso = try NSRegularExpression(pattern: "\\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:Z|\\+00:00)\\z")
        let parts: [Int]
        if let match = legacy.firstMatch(in: text, range: range) {
            let values = (1...5).compactMap { Int((text as NSString).substring(with: match.range(at: $0))) }
            guard values.count == 5 else { throw MeteocatError("Data UTC de Meteocat no vàlida.") }
            parts = values + [0]
        } else if let match = iso.firstMatch(in: text, range: range) {
            let values = (1...6).compactMap { Int((text as NSString).substring(with: match.range(at: $0))) }
            guard values.count == 6 else { throw MeteocatError("Data UTC de Meteocat no vàlida.") }
            parts = [values[1],values[2],values[0],values[3],values[4],values[5]]
        } else { throw MeteocatError("Data UTC de Meteocat no vàlida.") }
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw MeteocatError("Zona horària UTC no disponible.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let c = DateComponents(year: parts[2], month: parts[0], day: parts[1], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = calendar.date(from: c), calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date) == c else { throw MeteocatError("Data UTC fora de rang.") }
        return date
    }
    public static func parse(_ body: Data) throws -> Metadata {
        guard body.count <= 2 * 1024 * 1024, let html = String(data: body, encoding: .utf8) else { throw MeteocatError("Metadades no vàlides.") }
        func field(_ name: String) throws -> Date {
            let r = try NSRegularExpression(pattern: "\\b\(name)\\s*:\\s*['\"]([^'\"]+)['\"]")
            let matches = r.matches(in: html, range: NSRange(html.startIndex..., in: html))
            guard matches.count == 1 else { throw MeteocatError("Metadades absents o ambigües: \(name).") }
            return try parseUTC((html as NSString).substring(with: matches[0].range(at: 1)))
        }
        let m = try Metadata(serverUTC: field("dataServidor"), observationUTC: field("dataDarreraRadar"), originUTC: field("dataDarreraAdveccio"))
        guard m.observationUTC <= m.serverUTC.addingTimeInterval(360), m.originUTC <= m.serverUTC.addingTimeInterval(360) else { throw MeteocatError("Les metadades contenen dates futures incompatibles.") }
        return m
    }
    public static func candidates(_ metadata: Metadata) throws -> (observations: [FrameID], forecast: [FrameID]) {
        (try (0..<11).map { try FrameID(kind: .observation, validUTC: metadata.observationUTC.addingTimeInterval(Double($0 - 10) * 360)) }, try (1...10).map { try FrameID(kind: .forecast, validUTC: metadata.originUTC.addingTimeInterval(Double($0) * 360), originUTC: metadata.originUTC) })
    }
    public static func tileURL(_ id: FrameID, coordinate: TileCoordinate) throws -> URL {
        try id.validate(); guard TileCoordinate.grid.contains(coordinate) else { throw MeteocatError("Fragment del radar fora de cobertura.") }
        func parts(_ date: Date) throws -> [String] {
            guard let utc = TimeZone(secondsFromGMT: 0) else { throw MeteocatError("Zona horària UTC no disponible.") }
            var c = Calendar(identifier: .gregorian); c.timeZone = utc
            let d = c.dateComponents([.year,.month,.day,.hour,.minute], from: date)
            guard let year = d.year, let month = d.month, let day = d.day, let hour = d.hour, let minute = d.minute else { throw MeteocatError("Hora de radar no vàlida.") }
            return [String(format: "%04d", year), String(format: "%02d", month), String(format: "%02d", day), String(format: "%02d", hour), String(format: "%02d", minute)]
        }
        let v = try parts(id.validUTC), suffix = String(format: "07/000/000/%03d/000/000/%03d.png", coordinate.x, coordinate.yTMS)
        var path = "radar/" + v.joined(separator: "/")
        if let origin = id.originUTC { let o = try parts(origin); path = "adveccio/" + (Array(o.prefix(3)) + Array(v.prefix(3)) + Array(o.suffix(2)) + Array(v.suffix(2))).joined(separator: "/") }
        guard let url = URL(string: "https://static-m.meteo.cat/tiles/\(path)/\(suffix)") else { throw MeteocatError("URL de radar no vàlida.") }; return url
    }
    public static func retryDeadline(_ raw: String?, now: Date) -> Date {
        let minimum = now.addingTimeInterval(360), maximum = now.addingTimeInterval(86400)
        guard let raw else { return minimum }
        if !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // Saturating ASCII accumulation handles arbitrarily large integer headers.
            var seconds = 0
            for byte in raw.utf8 {
                seconds = min(86400, seconds * 10 + Int(byte - 48))
                if seconds == 86400 { break }
            }
            return max(minimum,now.addingTimeInterval(Double(seconds)))
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; f.isLenient = false
        return min(maximum,max(minimum,f.date(from: raw) ?? now))
    }
}

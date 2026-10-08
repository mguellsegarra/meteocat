import AppKit
import SwiftUI
import MeteocatCore

extension AppAppearance {
    var nativeAppearance: NSAppearance? {
        switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSColor {
    private static func radarColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
    static let radarInk = radarColor(light: 0x252B33, dark: 0xFFFFFF)
    static let radarChromeBackground = radarColor(light: 0xF7F8FA, dark: 0x000000)
    static let radarMapBackground = radarColor(light: 0xDCEAF1, dark: 0x0F1114)
    /// Deep teal: the system teal hue, darkened so 2.5 pt dots and the clock stay above 4.5:1 on light glass.
    static let radarForecast = radarColor(light: 0x00768A, dark: 0xFFD60A)
    // Clock and transport. Dark values equal the former radarInk uses; light is a softer slate than radarInk.
    static let radarTransportInk = radarColor(light: 0x3F4855, dark: 0xFFFFFF)
    static let radarClockZone = radarColor(light: 0x5F6874, dark: 0xFFFFFF, darkAlpha: 0.6)
    static let radarScrubberFill = radarColor(light: 0x5E6875, dark: 0xFFFFFF, darkAlpha: 0.78)
    static let radarScrubberTrack = radarColor(light: 0x5E6875, dark: 0xFFFFFF)
    /// Legibility shadow for glyphs over the map: full strength in dark, a faint lift on light glass.
    static let radarTransportShadow = radarColor(light: 0x000000, dark: 0x000000, lightAlpha: 0.2)
}

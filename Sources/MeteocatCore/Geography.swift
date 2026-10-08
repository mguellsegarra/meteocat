import Foundation
import CoreGraphics
import ImageIO

private struct SVGStyle {
    var fill = "black", stroke = "none"
    var width: CGFloat = 1, opacity: CGFloat = 1, fillOpacity: CGFloat = 1, strokeOpacity: CGFloat = 1
    var evenOdd = false
    mutating func apply(_ attributes: [String:String]) throws {
        for (key,value) in attributes {
            switch key {
            case "fill", "stroke":
                guard ["none","black","currentColor"].contains(value) || (value.count == 7 && value.hasPrefix("#") && UInt32(value.dropFirst(),radix: 16) != nil) else { throw MeteocatError("Color SVG no compatible.") }
                if key == "fill" { fill = value } else { stroke = value }
            case "stroke-width": guard let n = Double(value), n.isFinite, n >= 0, n <= 10 else { throw MeteocatError("Gruix SVG no vàlid.") }; width = n
            case "opacity", "fill-opacity", "stroke-opacity":
                guard let n = Double(value), n.isFinite, (0...1).contains(n) else { throw MeteocatError("Opacitat SVG no vàlida.") }
                if key == "opacity" { opacity *= n } else if key == "fill-opacity" { fillOpacity = n } else { strokeOpacity = n }
            case "fill-rule": guard value == "evenodd" || value == "nonzero" else { throw MeteocatError("Regla SVG no vàlida.") }; evenOdd = value == "evenodd"
            case "stroke-linejoin": guard value == "round" else { throw MeteocatError("Unió SVG no compatible.") }
            case "clip-path": guard value == "url(#frame)" else { throw MeteocatError("Clip SVG no compatible.") }
            case "transform", "style": throw MeteocatError("Transformació SVG no compatible.")
            default: break
            }
        }
    }
}
private struct SVGShape { let path: CGPath; let style: SVGStyle }
private final class SVGLoader: NSObject, XMLParserDelegate {
    var shapes = [SVGShape](), definitions = [String:CGPath](), styles = [SVGStyle]()
    var elements = [String](), failure: Error?, commands = 0
    func load(_ url: URL) throws -> [SVGShape] {
        let data = try AtomicFile.read(url, maximum: 4*1024*1024)
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw MeteocatError("SVG no segur.") }
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse(), failure == nil else { throw failure ?? MeteocatError("Geografia SVG no vàlida.") }
        return shapes
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String:String]) {
        do {
            guard elements.count < 32, shapes.count < 128, definitions.count < 128 else { throw MeteocatError("SVG massa complex.") }
            guard ["svg","title","desc","g","defs","clipPath","path","rect","use"].contains(name) else { throw MeteocatError("Element SVG no compatible: \(name).") }
            let allowed: Set<String> = ["xmlns","xmlns:xlink","width","height","viewBox","id","d","data-name","data-code","data-country","fill","stroke","stroke-width","stroke-opacity","fill-opacity","opacity","fill-rule","stroke-linejoin","clip-path","href","xlink:href","rx"]
            guard a.keys.allSatisfy({ allowed.contains($0) }) else { throw MeteocatError("Atribut SVG no compatible.") }
            var style = styles.last ?? SVGStyle(); try style.apply(a)
            let inDefs = elements.contains("defs")
            if name == "svg" { guard a["width"] == "680", a["height"] == "380", a["viewBox"] == "0 0 680 380" else { throw MeteocatError("Extensió SVG incompatible.") } }
            if name == "clipPath" { guard a["id"] == "frame" else { throw MeteocatError("Clip SVG desconegut.") } }
            if name == "path" {
                guard let d = a["d"] else { throw MeteocatError("Traçat SVG absent.") }
                let path = try parsePath(d)
                if let id = a["id"] { guard definitions[id] == nil else { throw MeteocatError("Identificador SVG duplicat.") }; definitions[id] = path }
                if !inDefs { shapes.append(SVGShape(path: path, style: style)) }
            } else if name == "rect" {
                guard a["width"] == "680", a["height"] == "380", a["x"] == nil, a["y"] == nil else { throw MeteocatError("Rectangle SVG incompatible.") }
                // The legacy rounded map card is deliberately a rectangular geographic clip.
                if !inDefs { shapes.append(SVGShape(path: CGPath(rect: CGRect(x: 0,y: 0,width: 680,height: 380), transform: nil), style: style)) }
            } else if name == "use" {
                guard let href = a["href"] ?? a["xlink:href"], href.hasPrefix("#"), let path = definitions[String(href.dropFirst())], a["x"] == nil, a["y"] == nil else { throw MeteocatError("Referència SVG no local o absent.") }
                shapes.append(SVGShape(path: path, style: style))
            }
            elements.append(name); styles.append(style)
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !elements.isEmpty { elements.removeLast(); styles.removeLast() } }
    private func parsePath(_ d: String) throws -> CGPath {
        let bytes = Array(d.utf8); var i = 0, command: UInt8 = 0, current = CGPoint.zero, start = CGPoint.zero, hasMove = false
        let path = CGMutablePath()
        func whitespace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 44 }
        func skip() { while i < bytes.count && whitespace(bytes[i]) { i += 1 } }
        func number() throws -> Double {
            skip(); let begin = i
            if i < bytes.count && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
            var digits = 0
            while i < bytes.count && (48...57).contains(bytes[i]) { i += 1; digits += 1 }
            if i < bytes.count && bytes[i] == 46 { i += 1; while i < bytes.count && (48...57).contains(bytes[i]) { i += 1; digits += 1 } }
            guard digits > 0, let value = Double(String(decoding: bytes[begin..<i], as: UTF8.self)), value.isFinite, abs(value) <= 10000 else { throw MeteocatError("Coordenada SVG no vàlida.") }
            return value
        }
        while i < bytes.count {
            skip(); if i == bytes.count { break }
            if [77,76,90,109,108,122].contains(bytes[i]) {
                command = bytes[i]; i += 1
                if command == 90 || command == 122 { guard hasMove else { throw MeteocatError("Tancament SVG sense inici.") }; path.closeSubpath(); current = start; command = 0; continue }
            }
            guard [77,76,109,108].contains(command) else { throw MeteocatError("Ordre SVG no compatible.") }
            let x = try number(), y = try number()
            let relative = command == 109 || command == 108
            let point = CGPoint(x: x + (relative ? current.x : 0), y: y + (relative ? current.y : 0))
            if command == 77 || command == 109 { path.move(to: point); start = point; hasMove = true; command = relative ? 108 : 76 }
            else { guard hasMove else { throw MeteocatError("Línia SVG sense inici.") }; path.addLine(to: point) }
            current = point; commands += 1; guard commands <= 400000 else { throw MeteocatError("SVG massa complex.") }
        }
        return path.copy()!
    }
}

/// Both draw calls require a flipped (top-left, y-down) receiving CGContext.
/// For an unflipped NSView, translate by its height and scale y by -1 once before calling.
@MainActor public final class Geography {
    private let underlay: [SVGShape], boundaries: [SVGShape]
    private let nativeDark: Bool
    private let terrain: CGImage?
    public init(directory: URL, nativeDark: Bool = false) throws {
        self.nativeDark = nativeDark
        let terrainURL = directory.appendingPathComponent("terrain-relief.png")
        if nativeDark, let data = try? AtomicFile.read(terrainURL, maximum: 2*1024*1024),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           image.width == 1360, image.height == 760 {
            terrain = image
        } else { terrain = nil }
        underlay = try SVGLoader().load(directory.appendingPathComponent("layer-under.svg"))
        boundaries = try SVGLoader().load(directory.appendingPathComponent("paths.svg"))
    }
    public func drawUnderlay(in context: CGContext, fit: MapFit, dark: Bool? = nil) {
        let darkOverride = dark != nil
        let dark = dark ?? nativeDark
        draw(underlay, in: context, fit: fit, dark: dark, themed: dark || darkOverride)
        guard let terrain, fit.scale.isFinite, fit.scale > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: fit.rect)
        // The packaged image has north in row zero, while the receiving context is y-down.
        context.translateBy(x: 0, y: fit.rect.minY + fit.rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        // The relief is a monochrome alpha overlay. Multiply suppresses white highlights on
        // light land while retaining its shadows; geography and raster coordinates stay unchanged.
        if !dark { context.setBlendMode(.multiply); context.setAlpha(0.55) }
        context.draw(terrain, in: fit.rect)
    }
    public func drawBoundaries(in context: CGContext, fit: MapFit, dark: Bool? = nil) { draw(boundaries, in: context, fit: fit, dark: dark ?? nativeDark, themed: dark != nil || nativeDark) }
    private func color(_ value: String, opacity: CGFloat) -> CGColor? {
        if value == "none" { return nil }
        if value == "currentColor" { return CGColor(srgbRed: 0.27,green: 0.31,blue: 0.36,alpha: opacity) }
        if value == "black" { return CGColor(srgbRed: 0,green: 0,blue: 0,alpha: opacity) }
        guard value.hasPrefix("#"), value.count == 7, let n = UInt32(value.dropFirst(),radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((n>>16)&255)/255,green: CGFloat((n>>8)&255)/255,blue: CGFloat(n&255)/255,alpha: opacity)
    }
    private func draw(_ shapes: [SVGShape], in context: CGContext, fit: MapFit, dark: Bool, themed: Bool) {
        guard fit.scale.isFinite, fit.scale > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: fit.rect); context.translateBy(x: fit.offset.x, y: fit.offset.y); context.scaleBy(x: fit.scale, y: fit.scale); context.setLineJoin(.round)
        for shape in shapes {
            var style = shape.style
            if dark {
                // Preserve source paths; only presentation colours and screen-point strokes change.
                switch style.fill {
                case "#10151b": style.fill = "#0F1114"
                case "#181b20": style.fill = "#17191D"
                case "#1e2126": style.fill = "#1C1E22"
                default: break
                }
                if style.stroke == "currentColor" {
                    let outline = style.width > 1
                    style.stroke = "#FFFFFF"
                    style.strokeOpacity = outline ? 0.24 : 0.055
                    style.width = (outline ? 0.8 : 0.5) / fit.scale
                } else if style.stroke == "#39414b" {
                    style.stroke = "#FFFFFF"
                    style.strokeOpacity = 0.09
                    style.width = 0.6 / fit.scale
                }
            }
            else if themed {
                switch style.fill.lowercased() {
                case "#10151b": style.fill = "#DCEAF1" // sea
                case "#181b20": style.fill = "#E7E8E2" // surrounding land
                case "#1e2126": style.fill = "#F3F1E8" // Catalunya
                default: break
                }
                if style.stroke == "currentColor" {
                    let outline = style.width > 1
                    style.stroke = "#45515C"
                    style.strokeOpacity = outline ? 0.65 : 0.26
                    style.width = (outline ? 0.8 : 0.5) / fit.scale
                } else if style.stroke == "#39414b" {
                    style.stroke = "#65727C"
                    style.strokeOpacity = 0.4
                    style.width = 0.6 / fit.scale
                }
            }
            if let fill = color(style.fill,opacity: style.opacity*style.fillOpacity) { context.setFillColor(fill); context.addPath(shape.path); context.drawPath(using: style.evenOdd ? .eoFill : .fill) }
            if let stroke = color(style.stroke,opacity: style.opacity*style.strokeOpacity) { context.setStrokeColor(stroke); context.setLineWidth(style.width); context.addPath(shape.path); context.strokePath() }
        }
    }
}

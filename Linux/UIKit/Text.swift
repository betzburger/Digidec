// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Schrift und Text: Messung und Zeichnung mit Pango/Cairo.
import Foundation
import CGtkCairo

// MARK: - Font

public struct Font: Sendable, Hashable {
    public enum Weight: Int, Sendable { case ultraLight = 200, thin = 250, light = 300, regular = 400, medium = 500, semibold = 600, bold = 700, heavy = 800, black = 900 }
    public enum Design: Sendable { case `default`, monospaced, rounded, serif }
    public enum TextStyle: Sendable { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }

    public var size: CGFloat
    public var weight: Weight
    public var design: Design
    public var isItalic = false
    public var monospacedDigits = false

    public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font { Font(size: size, weight: weight, design: design) }

    public static func system(_ style: TextStyle, design: Design = .default, weight: Weight? = nil) -> Font {
        var f = Font.style(style)
        f.design = design
        if let weight { f.weight = weight }
        return f
    }

    static func style(_ style: TextStyle) -> Font {
        switch style {
        case .largeTitle: return Font(size: 26, weight: .regular, design: .default)
        case .title: return Font(size: 22, weight: .regular, design: .default)
        case .title2: return Font(size: 17, weight: .regular, design: .default)
        case .title3: return Font(size: 15, weight: .regular, design: .default)
        case .headline: return Font(size: 13, weight: .bold, design: .default)
        case .subheadline: return Font(size: 11, weight: .regular, design: .default)
        case .body: return Font(size: 13, weight: .regular, design: .default)
        case .callout: return Font(size: 12, weight: .regular, design: .default)
        case .footnote: return Font(size: 10, weight: .regular, design: .default)
        case .caption: return Font(size: 10, weight: .regular, design: .default)
        case .caption2: return Font(size: 10, weight: .medium, design: .default)
        }
    }

    public static let largeTitle = Font.style(.largeTitle), title = Font.style(.title), title2 = Font.style(.title2), title3 = Font.style(.title3)
    public static let headline = Font.style(.headline), subheadline = Font.style(.subheadline), body = Font.style(.body), callout = Font.style(.callout)
    public static let footnote = Font.style(.footnote), caption = Font.style(.caption), caption2 = Font.style(.caption2)

    public func weight(_ w: Weight) -> Font { var f = self; f.weight = w; return f }
    public func bold() -> Font { weight(.bold) }
    public func italic() -> Font { var f = self; f.isItalic = true; return f }
    public func monospaced() -> Font { var f = self; f.design = .monospaced; return f }
    public func monospacedDigit() -> Font { var f = self; f.monospacedDigits = true; return f }
    public func design(_ d: Design) -> Font { var f = self; f.design = d; return f }
    public func leading(_ l: Leading) -> Font { self }
    public enum Leading: Sendable { case standard, tight, loose }

    /// Pango-Beschreibung als Zeichenkette für den Zwischenspeicher
    var key: String { "\(design)|\(weight.rawValue)|\(size)|\(isItalic)" }

    var family: String {
        switch design {
        case .monospaced: return "Noto Sans Mono,Adwaita Mono,monospace"
        case .serif: return "Noto Serif,serif"
        case .rounded, .default: return "Adwaita Sans,Noto Sans,Inter,sans-serif"
        }
    }
}

// MARK: - Text

/// Übersetzung der Schlüssel; der Kern setzt sie beim Start (liest Localizable.strings)
nonisolated(unsafe) public var localizationHook: (String) -> String = { $0 }
/// Rohes Rollereignis (dx, dy, GDK-Umschaltzustand) vor der Verteilung an die Knoten; true = verbraucht
nonisolated(unsafe) public var rawScrollHook: ((CGFloat, CGFloat, Int) -> Bool)?
/// Text in die Zwischenablage legen
nonisolated(unsafe) public var clipboardHook: (String) -> Void = { _ in }
/// Dateiauswahl: (Titel, speichern, Ordner, Vorschlag) → Pfad
nonisolated(unsafe) public var fileDialogHook: (String, Bool, Bool, String?) -> String? = { _, _, _, _ in nil }
/// Öffnen von Adressen und Ordnern im System
nonisolated(unsafe) public var openURLHook: (URL) -> Void = { _ in }

public struct LocalizedStringKey: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var format: String
    var arguments: [CVarArg]

    public init(stringLiteral value: String) { format = value; arguments = [] }
    public init(_ value: String) { format = value.replacingOccurrences(of: "%", with: "%%"); arguments = [] }

    public struct StringInterpolation: StringInterpolationProtocol {
        var format = ""
        var arguments: [CVarArg] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { format += literal.replacingOccurrences(of: "%", with: "%%") }
        public mutating func appendInterpolation(_ value: Int) { format += "%lld"; arguments.append(Int64(value)) }
        public mutating func appendInterpolation(_ value: Double) { format += "%lf"; arguments.append(value) }
        public mutating func appendInterpolation(_ value: String) { format += "%@"; arguments.append(value as NSString) }
        public mutating func appendInterpolation<T>(_ value: T) { format += "%@"; arguments.append(String(describing: value) as NSString) }
    }

    public init(stringInterpolation: StringInterpolation) { format = stringInterpolation.format; arguments = stringInterpolation.arguments }

    var resolved: String {
        let template = localizationHook(format)
        return arguments.isEmpty ? template.replacingOccurrences(of: "%%", with: "%") : String(format: template, arguments: arguments)
    }
}

public struct Text {
    public enum TruncationMode: Sendable { case head, tail, middle }
    public enum Case: Sendable { case uppercase, lowercase }

    var content: String
    var fontOverride: Font?
    var colorOverride: Color?
    var trackingOverride: CGFloat?
    var underlined = false
    var struck = false
    var boldOverride = false
    var italicOverride = false
    var monospacedDigitOverride = false

    public init(_ key: LocalizedStringKey) { content = key.resolved }
    @_disfavoredOverload public init<S: StringProtocol>(_ string: S) { content = String(string) }
    public init(verbatim: String) { content = verbatim }

    // Textspezifische Modifikatoren geben wieder `Text` zurück (wie in SwiftUI)
    public func font(_ f: Font?) -> Text { var t = self; t.fontOverride = f; return t }
    public func foregroundColor(_ c: Color?) -> Text { var t = self; t.colorOverride = c; return t }
    public func foregroundStyle(_ c: Color) -> Text { var t = self; t.colorOverride = c; return t }
    public func tracking(_ v: CGFloat) -> Text { var t = self; t.trackingOverride = v; return t }
    public func kerning(_ v: CGFloat) -> Text { tracking(v) }
    public func bold() -> Text { var t = self; t.boldOverride = true; return t }
    public func italic() -> Text { var t = self; t.italicOverride = true; return t }
    public func underline() -> Text { var t = self; t.underlined = true; return t }
    public func strikethrough() -> Text { var t = self; t.struck = true; return t }
    public func monospacedDigit() -> Text { var t = self; t.monospacedDigitOverride = true; return t }
    public func fontWeight(_ w: Font.Weight?) -> Text { var t = self; if let w { t.fontOverride = (t.fontOverride ?? .body).weight(w) }; return t }
    public func baselineOffset(_ v: CGFloat) -> Text { self }

    func spec(_ env: EnvironmentValues) -> TextSpec {
        var font = fontOverride ?? env.font
        if boldOverride { font.weight = .bold }
        if italicOverride { font.isItalic = true }
        if monospacedDigitOverride { font.monospacedDigits = true }
        var text = content
        if let c = env.textCase { text = c == .uppercase ? text.uppercased() : text.lowercased() }
        return TextSpec(text: text, font: font, color: colorOverride ?? env.foregroundColor ?? .primary, lineLimit: env.lineLimit,
                        tracking: trackingOverride ?? env.tracking, minScale: env.minimumScaleFactor, alignment: env.multilineTextAlignment,
                        underline: underlined, strikethrough: struck)
    }

}

extension Text: PrimitiveView {
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [TextNode(identity: r.identity, spec: spec(r.env))] }
}

private struct TextCaseKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: Text.Case? = nil }
extension EnvironmentValues {
    var textCase: Text.Case? { get { self[TextCaseKey.self] } set { self[TextCaseKey.self] = newValue } }
}

struct TextSpec: Hashable {
    var text: String
    var font: Font
    var color: Color
    var lineLimit: Int?
    var tracking: CGFloat
    var minScale: CGFloat
    var alignment: TextAlignment
    var underline: Bool
    var strikethrough: Bool
}

extension TextAlignment: Hashable {}

// MARK: - Messung und Zeichnung (Pango)

@MainActor
enum TextEngine {
    /// Gemeinsamer Cairo-Kontext für Messungen (Größe des Bildes spielt keine Rolle)
    private static let measureSurface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)!
    private static let measureCr = cairo_create(measureSurface)!

    private static let fontOptions: OpaquePointer = {
        let o = cairo_font_options_create()!
        cairo_font_options_set_hint_metrics(o, CAIRO_HINT_METRICS_OFF)
        cairo_font_options_set_hint_style(o, CAIRO_HINT_STYLE_NONE)
        cairo_font_options_set_antialias(o, CAIRO_ANTIALIAS_GRAY)
        return o
    }()

    struct Key: Hashable { var spec: TextSpec; var width: Int }
    struct Metrics { var size: CGSize; var baseline: CGFloat }
    private static var cache: [Key: Metrics] = [:]
    private static var layouts: [Key: OpaquePointer] = [:]

    /// Absolute Zeilenhöhe wie bei den Systemschriften des Mac (ca. 1,19 × Schriftgröße)
    static func lineHeight(_ size: CGFloat) -> CGFloat { (size * 1.19).rounded() }

    private static func makeLayout(_ cr: OpaquePointer, _ spec: TextSpec, scale: CGFloat, width: CGFloat?) -> OpaquePointer {
        let layout = pango_cairo_create_layout(cr)!
        // Messung und Zeichnung müssen dieselben Schriftmaße verwenden (sonst wird Text beim Zeichnen abgeschnitten)
        pango_cairo_context_set_font_options(pango_layout_get_context(layout), fontOptions)
        let description = pango_font_description_new()!
        pango_font_description_set_family(description, spec.font.family)
        pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(spec.font.weight.rawValue)))
        if spec.font.isItalic { pango_font_description_set_style(description, PANGO_STYLE_ITALIC) }
        pango_font_description_set_absolute_size(description, Double(spec.font.size * scale) * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, spec.text, -1)
        let attributes = pango_attr_list_new()!
        pango_attr_list_insert(attributes, pango_attr_line_height_new_absolute(Int32(lineHeight(spec.font.size * scale) * CGFloat(PANGO_SCALE))))
        if spec.tracking != 0 { pango_attr_list_insert(attributes, pango_attr_letter_spacing_new(Int32(Double(spec.tracking * scale) * Double(PANGO_SCALE)))) }
        if spec.underline { pango_attr_list_insert(attributes, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE)) }
        if spec.strikethrough { pango_attr_list_insert(attributes, pango_attr_strikethrough_new(1)) }
        if spec.font.monospacedDigits { pango_attr_list_insert(attributes, pango_attr_font_features_new("tnum")) }
        pango_layout_set_attributes(layout, attributes)
        pango_attr_list_unref(attributes)
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        switch spec.alignment {
        case .leading: pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT)
        case .center: pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)
        case .trailing: pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT)
        }
        if let width, width.isFinite {
            pango_layout_set_width(layout, Int32(max(0, width * scale) * CGFloat(PANGO_SCALE)))
            if let limit = spec.lineLimit {
                pango_layout_set_height(layout, -Int32(limit))
                pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            }
        } else if let limit = spec.lineLimit, limit > 0 {
            // Ohne Breite: nur die ersten Zeilen messen
            pango_layout_set_height(layout, -Int32(limit))
        }
        return layout
    }

    static func measure(_ spec: TextSpec, width: CGFloat?) -> Metrics {
        let w = width.flatMap { $0.isFinite ? $0 : nil }
        let key = Key(spec: spec, width: w.map { Int(($0 * 4).rounded()) } ?? -1)
        if let m = cache[key] { return m }
        let layout = makeLayout(measureCr, spec, scale: 1, width: w)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var pw: Int32 = 0, ph: Int32 = 0
        pango_layout_get_size(layout, &pw, &ph)
        let baseline = CGFloat(pango_layout_get_baseline(layout)) / CGFloat(PANGO_SCALE)
        var size = CGSize(width: (CGFloat(pw) / CGFloat(PANGO_SCALE)).rounded(.up), height: CGFloat(ph) / CGFloat(PANGO_SCALE))
        if spec.text.isEmpty { size.height = lineHeight(spec.font.size) }
        let m = Metrics(size: size, baseline: baseline)
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = m
        return m
    }

    /// Zeichnet den Text in `rect` (Oberkante des Textes = rect.minY)
    static func draw(_ spec: TextSpec, in rect: CGRect, scale: CGFloat = 1, cr: OpaquePointer) {
        guard !spec.text.isEmpty else { return }
        cairo_save(cr)
        defer { cairo_restore(cr) }
        var fitting = spec
        // Passt der Text, wird nie gekürzt (Pango kürzt sonst bei Zeichenabstand schon bei exakt passender Breite)
        if spec.lineLimit != nil, measure(spec, width: nil).size.width <= rect.width + 0.5 { fitting.lineLimit = nil }
        // Fertig umbrochene Layouts bleiben erhalten; die Farbe gehört nicht zum Schlüssel
        let layoutWidth = fitting.lineLimit == nil ? rect.width + 1 : rect.width
        var neutral = fitting
        neutral.color = Color(white: 0)
        let key = Key(spec: neutral, width: Int((layoutWidth * 4).rounded()))
        let layout: OpaquePointer
        if let cached = layouts[key] {
            layout = cached
            pango_cairo_update_layout(cr, layout)
        } else {
            layout = makeLayout(cr, fitting, scale: 1, width: layoutWidth)
            if layouts.count >= 3000 {
                for (_, old) in layouts { g_object_unref(UnsafeMutableRawPointer(old)) }
                layouts.removeAll(keepingCapacity: true)
            }
            layouts[key] = layout
        }
        cairo_set_source_rgba(cr, spec.color.red, spec.color.green, spec.color.blue, spec.color.alpha)
        cairo_move_to(cr, rect.minX, rect.minY)
        pango_cairo_show_layout(cr, layout)
    }
}

@MainActor
final class TextNode: Node {
    let spec: TextSpec
    init(identity: Identity, spec: TextSpec) { self.spec = spec; super.init(identity: identity) }

    /// Schrift, die für `minimumScaleFactor` verkleinert werden darf
    private func scaledSpec(for width: CGFloat?) -> TextSpec {
        guard spec.minScale < 1, let width, width.isFinite else { return spec }
        let natural = TextEngine.measure(spec, width: nil).size.width
        guard natural > width, natural > 0 else { return spec }
        var s = spec
        s.font.size = max(spec.font.size * spec.minScale, spec.font.size * width / natural)
        return s
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        let s = scaledSpec(for: p.width)
        let natural = TextEngine.measure(s, width: nil)
        guard let w = p.width, w.isFinite else { return natural.size }
        if natural.size.width <= w, !s.text.contains("\n") { return natural.size }
        let wrapped = TextEngine.measure(s, width: w)
        return CGSize(width: min(wrapped.size.width, max(w, 0)), height: wrapped.size.height)
    }

    override var firstBaseline: CGFloat? { TextEngine.measure(spec, width: nil).baseline }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        var s = scaledSpec(for: frame.width)
        if s.lineLimit == nil { s.lineLimit = nil }
        TextEngine.draw(s, in: frame, cr: g.cr)
    }
}

// MARK: - Canvas-Text

extension GraphicsContext {
    /// Text in einem Canvas (wie `GraphicsContext.draw(Text, at:anchor:)`)
    public func draw(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) {
        MainActor.assumeIsolated {
            var env = EnvironmentValues()
            env.font = .body
            let spec = text.spec(env)
            let m = TextEngine.measure(spec, width: nil)
            let origin = CGPoint(x: point.x - m.size.width * anchor.x, y: point.y - m.size.height * anchor.y)
            TextEngine.draw(spec, in: CGRect(origin: origin, size: CGSize(width: m.size.width + 2, height: m.size.height)), cr: cr)
        }
    }
}

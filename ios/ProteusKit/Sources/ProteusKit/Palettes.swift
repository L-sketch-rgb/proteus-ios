import Foundation

public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// #RRGGBB (sRGB), passed to the shader without gamma conversion.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        r = Double((number >> 16) & 0xFF) / 255.0
        g = Double((number >> 8) & 0xFF) / 255.0
        b = Double(number & 0xFF) / 255.0
    }
}

public struct PaletteMode: Codable, Equatable, Sendable {
    public var bg: String
    public var wave0: String
    public var wave1: String
    public var wave2: String
    public var wave3: String
    public var accent: String

    public init(
        bg: String,
        wave0: String,
        wave1: String,
        wave2: String,
        wave3: String,
        accent: String
    ) {
        self.bg = bg
        self.wave0 = wave0
        self.wave1 = wave1
        self.wave2 = wave2
        self.wave3 = wave3
        self.accent = accent
    }

    public func rgb(_ hex: String) -> RGB {
        RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
    }

    public var background: RGB { rgb(bg) }
    public var accentColor: RGB { rgb(accent) }
    public var waves: [RGB] { [rgb(wave0), rgb(wave1), rgb(wave2), rgb(wave3)] }
}

public struct Palette: Codable, Identifiable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var dark: PaletteMode
    public var light: PaletteMode

    public init(key: String, label: String, dark: PaletteMode, light: PaletteMode) {
        self.key = key
        self.label = label
        self.dark = dark
        self.light = light
    }

    public var id: String { key }

    public func mode(dark isDark: Bool) -> PaletteMode {
        isDark ? dark : light
    }
}

public enum PaletteCatalog {
    private struct File: Codable {
        var palettes: [Palette]
    }

    /// The 12 palettes from export/wave-dither/palettes.json (bundled resource).
    public static let palettes: [Palette] = {
        guard let url = Bundle.module.url(forResource: "palettes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.palettes
    }()

    public static let defaultKey = "blue"

    public static func palette(key: String) -> Palette? {
        palettes.first { $0.key == key }
    }

    public static var defaultPalette: Palette? {
        palette(key: defaultKey) ?? palettes.first
    }
}

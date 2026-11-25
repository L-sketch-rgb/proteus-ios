import Foundation

/// A palette computed from one hue shift and one saturation factor, exactly like
/// `art/palettes.py` (the 12 built-in palettes are the same filter applied to
/// the same seeds). Everything that is coloured — the marks, `wave0..3`, `bg`
/// and `accent` — goes through this one filter, in dark and light.
public enum PaletteEngine {
    /// Clay-tinted seeds, dark / light. Same table and order as `art/palettes.py`.
    public static let seeds: [String: (dark: String, light: String)] = [
        "bg": ("#211A17", "#F8F1EC"),
        "wave0": ("#1A1412", "#F3EAE3"),
        "wave1": ("#33231D", "#EBD8CB"),
        "wave2": ("#5E3526", "#DFB9A2"),
        "wave3": ("#8A4A32", "#D39878"),
        "accent": ("#D97757", "#C96442"),
    ]

    /// The clay dark accent, the reference every palette is measured from.
    public static let clayAccent = "#D97757"

    /// hsv hue of the canonical blue mark, in degrees (`BLUE_SHIFT` in palettes.py).
    public static let blueHueDegrees = 205.0

    /// The seed order used by `PaletteMode`, so custom palettes are built from
    /// the same six keys as the bundled table.
    public static let seedKeys = ["bg", "wave0", "wave1", "wave2", "wave3", "accent"]

    // MARK: - The filter

    /// `q(deg) = round(deg / 360 * 256)`, Python's banker's rounding.
    public static func q(_ degrees: Double) -> Int {
        Int((degrees / 360.0 * 256.0).rounded(.toNearestOrEven))
    }

    /// Build a palette from a hue shift (degrees) and a saturation factor by
    /// running every seed through the same filter as `filt_hex`.
    public static func customPalette(shift: Double, sat: Double) -> Palette {
        let dark = PaletteMode(
            bg: transformedHex(seeds["bg"]!.dark, shift: shift, sat: sat),
            wave0: transformedHex(seeds["wave0"]!.dark, shift: shift, sat: sat),
            wave1: transformedHex(seeds["wave1"]!.dark, shift: shift, sat: sat),
            wave2: transformedHex(seeds["wave2"]!.dark, shift: shift, sat: sat),
            wave3: transformedHex(seeds["wave3"]!.dark, shift: shift, sat: sat),
            accent: transformedHex(seeds["accent"]!.dark, shift: shift, sat: sat)
        )
        let light = PaletteMode(
            bg: transformedHex(seeds["bg"]!.light, shift: shift, sat: sat),
            wave0: transformedHex(seeds["wave0"]!.light, shift: shift, sat: sat),
            wave1: transformedHex(seeds["wave1"]!.light, shift: shift, sat: sat),
            wave2: transformedHex(seeds["wave2"]!.light, shift: shift, sat: sat),
            wave3: transformedHex(seeds["wave3"]!.light, shift: shift, sat: sat),
            accent: transformedHex(seeds["accent"]!.light, shift: shift, sat: sat)
        )
        return Palette(key: "custom", label: "Custom", dark: dark, light: light)
    }

    /// Port of `filt_hex` (art/palettes.py). `colorsys` (double precision) for
    /// RGB<->HSV, hue stored 0...255, saturation multiplied and clamped at 1.
    public static func transformedHex(_ hex: String, shift: Double, sat: Double) -> String {
        guard let rgb = parseHex(hex) else { return hex }
        let hsv = rgbToHSVDouble(rgb)
        var h8 = (Int((hsv.h * 255.0).rounded(.toNearestOrEven)) + q(shift)) % 256
        if h8 < 0 { h8 += 256 }
        let saturation = min(1.0, hsv.s * sat)
        let out = hsvToRGBDouble(h: Double(h8) / 255.0, s: saturation, v: hsv.v)
        return formatHex(out)
    }

    // MARK: - Picked colour -> (shift, sat)

    /// One colour picked on a wheel, mapped to the palette it represents.
    public struct ColorMapping: Equatable, Sendable {
        /// Canonical `#RRGGBB` for the picked colour.
        public var color: String
        public var shift: Double
        public var sat: Double

        public init(color: String, shift: Double, sat: Double) {
            self.color = color
            self.shift = shift
            self.sat = sat
        }
    }

    /// The rule from docs/design/v7-custom-colours.md §1:
    /// `shift = hue(picked) - hue(CLAY_ACCENT)` normalised to (-180, 180], and
    /// `sat = clamp(S(picked) / S(CLAY_ACCENT), 0, 1.25)`. Brightness is ignored.
    public static func mapPickedColor(hex: String) -> ColorMapping? {
        guard let picked = parseHex(hex),
              let clay = parseHex(clayAccent) else { return nil }
        let pickedHSV = rgbToHSVDouble(picked)
        let clayHSV = rgbToHSVDouble(clay)
        let shift = normalizedShift((pickedHSV.h - clayHSV.h) * 360.0)
        let sat = min(max(pickedHSV.s / clayHSV.s, 0.0), 1.25)
        return ColorMapping(color: formatHex(picked), shift: shift, sat: sat)
    }

    /// Normalise a hue difference to (-180, 180].
    public static func normalizedShift(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360.0)
        if value <= -180.0 { value += 360.0 }
        if value > 180.0 { value -= 360.0 }
        return value == 0 ? 0 : value
    }

    // MARK: - Image filter

    /// `dhue8` for a palette: `(q(shift) - q(205)) mod 256`, i.e. the same
    /// rotation `filt_img` applies to the canonical blue files.
    public static func hueDelta8(shift: Double) -> Int {
        ((q(shift) - q(blueHueDegrees)) % 256 + 256) % 256
    }

    /// Filter straight RGBA bytes. Port of `filt_img` including Pillow's 8-bit
    /// HSV conversion; the alpha byte is copied unchanged.
    ///
    /// Pillow's formulas (src/libImaging/Convert.c, 12.3.0):
    /// - RGB -> HSV: with `maxc`, `minc`, `cr = maxc-minc`, all as C `float`,
    ///   `s = cr / maxc`, and the hue is `h = fmod(h/6 + 1, 1)` computed in
    ///   `double` and stored back into a `float`. `H = (int)(h * 255.0)` and
    ///   `S = (int)(s * 255.0)`, both truncating.
    /// - HSV -> RGB: `i = floor(h * 6 / 255)`, `f = h * 6 / 255 - i`,
    ///   `p/q/t = round(v * (1 - ...))` with C `round` and 8-bit clipping.
    ///
    /// Saturation scaling uses `np.round` semantics (half to even), matching
    /// `filt_img`'s `np.round(S * sat)`.
    public static func filterRGBA(_ bytes: [UInt8], dhue8: Int, sat: Double) -> [UInt8] {
        guard bytes.count >= 4 else { return bytes }
        if dhue8 == 0 && sat == 1.0 { return bytes }
        var out = bytes
        let pixels = bytes.count / 4
        for index in 0..<pixels {
            let offset = index * 4
            let hsv = rgbToHSVPillow(bytes[offset], bytes[offset + 1], bytes[offset + 2])
            let hue = ((Int(hsv.0) + dhue8) % 256 + 256) % 256
            let saturation = min(max(Int((Double(hsv.1) * sat).rounded(.toNearestOrEven)), 0), 255)
            let rgb = hsvToRGBPillow(h: UInt8(hue), s: UInt8(saturation), v: hsv.2)
            out[offset] = rgb.0
            out[offset + 1] = rgb.1
            out[offset + 2] = rgb.2
            // out[offset + 3] keeps the original alpha.
        }
        return out
    }

    /// Filter a whole image for a palette (used by the app for the hand mark).
    public static func filterRGBA(_ data: Data, shift: Double, sat: Double) -> Data {
        Data(filterRGBA([UInt8](data), dhue8: hueDelta8(shift: shift), sat: sat))
    }

    // MARK: - Palettes.py helpers

    struct HSV {
        var h: Double
        var s: Double
        var v: Double
    }

    /// Python `colorsys.rgb_to_hsv` on 8-bit RGB.
    static func rgbToHSVDouble(_ rgb: (UInt8, UInt8, UInt8)) -> HSV {
        let r = Double(rgb.0) / 255.0
        let g = Double(rgb.1) / 255.0
        let b = Double(rgb.2) / 255.0
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let v = maxc
        guard maxc != 0 else { return HSV(h: 0, s: 0, v: 0) }
        let s = (maxc - minc) / maxc
        guard maxc != minc else { return HSV(h: 0, s: s, v: v) }
        let cr = maxc - minc
        let rc = (maxc - r) / cr
        let gc = (maxc - g) / cr
        let bc = (maxc - b) / cr
        let raw: Double
        if r == maxc {
            raw = bc - gc
        } else if g == maxc {
            raw = 2.0 + rc - bc
        } else {
            raw = 4.0 + gc - rc
        }
        var h = (raw / 6.0).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1.0 }
        return HSV(h: h, s: s, v: v)
    }

    /// Python `colorsys.hsv_to_rgb`, h in 0...1.
    static func hsvToRGBDouble(h: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
        if s == 0 { return (byte(v), byte(v), byte(v)) }
        let h6 = h * 6.0
        let i = Int(floor(h6))
        let f = h6 - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        let rgb: (Double, Double, Double)
        switch ((i % 6) + 6) % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        return (byte(rgb.0), byte(rgb.1), byte(rgb.2))
    }

    /// Python's `round(c * 255)` (half to even).
    private static func byte(_ component: Double) -> UInt8 {
        UInt8(min(max(Int((component * 255.0).rounded(.toNearestOrEven)), 0), 255))
    }

    // MARK: - Pillow 8-bit HSV (float32 semantics)

    /// Port of Pillow's `rgb2hsv_row`. The intermediate components are C
    /// `float`s, which is load-bearing at hue byte boundaries.
    static func rgbToHSVPillow(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let v = maxc
        guard minc != maxc else { return (0, 0, v) }

        let cr = Float(Int(maxc) - Int(minc))
        let s = cr / Float(maxc)
        let rc = Float(Int(maxc) - Int(r)) / cr
        let gc = Float(Int(maxc) - Int(g)) / cr
        let bc = Float(Int(maxc) - Int(b)) / cr

        let raw: Float
        if r == maxc {
            raw = bc - gc
        } else if g == maxc {
            raw = 2.0 + rc - bc
        } else {
            raw = 4.0 + gc - rc
        }
        // C promotes to double for the division and fmod, then stores back to float.
        let h = Float(fmod(Double(raw) / 6.0 + 1.0, 1.0))
        let uh = UInt8(clamping: Int(Double(h) * 255.0))
        let us = UInt8(clamping: Int(Double(s) * 255.0))
        return (uh, us, v)
    }

    /// Port of Pillow's `hsv2rgb` (8-bit HSV).
    static func hsvToRGBPillow(h: UInt8, s: UInt8, v: UInt8) -> (UInt8, UInt8, UInt8) {
        if s == 0 { return (v, v, v) }
        let scaled = Double(h) * 6.0 / 255.0
        let i = Int(floor(scaled))
        let f = Float(scaled - Double(i))
        let fs = Float(Double(s) / 255.0)
        let p = Int((Double(v) * (1.0 - Double(fs))).rounded())
        let q = Int((Double(v) * (1.0 - Double(fs) * Double(f))).rounded())
        let t = Int((Double(v) * (1.0 - Double(fs) * (1.0 - Double(f)))).rounded())
        let up = UInt8(clamping: p)
        let uq = UInt8(clamping: q)
        let ut = UInt8(clamping: t)
        switch ((i % 6) + 6) % 6 {
        case 0: return (v, ut, up)
        case 1: return (uq, v, up)
        case 2: return (up, v, ut)
        case 3: return (up, uq, v)
        case 4: return (ut, up, v)
        default: return (v, up, uq)
        }
    }

    // MARK: - Hex

    static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (UInt8((number >> 16) & 0xFF), UInt8((number >> 8) & 0xFF), UInt8(number & 0xFF))
    }

    static func formatHex(_ rgb: (UInt8, UInt8, UInt8)) -> String {
        String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2)
    }
}

import Foundation

/// One synced custom-colour slot (docs/design/v7-custom-colours.md §2).
/// The hub stores exactly what the client sends: a hex colour plus the
/// palette's hue shift and saturation factor.
public struct AppearanceSlot: Codable, Equatable, Sendable {
    public var color: String
    public var shift: Double
    public var sat: Double
    public var savedAt: String

    public init(color: String, shift: Double, sat: Double, savedAt: String = AppearanceSlot.timestamp()) {
        self.color = color
        self.shift = shift
        self.sat = sat
        self.savedAt = savedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(String.self, forKey: .color)
        shift = try c.decode(Double.self, forKey: .shift)
        sat = try c.decode(Double.self, forKey: .sat)
        savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case color, shift, sat, savedAt }

    public static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Turn a picked `#RRGGBB` into a slot with the mapping from §1.
    public static func fromPickedColor(_ hex: String, savedAt: String = AppearanceSlot.timestamp()) -> AppearanceSlot? {
        guard let mapping = PaletteEngine.mapPickedColor(hex: hex) else { return nil }
        return AppearanceSlot(color: mapping.color, shift: mapping.shift, sat: mapping.sat, savedAt: savedAt)
    }
}

/// `welcome.appearance` and the `appearance` broadcast payload.
public struct AppearanceInfo: Codable, Equatable, Sendable {
    public var slots: [AppearanceSlot?]

    public init(slots: [AppearanceSlot?]) {
        self.slots = AppearanceStore.normalized(slots)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = AppearanceStore.normalized(try c.decodeIfPresent([AppearanceSlot?].self, forKey: .slots) ?? [])
    }

    private enum CodingKeys: String, CodingKey { case slots }
}

/// The unsolicited `{t:"appearance", slots}` broadcast.
public struct AppearanceFrame: Codable, Equatable, Sendable {
    public var slots: [AppearanceSlot?]

    public init(slots: [AppearanceSlot?]) {
        self.slots = AppearanceStore.normalized(slots)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = AppearanceStore.normalized(try c.decodeIfPresent([AppearanceSlot?].self, forKey: .slots) ?? [])
    }

    private enum CodingKeys: String, CodingKey { case slots }
}

/// Per-device palette selection: a built-in key (`blue`) or `custom:<index>`.
public enum PaletteSelection: Equatable, Sendable {
    case builtin(String)
    case custom(Int)

    public init(raw: String) {
        if raw.hasPrefix("custom:"),
           let index = Int(raw.dropFirst("custom:".count)),
           (0..<AppearanceStore.slotCount).contains(index) {
            self = .custom(index)
        } else {
            self = .builtin(raw)
        }
    }

    public var raw: String {
        switch self {
        case .builtin(let key): return key
        case .custom(let index): return "custom:\(index)"
        }
    }
}

/// A selection resolved against the synced slots: always a usable palette.
public struct ResolvedPalette: Equatable, Sendable {
    /// The resolved selection, e.g. `blue` or `custom:2`.
    public var selection: String
    public var palette: Palette
    /// Set only when a filled custom slot backs the selection.
    public var customIndex: Int?
    public var shift: Double?
    public var sat: Double?

    public init(selection: String, palette: Palette, customIndex: Int? = nil, shift: Double? = nil, sat: Double? = nil) {
        self.selection = selection
        self.palette = palette
        self.customIndex = customIndex
        self.shift = shift
        self.sat = sat
    }

    public var isCustom: Bool { customIndex != nil }
}

/// The 5 synced slots (hub KV `appearance:slots`) and the selection fallback
/// rule. Plain class with a callback, like the other ProteusKit stores.
public final class AppearanceStore {
    public static let slotCount = 5
    /// UserDefaults key shared with `@AppStorage("proteus.palette")` in the app.
    public static let selectionDefaultsKey = "proteus.palette"

    public private(set) var slots: [AppearanceSlot?] = Array(repeating: nil, count: slotCount)
    public var onSlotsChanged: (() -> Void)?

    public init() {}

    /// Pad or truncate to exactly 5; `null` entries stay `nil`.
    public static func normalized(_ slots: [AppearanceSlot?]) -> [AppearanceSlot?] {
        var out = Array(slots.prefix(slotCount))
        if out.count < slotCount {
            out.append(contentsOf: Array(repeating: nil, count: slotCount - out.count))
        }
        return out
    }

    public func apply(slots: [AppearanceSlot?]) {
        let next = Self.normalized(slots)
        guard next != self.slots else { return }
        self.slots = next
        onSlotsChanged?()
    }

    public func apply(info: AppearanceInfo?) {
        guard let info else { return }
        apply(slots: info.slots)
    }

    public func apply(frame: AppearanceFrame) {
        apply(slots: frame.slots)
    }

    /// Optimistic local update while waiting for the hub broadcast.
    public func setLocal(index: Int, slot: AppearanceSlot?) {
        guard (0..<Self.slotCount).contains(index) else { return }
        var next = slots
        next[index] = slot
        apply(slots: next)
    }

    public func slot(at index: Int) -> AppearanceSlot? {
        guard (0..<Self.slotCount).contains(index) else { return nil }
        return slots[index]
    }

    public func hasSlot(_ index: Int) -> Bool {
        slot(at: index) != nil
    }

    /// The selection actually shown: an emptied `custom:<n>` falls back to blue.
    public func resolvedSelection(for raw: String) -> String {
        switch PaletteSelection(raw: raw) {
        case .custom(let index):
            return hasSlot(index) ? "custom:\(index)" : PaletteCatalog.defaultKey
        case .builtin(let key):
            return PaletteCatalog.palette(key: key) != nil ? key : PaletteCatalog.defaultKey
        }
    }

    /// Resolve a selection to a palette, including a computed custom palette.
    public func resolve(_ raw: String) -> ResolvedPalette {
        let selection = resolvedSelection(for: raw)
        switch PaletteSelection(raw: selection) {
        case .custom(let index):
            let slot = slots[index] ?? AppearanceSlot(color: "#D97757", shift: 0, sat: 1)
            return ResolvedPalette(
                selection: selection,
                palette: PaletteEngine.customPalette(shift: slot.shift, sat: slot.sat),
                customIndex: index,
                shift: slot.shift,
                sat: slot.sat
            )
        case .builtin(let key):
            let palette = PaletteCatalog.palette(key: key)
                ?? PaletteCatalog.defaultPalette
                ?? Self.fallbackPalette
            return ResolvedPalette(selection: palette.key, palette: palette)
        }
    }

    private static let fallbackPalette = Palette(
        key: "blue",
        label: "Blue",
        dark: PaletteMode(bg: "#171A21", wave0: "#12141A", wave1: "#1D2333", wave2: "#26375E", wave3: "#324B8A", accent: "#5782D9"),
        light: PaletteMode(bg: "#ECEEF8", wave0: "#E3E5F3", wave1: "#CBD0EB", wave2: "#A2ADDF", wave3: "#788BD3", accent: "#426BC9")
    )
}

// MARK: - Frames

public extension ClientFrame {
    /// `appearance.setSlot` (protocol v7). `slot == nil` clears the slot.
    static func appearanceSetSlot(index: Int, slot: AppearanceSlot?, rid: String? = nil) -> ClientFrame {
        let encodedSlot: JSONValue
        if let slot, let value = try? JSONValue.from(slot) {
            encodedSlot = value
        } else {
            encodedSlot = .null
        }
        return ClientFrame("appearance.setSlot", rid: rid, [
            "index": .int(index),
            "slot": encodedSlot,
        ])
    }
}

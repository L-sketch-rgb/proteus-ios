import SwiftUI
import UIKit
import Foundation
import ProteusKit

/// Picker for one custom palette slot (v7 §3). SwiftUI's `ColorPicker` provides
/// the wheel/spectrum; the brightness rule, the live preview and the 5-slot
/// chooser are ours.
struct CustomColorPickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("proteus.palette") private var paletteKey = "blue"

    let initialIndex: Int
    let initialSlot: AppearanceSlot?

    @State private var color: Color
    @State private var targetIndex: Int

    init(initialIndex: Int, initialSlot: AppearanceSlot?) {
        self.initialIndex = initialIndex
        self.initialSlot = initialSlot
        _color = State(initialValue: Color(hex: initialSlot?.color ?? "#D97757"))
        _targetIndex = State(initialValue: initialIndex)
    }

    private var hex: String {
        Self.hexString(from: color)
    }

    private var mapping: PaletteEngine.ColorMapping {
        PaletteEngine.mapPickedColor(hex: hex)
            ?? PaletteEngine.ColorMapping(color: hex, shift: 0, sat: 1)
    }

    private var palette: Palette {
        PaletteEngine.customPalette(shift: mapping.shift, sat: mapping.sat)
    }

    private var mode: PaletteMode {
        palette.mode(dark: colorScheme == .dark)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ColorPicker("Colour", selection: $color, supportsOpacity: false)
                        .font(.headline)

                    Text("Brightness is set per theme for readable text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    preview

                    slotChooser

                    Button {
                        save()
                    } label: {
                        Text("Save to slot \(targetIndex + 1)")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(mode.accentColor.color)
                }
                .padding(16)
            }
            .navigationTitle("Custom colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.subheadline)
            HStack(alignment: .center, spacing: 16) {
                markPreview
                    .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dither")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            ForEach(mode.waves.indices, id: \.self) { index in
                                Rectangle()
                                    .fill(mode.waves[index].color)
                                    .frame(width: 26, height: 16)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text("Accent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(mode.accentColor.color, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var markPreview: some View {
        if let image = app.customMarkImage(shift: mapping.shift, sat: mapping.sat) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image("mark-blue")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        }
    }

    // MARK: - Slot chooser

    private var slotChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save to slot")
                .font(.subheadline)
            HStack(spacing: 10) {
                ForEach(0..<AppearanceStore.slotCount, id: \.self) { index in
                    Button {
                        targetIndex = index
                    } label: {
                        slotSwatch(index)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Slot \(index + 1)")
                }
                Spacer()
            }
        }
    }

    private func slotSwatch(_ index: Int) -> some View {
        let slot = index < app.appearanceSlots.count ? app.appearanceSlots[index] : nil
        let selected = targetIndex == index
        return ZStack {
            if let slot {
                Circle()
                    .fill(Color(hex: slot.color))
                    .frame(width: 30, height: 30)
            } else {
                Circle()
                    .strokeBorder(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: "plus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if selected {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 38, height: 38)
            }
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - Actions

    private func save() {
        guard let slot = AppearanceSlot.fromPickedColor(hex) else { return }
        app.saveAppearanceSlot(slot, at: targetIndex, select: true)
        paletteKey = "custom:\(targetIndex)"
        dismiss()
    }

    /// Resolve the picker colour in sRGB before reading its channels.
    private static func hexString(from color: Color) -> String {
        let uiColor = UIColor(color).resolvedColor(with: UITraitCollection(displayGamut: .SRGB))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#D97757"
        }
        func channel(_ value: CGFloat) -> Int {
            min(max(Int((value * 255.0).rounded()), 0), 255)
        }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

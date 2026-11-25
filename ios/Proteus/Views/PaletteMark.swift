import SwiftUI
import ProteusKit

/// The hand mark for a selection. Built-in palettes use their bundled mark
/// asset; a custom palette filters the canonical blue mark at runtime through
/// `PaletteEngine`, with nearest-neighbour scaling as everywhere else.
struct PaletteMark: View {
    @EnvironmentObject private var app: AppModel
    let selection: String

    var body: some View {
        let resolved = app.resolvedPalette(for: selection)
        Group {
            if let shift = resolved.shift,
               let sat = resolved.sat,
               let image = app.customMarkImage(shift: shift, sat: sat) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image("mark-\(resolved.isCustom ? "blue" : resolved.palette.key)")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}

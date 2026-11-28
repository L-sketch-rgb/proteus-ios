import SwiftUI
import ProteusKit

/// Animated dithered wave. The Metal color effect is the 1:1 port of
/// export/wave-dither/wave-dither.glsl; the flat bg colour sits underneath.
struct WaveBackground: View {
    let palette: Palette
    var animated: Bool = true
    /// 0...1, Settings → Appearance → Background intensity. 0.8 is the
    /// desktop default.
    var intensity: Double = 0.8

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var start = Date()

    private var mode: PaletteMode {
        palette.mode(dark: colorScheme == .dark)
    }

    var body: some View {
        GeometryReader { proxy in
            let paused = !animated || reduceMotion || scenePhase != .active
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
                let time = Float(max(0, context.date.timeIntervalSince(start)))
                let waves = mode.waves
                Rectangle()
                    .fill(Color.white)
                    .colorEffect(ShaderLibrary.waveDither(
                        .float2(Float(proxy.size.width), Float(proxy.size.height)),
                        .float(time),
                        .float(Float(min(1, max(0, intensity)))),
                        .float3(Float(waves[0].r), Float(waves[0].g), Float(waves[0].b)),
                        .float3(Float(waves[1].r), Float(waves[1].g), Float(waves[1].b)),
                        .float3(Float(waves[2].r), Float(waves[2].g), Float(waves[2].b)),
                        .float3(Float(waves[3].r), Float(waves[3].g), Float(waves[3].b))
                    ))
            }
        }
        .background(mode.background.color)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

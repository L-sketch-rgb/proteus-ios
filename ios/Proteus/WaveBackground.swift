import SwiftUI
import ProteusKit

/// Why the wave is (or is not) allowed to move right now.
///
/// The shader is GPU work for the full screen on every frame it ticks, so the
/// wave only animates when all of these hold: the screen is visible, the app
/// is active, Reduce Motion and Low Power Mode are off, the setting is on, and
/// nothing above it (a streaming transcript) asked it to hold still.
private final class PowerWatcher: ObservableObject {
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// A screen sets this to freeze the wave on its current frame (the chat does
/// while a reply is streaming, so the GPU and main thread go to the text).
private struct WaveFrozenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var waveFrozen: Bool {
        get { self[WaveFrozenKey.self] }
        set { self[WaveFrozenKey.self] = newValue }
    }
}

/// Animated dithered wave. The Metal color effect is the 1:1 port of
/// export/wave-dither/wave-dither.glsl; the flat bg colour sits underneath.
///
/// Performance rules (v19 fixes): one instance per screen, drawn *behind* the
/// scroll view and never inside a row; the drift is slow so it ticks at 12 fps
/// rather than 30; it stops entirely when its screen is covered by a pushed
/// screen or another tab (onDisappear), when the app is inactive, under Low
/// Power Mode and Reduce Motion, and while `waveFrozen` is set. A stopped wave
/// still draws its current frame once.
struct WaveBackground: View {
    let palette: Palette
    var animated: Bool = true
    /// 0...1, Settings → Appearance → Background intensity. 0.8 is the
    /// desktop default.
    var intensity: Double = 0.8

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.waveFrozen) private var frozen
    @StateObject private var power = PowerWatcher()

    @State private var start = Date()
    @State private var onScreen = true

    private var mode: PaletteMode {
        palette.mode(dark: colorScheme == .dark)
    }

    var body: some View {
        let paused = !animated || reduceMotion || power.lowPower || frozen
            || !onScreen || scenePhase != .active
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: paused)) { context in
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
        .accessibilityHidden(true)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}

/// The wave, wired to the same defaults Settings writes. One of these lives
/// **inside every tab**: iOS gives the tab controller its own opaque page
/// background, so a wave placed behind the `TabView` is never on screen at all
/// — which is why v18 and v19 shipped with no dither (docs/DECISIONS.md D55).
struct WaveBackdrop: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("proteus.palette") private var paletteKey = "blue"
    @AppStorage("proteus.animatedBackground") private var animatedBackground = true
    @AppStorage("proteus.backgroundIntensity") private var backgroundIntensity = 0.8

    var body: some View {
        WaveBackground(
            palette: app.resolvedPalette(for: paletteKey).palette,
            animated: animatedBackground,
            intensity: backgroundIntensity
        )
    }
}

/// One still frame of a palette's wave, at whatever size it is given.
///
/// The Appearance grid and the intensity preview use this instead of
/// `WaveBackground`: a dozen animated 30 fps shaders inside a list would spend
/// battery on a decoration (v19 §9). Being static also means it cannot keep
/// running when the screen is off-screen.
struct DitherSwatch: View {
    let palette: Palette
    var intensity: Double = 0.85

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let mode = palette.mode(dark: colorScheme == .dark)
        let waves = mode.waves
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.white)
                .colorEffect(ShaderLibrary.waveDither(
                    .float2(Float(proxy.size.width), Float(proxy.size.height)),
                    .float(0),
                    .float(Float(min(1, max(0, intensity)))),
                    .float3(Float(waves[0].r), Float(waves[0].g), Float(waves[0].b)),
                    .float3(Float(waves[1].r), Float(waves[1].g), Float(waves[1].b)),
                    .float3(Float(waves[2].r), Float(waves[2].g), Float(waves[2].b)),
                    .float3(Float(waves[3].r), Float(waves[3].g), Float(waves[3].b))
                ))
        }
        .background(mode.background.color)
    }
}

extension View {
    /// Puts the wave behind this screen.
    ///
    /// Applied **inside** every `NavigationStack`, never outside it: the stack's
    /// own container view paints `systemBackground` (black in dark, white in
    /// light), and the tab controller paints another one. A wave behind either
    /// of those is invisible — that was v18 and v19 (docs/DECISIONS.md D55).
    /// The wave ignores the safe area, so it also reaches under the nav bar and
    /// the tab bar, where the 0.80 chrome lets it read.
    func screenWave() -> some View {
        background { WaveBackdrop() }
    }
}

import SwiftUI

/// Interface size, shared with the desktop's 80–150 % slider (v8 §2). The
/// value is the percentage stored in UserDefaults; terminals scale their font
/// by the same fraction.
enum TextScale {
    static let key = "proteus.textScale"
    static let minimum = 80
    static let maximum = 150
    static let `default` = 100
}

/// Map the slider percentage onto SwiftUI's Dynamic Type ladder. The ladder is
/// discrete, so the nearest step is used; the terminal's own font scaling is
/// continuous.
func proteusDynamicTypeSize(percent: Int) -> DynamicTypeSize {
    switch percent {
    case ..<85: return .xSmall
    case ..<95: return .small
    case ..<105: return .medium
    case ..<115: return .large
    case ..<125: return .xLarge
    case ..<135: return .xxLarge
    case ..<145: return .xxxLarge
    case ..<155: return .accessibility1
    default: return .accessibility2
    }
}

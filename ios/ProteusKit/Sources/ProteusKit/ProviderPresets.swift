import Foundation

/// Provider presets offered by the iOS "Add provider" sheet. These mirror
/// `Hub::providerPresets()` in `linux/src/hub.cpp`; the labels and IDs are
/// identical so both clients explain the same accounts.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var summary: String
    /// Provider definition for the one-tap presets; nil for the custom and
    /// disabled entries.
    public var provider: ProviderConfig?
    public var accountLabel: String?
    public var isCustom: Bool
    public var isDisabled: Bool

    public init(
        id: String,
        label: String,
        summary: String,
        provider: ProviderConfig? = nil,
        accountLabel: String? = nil,
        isCustom: Bool = false,
        isDisabled: Bool = false
    ) {
        self.id = id
        self.label = label
        self.summary = summary
        self.provider = provider
        self.accountLabel = accountLabel
        self.isCustom = isCustom
        self.isDisabled = isDisabled
    }
}

public enum ProviderPresets {
    public static let anthropic = ProviderPreset(
        id: "anthropic-api",
        label: "Anthropic API",
        summary: "An API key from console.anthropic.com.",
        provider: ProviderConfig(id: "anthropic", kind: "anthropic-api", label: "Anthropic API"),
        accountLabel: "Anthropic API"
    )

    public static let deepSeek = ProviderPreset(
        id: "deepseek",
        label: "DeepSeek",
        summary: "Uses a DeepSeek API key (anthropic-compatible).",
        provider: ProviderConfig(
            id: "deepseek",
            kind: "anthropic-compatible",
            label: "DeepSeek",
            baseUrl: "https://api.deepseek.com/anthropic",
            sanitize: "deepseek",
            models: [
                ProviderModelConfig(key: "flash", engineModel: "deepseek-flash", label: "DeepSeek Flash", tier: "fast"),
            ]
        ),
        accountLabel: "DeepSeek"
    )

    public static let custom = ProviderPreset(
        id: "custom",
        label: "Custom Anthropic-compatible",
        summary: "Any endpoint that speaks the Anthropic Messages API.",
        isCustom: true
    )

    public static let openAI = ProviderPreset(
        id: "openai",
        label: "OpenAI (coming later)",
        summary: "Needs the Codex engine (P4).",
        isDisabled: true
    )

    public static let all: [ProviderPreset] = [anthropic, deepSeek, custom, openAI]
}

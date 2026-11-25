import Foundation

public struct ModelSection: Identifiable, Equatable, Sendable {
    public var provider: String
    public var title: String
    public var models: [ModelInfo]

    public var id: String { provider }

    public init(provider: String, title: String, models: [ModelInfo]) {
        self.provider = provider
        self.title = title
        self.models = models
    }
}

/// v5 menu shape: aliases at the top level (grouped by provider) and a
/// "More models" section for dated (pinned) or unavailable entries.
public struct ModelMenu: Equatable, Sendable {
    public var sections: [ModelSection]
    public var more: [ModelSection]

    public init(sections: [ModelSection] = [], more: [ModelSection] = []) {
        self.sections = sections
        self.more = more
    }

    public var isEmpty: Bool { sections.isEmpty && more.isEmpty }
}

/// The hub's model catalog. No hard-coded model names live in the app.
public final class ModelCatalog {
    public private(set) var models: [ModelInfo] = []
    public private(set) var defaultModel: String = ""
    public var onChange: (() -> Void)?

    public init(models: [ModelInfo] = [], defaultModel: String = "") {
        self.models = models
        self.defaultModel = defaultModel
    }

    public func replace(models: [ModelInfo]) {
        self.models = models
        onChange?()
    }

    public func replace(models: [ModelInfo], defaultModel: String) {
        self.models = models
        self.defaultModel = defaultModel
        onChange?()
    }

    public func setDefaultModel(_ id: String) {
        defaultModel = id
        onChange?()
    }

    public func model(id: String) -> ModelInfo? {
        models.first { $0.id == id }
    }

    public var defaultModelInfo: ModelInfo? { model(id: defaultModel) }

    /// The model id a new chat starts with, honouring a project default.
    public func newChatModel(project: ProjectDef?) -> String {
        if let projectModel = project?.defaultModel, !projectModel.isEmpty, model(id: projectModel) != nil {
            return projectModel
        }
        if !defaultModel.isEmpty { return defaultModel }
        return models.first(where: \.available)?.id ?? ""
    }

    /// Aliases (available, not pinned) top level; dated or unavailable below.
    public func menu() -> ModelMenu {
        var top: [String: [ModelInfo]] = [:]
        var topOrder: [String] = []
        var more: [String: [ModelInfo]] = [:]
        var moreOrder: [String] = []

        for model in models {
            let isAlias = model.available && model.pinned != true
            if isAlias {
                if top[model.provider] == nil { topOrder.append(model.provider) }
                top[model.provider, default: []].append(model)
            } else {
                if more[model.provider] == nil { moreOrder.append(model.provider) }
                more[model.provider, default: []].append(model)
            }
        }

        func sections(_ groups: [String: [ModelInfo]], _ order: [String]) -> [ModelSection] {
            order.map { provider in
                ModelSection(provider: provider, title: prettyProvider(provider), models: groups[provider] ?? [])
            }
        }

        return ModelMenu(
            sections: sections(top, topOrder),
            more: sections(more, moreOrder)
        )
    }

    public func prettyProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": return "Claude"
        case "deepseek": return "DeepSeek"
        case "anthropic": return "Anthropic"
        default:
            return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Why a menu item is greyed out, or nil when it is selectable.
    public func note(for model: ModelInfo) -> String? {
        guard !model.available else { return nil }
        switch model.unavailableReason {
        case "credits": return "Needs usage credits"
        case "unavailable": return "Unavailable"
        default: return "Unavailable"
        }
    }

    /// The label to show for any stored id, even one no longer in the catalog.
    public func label(for id: String) -> String {
        if let model = model(id: id) { return model.label }
        return id.isEmpty ? "—" : "\(id) (unavailable)"
    }

    public func isSelectable(id: String) -> Bool {
        model(id: id)?.available ?? false
    }
}

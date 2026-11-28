import Foundation

/// Project pins, kept on this phone for now
/// (docs/design/v19-ios-shell.md §2.4).
///
/// The hub has no project-pin field yet: pins are a device preference stored in
/// `UserDefaults`, capped at `maximum` so the grid can never be pushed off the
/// screen. When the hub learns to carry a project pin, this becomes the cache
/// in front of it and nothing in the views has to change.
enum PinnedProjects {
    static let key = "proteus.pinnedProjects"
    static let maximum = 4

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    static func encode(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

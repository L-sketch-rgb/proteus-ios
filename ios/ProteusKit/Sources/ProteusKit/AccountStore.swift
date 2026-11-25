import Foundation

/// Accounts and the one global active Claude account. Usage windows that the
/// hub does not know are shown as "—", never as 0%.
public final class AccountStore {
    public private(set) var accounts: [Account] = []
    public private(set) var active: String = ""
    public var onChange: (() -> Void)?

    public init() {}

    public func replace(accounts: [Account], active: String) {
        self.accounts = accounts
        self.active = active
        onChange?()
    }

    public func replace(accounts: [Account]) {
        self.accounts = accounts
        onChange?()
    }

    public func setActive(_ name: String) {
        active = name
        onChange?()
    }

    public func account(named name: String) -> Account? {
        accounts.first { $0.name == name }
    }

    public var activeAccount: Account? {
        account(named: active)
    }

    public func accounts(forProvider provider: String) -> [Account] {
        accounts.filter { ($0.provider ?? "claude") == provider }
    }

    /// Provider ids in first-seen order.
    public var providers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for account in accounts {
            let provider = account.provider ?? "claude"
            if seen.insert(provider).inserted { out.append(provider) }
        }
        return out
    }

    /// The active account of a provider. The protocol's `accounts` frame only
    /// carries the global `active` name (today that is the Claude provider);
    /// other providers' active accounts are not reported to apps, so this
    /// returns nil for them rather than guessing.
    public func activeAccount(forProvider provider: String) -> Account? {
        guard let account = activeAccount else { return nil }
        return (account.provider ?? "claude") == provider ? account : nil
    }

    /// Usage rows for Settings: always both windows, "—" when absent.
    public func usageRows(for account: Account) -> (fiveHour: String, sevenDay: String) {
        (
            Formatting.percent(account.usage?.fiveHour),
            Formatting.percent(account.usage?.sevenDay)
        )
    }

    /// The masked hint shown after a key is stored (the key never reaches the app).
    public func keyHint(for account: Account) -> String? {
        guard let hint = account.keyHint, !hint.isEmpty else { return nil }
        return "…\(hint)"
    }
}

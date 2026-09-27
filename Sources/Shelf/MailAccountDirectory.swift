import Foundation

struct MailAccountDirectory: Sendable {
    struct Account: Sendable {
        var id: String
        var name: String
    }

    var accounts: [Account] = []

    private static func normalizedID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString ?? value
    }

    static func sameID(_ lhs: String, _ rhs: String) -> Bool {
        normalizedID(lhs) == normalizedID(rhs)
    }

    func including(_ context: MailMessageContext) -> Self {
        guard let name = context.currentAccount, !name.isEmpty,
              Set(context.selection.map { Self.normalizedID($0.accountID) }).count == 1,
              let id = context.selection.first?.accountID, !id.isEmpty, id != "local",
              !accounts.contains(where: { Self.normalizedID($0.id) == Self.normalizedID(id) }) else { return self }
        return Self(accounts: accounts + [.init(id: id, name: name)])
    }

    func canonicalHint(_ hint: String?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        let id = Self.normalizedID(hint)
        if accounts.contains(where: { Self.normalizedID($0.id) == id }) { return id }
        let matches = Set(accounts.filter { $0.name == hint }.map { Self.normalizedID($0.id) })
        // Names are aliases only when unambiguous. Never merge accounts by folder name.
        if matches.count == 1 { return matches.first }
        return matches.isEmpty && hint == "Mailboxes" ? "local" : id
    }

    func displayName(for hint: String?) -> String? {
        guard let id = canonicalHint(hint) else { return nil }
        if id == "local" { return "On My Mac" }
        guard let account = accounts.first(where: { Self.normalizedID($0.id) == id }) else { return nil }
        let aliases = Set(accounts.filter { $0.name == account.name }.map { Self.normalizedID($0.id) })
        return aliases.count > 1 ? "\(account.name) (\(id))" : account.name
    }
}

// A bounded account-only read, separate from the longer mailbox/header scan actor.
actor MailAccountResolver {
    static let shared = MailAccountResolver()
    private let bridge = MailApplicationBridge()
    private var cached = MailAccountDirectory()
    private var nextRefresh = Date.distantPast

    func directory() -> MailAccountDirectory {
        guard !Task.isCancelled, Date() >= nextRefresh else { return cached }
        if let directory = bridge.accountDirectory() {
            cached = directory
            nextRefresh = Date().addingTimeInterval(60)
        } else {
            nextRefresh = Date().addingTimeInterval(10)
        }
        return cached
    }
}

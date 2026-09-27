import Foundation

struct MailDestinationKey: Hashable {
    let account: String?
    let path: [String]
    init(_ location: RankedMessageLocation) { account = location.accountHint; path = location.mailboxPath }
}

struct MailDestinationCache {
    struct Entry {
        let identity: MailDestinationIdentity?
        let createdAt: Date
    }
    private(set) var entries: [MailDestinationKey: Entry] = [:]
    let capacity: Int
    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    mutating func lookup(_ key: MailDestinationKey, now: Date = Date()) -> Entry? {
        guard let entry = entries[key] else { return nil }
        let age = now.timeIntervalSince(entry.createdAt)
        guard age >= 0, age < (entry.identity == nil ? 10 : 60) else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    mutating func insert(_ identity: MailDestinationIdentity?, for key: MailDestinationKey, now: Date = Date()) {
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            entries[oldest] = nil
        }
        entries[key] = Entry(identity: identity, createdAt: now)
    }

    mutating func invalidate(_ key: MailDestinationKey) { entries[key] = nil }
}

protocol MailActionServicing: Sendable {
    func destinationIdentity(for location: RankedMessageLocation) async -> MailDestinationIdentity?
    func move(to location: RankedMessageLocation, selection: [MailMessageIdentity], destination: MailDestinationIdentity?) async -> MailBridgeResult
}

/// Synchronous Apple Events must never execute on the UI actor.
actor MailActionService: MailActionServicing {
    static let shared = MailActionService()
    private let bridge = MailApplicationBridge()
    private var destinations = MailDestinationCache()

    func destinationIdentity(for location: RankedMessageLocation) -> MailDestinationIdentity? {
        guard !Task.isCancelled else { return nil }
        let key = MailDestinationKey(location)
        if let cached = destinations.lookup(key) { return cached.identity }
        let destination = bridge.destinationIdentity(for: location)
        guard !Task.isCancelled else { return nil }
        destinations.insert(destination, for: key)
        if let destination {
            var resolved = location
            resolved.accountHint = destination.accountID
            resolved.mailboxPath = destination.path
            destinations.insert(destination, for: MailDestinationKey(resolved))
        }
        return destination
    }

    func resolve(_ locations: [RankedMessageLocation]) -> [MailDestinationKey: MailDestinationIdentity] {
        let deadline = Date().addingTimeInterval(2)
        var resolved: [MailDestinationKey: MailDestinationIdentity] = [:]
        var reads = 0
        for location in locations.prefix(40) {
            guard !Task.isCancelled else { break }
            let key = MailDestinationKey(location)
            if let cached = destinations.lookup(key) {
                if let identity = cached.identity { resolved[key] = identity }
                continue
            }
            guard reads < 16, Date() < deadline else { continue }
            reads += 1
            if let identity = destinationIdentity(for: location) { resolved[key] = identity }
        }
        return resolved
    }

    func move(to location: RankedMessageLocation, selection: [MailMessageIdentity], destination: MailDestinationIdentity?) -> MailBridgeResult {
        guard !Task.isCancelled else { return .init(output: "", error: "Move cancelled.") }
        // The bridge re-resolves the destination and verifies the selection before moving.
        destinations.invalidate(MailDestinationKey(location))
        return bridge.moveSelectedMessages(to: location, expectedSelection: selection, destination: destination)
    }
}

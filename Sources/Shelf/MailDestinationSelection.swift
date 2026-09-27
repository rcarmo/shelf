import Foundation

enum MailDestinationSelection {
    static func resolved(_ suggestions: MailSuggestions,
                         identities: [MailDestinationKey: MailDestinationIdentity],
                         accounts: MailAccountDirectory, context: MailMessageContext) -> MailSuggestions {
        var order: [MailDestinationIdentity] = []
        var grouped: [MailDestinationIdentity: MailFolderEvidence] = [:]
        for evidence in suggestions.decisionEvidence {
            guard let identity = identities[MailDestinationKey(evidence.location)],
                  MailFilingRetrieval.isDestination(identity.path, currentMailbox: context.currentMailbox) else { continue }
            var location = evidence.location
            location.accountHint = identity.accountID
            location.accountDisplayName = accounts.displayName(for: identity.accountID)
            location.mailboxPath = identity.path
            var records = evidence.records
            var visibleCount = evidence.visibleRelatedCount
            if let previous = grouped[identity] {
                location = previous.location
                location.score = max(location.score, evidence.location.score)
                location.semanticScore = max(location.semanticScore, evidence.location.semanticScore)
                records = previous.records + records
                visibleCount = max(visibleCount, previous.visibleRelatedCount)
            } else {
                order.append(identity)
            }
            var seen = Set<String>()
            records = records.filter { seen.insert($0.sourceID).inserted }
            let messages = records.filter { !$0.isLearnedMove }
            location.hitCount = max(messages.count, records.contains(where: \.isLearnedMove) ? 1 : 0)
            location.senderHitCount = messages.filter(\.sameSender).count
            location.threadHitCount = messages.filter(\.sameThread).count
            let recent = Date().addingTimeInterval(-90 * 24 * 60 * 60)
            location.recentHitCount = messages.filter { ($0.date ?? .distantPast) >= recent }.count
            grouped[identity] = .init(location: location, records: records, visibleRelatedCount: visibleCount, ambiguousAccount: false)
        }
        var result = suggestions
        result.decisionEvidence = order.compactMap { grouped[$0] }
        result.locations = Array(result.decisionEvidence.prefix(5).map(\.location))
        let unresolved = suggestions.decisionEvidence.filter { identities[MailDestinationKey($0.location)] == nil }.count
        result.diagnostic += " \(result.locations.count) verified move destination(s); \(unresolved) unresolved candidate(s)."
        return result
    }
}

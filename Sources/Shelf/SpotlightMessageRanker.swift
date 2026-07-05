import Foundation
import LatentSemanticMapping

final class SpotlightMessageRanker {
    private let maximumResults = 80
    private let maximumTrainingMessagesPerMailbox = 8
    private let spotlightCacheLifetime: TimeInterval = 180
    private let excludedMailboxNames: Set<String> = [
        "deleted items", "deleted messages", "trash", "bin", "junk", "junk email", "spam"
    ]
    private var spotlightCache: [String: (createdAt: Date, candidates: [MessageCandidate], diagnostic: String)] = [:]

    func quickSimilarMessages(for context: MailMessageContext) async -> [SimilarMessage] {
        let senderNeedle = normalizedSender(context.senderEmail ?? context.sender)
        guard !senderNeedle.isEmpty else {
            return []
        }

        let candidates = await MailHeaderCache.shared.cachedCandidates(
            for: context,
            terms: context.searchTerms.filter { !$0.isEmpty },
            limit: 12
        )
        return similarMessages(from: rankedCandidates(candidates), context: context)
    }

    func suggestions(for context: MailMessageContext) async -> MailSuggestions {
        let senderNeedle = normalizedSender(context.senderEmail ?? context.sender)
        guard !senderNeedle.isEmpty else {
            return .empty
        }
        let terms = context.searchTerms.filter { !$0.isEmpty }

        let result = await spotlightCandidates(for: context, terms: terms)
        let learnedCandidates = await learnedMoveCandidates(for: context, limit: 8)
        let candidates = rankedCandidates(learnedCandidates + result.candidates)

        guard !candidates.isEmpty else {
            return MailSuggestions(
                locations: [],
                messages: [],
                diagnostic: result.diagnostic,
                requiresFullDiskAccess: result.requiresFullDiskAccess
            )
        }

        let locations = groupedLocations(from: candidates, currentMailbox: context.currentMailbox, context: context)
        let messages = similarMessages(from: candidates, context: context)
        return MailSuggestions(
            locations: locations,
            messages: messages,
            diagnostic: "\(result.diagnostic) Learned LSM ranked \(learnedCandidates.count) destination\(learnedCandidates.count == 1 ? "" : "s"). LSM ranked \(locations.count) filing destination\(locations.count == 1 ? "" : "s").",
            requiresFullDiskAccess: result.requiresFullDiskAccess
        )
    }

    private func spotlightCandidates(for context: MailMessageContext, terms: [String]) async -> (candidates: [MessageCandidate], diagnostic: String, requiresFullDiskAccess: Bool) {
        let needle = normalizedSender(context.senderEmail ?? context.sender)
        let cacheKey = ([needle] + terms.map { $0.lowercased() }.sorted()).joined(separator: "|")
        if let cached = spotlightCache[cacheKey],
           !cached.candidates.isEmpty,
           Date().timeIntervalSince(cached.createdAt) < spotlightCacheLifetime {
            return (cached.candidates, "\(cached.diagnostic) Cached.", false)
        }

        async let semanticMetadataSearch = SpotlightMailQuery.search(context: context, terms: terms, limit: maximumResults, mode: .semantic)
        async let globalHeaderSearch = MailHeaderCache.shared.globalCandidates(for: context, terms: terms, limit: maximumResults)
        async let senderMetadataSearch = SpotlightMailQuery.search(context: context, terms: terms, limit: maximumResults, mode: .sender)
        async let senderHeaderSearch = MailHeaderCache.shared.candidates(for: context, terms: terms, limit: maximumResults)
        let (semanticMetadataCandidates, globalHeaderCandidates, senderMetadataCandidates, senderHeaderCandidates) = await (
            semanticMetadataSearch,
            globalHeaderSearch,
            senderMetadataSearch,
            senderHeaderSearch
        )

        var merged: [MessageCandidate] = []
        var indexByPath: [String: Int] = [:]
        for candidate in semanticMetadataCandidates + globalHeaderCandidates + senderMetadataCandidates + senderHeaderCandidates.candidates {
            if let existingIndex = indexByPath[candidate.path] {
                merged[existingIndex] = mergedCandidate(merged[existingIndex], candidate)
                continue
            }
            var ranked = candidate
            ranked.rank = merged.count + 1
            indexByPath[ranked.path] = merged.count
            merged.append(ranked)
            if merged.count >= maximumResults * 4 {
                break
            }
        }

        let diagnostics = [
            semanticMetadataCandidates.isEmpty
                ? nil
                : "Spotlight semantic returned \(semanticMetadataCandidates.count) email candidate\(semanticMetadataCandidates.count == 1 ? "" : "s").",
            globalHeaderCandidates.isEmpty
                ? nil
                : "Global header search returned \(globalHeaderCandidates.count) topic candidate\(globalHeaderCandidates.count == 1 ? "" : "s").",
            senderMetadataCandidates.isEmpty
                ? nil
                : "Spotlight sender returned \(senderMetadataCandidates.count) email candidate\(senderMetadataCandidates.count == 1 ? "" : "s").",
            senderHeaderCandidates.diagnostic
        ]
        .compactMap { $0 }

        let diagnostic = diagnostics.isEmpty
            ? "Spotlight returned no Mail metadata candidates for \(needle)."
            : diagnostics.joined(separator: " ")

        if !merged.isEmpty {
            spotlightCache[cacheKey] = (Date(), merged, diagnostic)
        }
        return (merged, diagnostic, senderHeaderCandidates.requiresFullDiskAccess)
    }

    private func mergedCandidate(_ existing: MessageCandidate, _ incoming: MessageCandidate) -> MessageCandidate {
        var merged = existing
        if incoming.bodyPreview.count > existing.bodyPreview.count {
            merged.bodyPreview = incoming.bodyPreview
        }
        if merged.header.subject == nil {
            merged.header.subject = incoming.header.subject
        }
        if merged.header.sender == nil {
            merged.header.sender = incoming.header.sender
        }
        if merged.header.date == nil {
            merged.header.date = incoming.header.date
        }
        merged.supportsMailFiling = existing.supportsMailFiling || incoming.supportsMailFiling
        merged.contributesSimilarMessage = existing.contributesSimilarMessage || incoming.contributesSimilarMessage
        if merged.mailboxInfo.mailboxPath == ["Mail"], incoming.mailboxInfo.mailboxPath != ["Mail"] {
            merged.mailboxInfo = incoming.mailboxInfo
        }
        return merged
    }

    private func learnedMoveCandidates(for context: MailMessageContext, limit: Int) async -> [MessageCandidate] {
        let recommendations = await MailMoveLearningStore.shared.recommendations(for: context, limit: limit)
        return recommendations.enumerated().map { index, recommendation in
            MessageCandidate(
                path: "shelf-learning://\(recommendation.displayPath)",
                rank: index + 1,
                supportsMailFiling: true,
                contributesSimilarMessage: false,
                mailboxInfo: MailboxInfo(mailboxPath: recommendation.mailboxPath, accountHint: recommendation.accountHint),
                header: MessageHeader(
                    subject: "Learned move to \(recommendation.displayPath)",
                    sender: nil,
                    date: Date(timeIntervalSince1970: recommendation.lastMovedAt)
                ),
                bodyPreview: recommendation.sampleText
            )
        }
    }

    private func rankedCandidates(_ candidates: [MessageCandidate]) -> [MessageCandidate] {
        var seenLearnedDestinations = Set<String>()
        var ranked: [MessageCandidate] = []

        for candidate in candidates {
            if !candidate.contributesSimilarMessage {
                let key = candidate.mailboxInfo.mailboxPath.joined(separator: "\u{1F}")
                guard seenLearnedDestinations.insert(key).inserted else {
                    continue
                }
            }
            var candidate = candidate
            candidate.rank = ranked.count + 1
            ranked.append(candidate)
        }

        return ranked
    }

    private func groupedLocations(from candidates: [MessageCandidate], currentMailbox: String, context: MailMessageContext) -> [RankedMessageLocation] {
        let usableCandidates = candidates.filter {
            $0.supportsMailFiling && !isExcludedMailbox($0.mailboxInfo.mailboxPath)
        }
        let semanticScores = semanticScores(for: usableCandidates, context: context)
        let similarBackedLocations = groupedLocations(
            from: usableCandidates.filter(\.contributesSimilarMessage),
            semanticScores: semanticScores,
            allowCatalogBoost: false
        )

        if !similarBackedLocations.isEmpty {
            let strongLearnedLocations = groupedLocations(
                from: usableCandidates.filter { $0.isLearnedMoveCandidate },
                semanticScores: semanticScores,
                allowCatalogBoost: false
            )
            .filter { $0.semanticScore >= 0.12 }

            return rankedLocations(similarBackedLocations + strongLearnedLocations, preferHitCount: true)
        }

        let fallbackLocations = groupedLocations(
            from: usableCandidates.filter { !$0.contributesSimilarMessage },
            semanticScores: semanticScores,
            allowCatalogBoost: false
        )
        .filter { $0.semanticScore >= 0.18 || $0.hitCount > 1 }

        return rankedLocations(fallbackLocations, preferHitCount: false)
    }

    private func groupedLocations(
        from candidates: [MessageCandidate],
        semanticScores: [String: Double],
        allowCatalogBoost: Bool
    ) -> [RankedMessageLocation] {
        var grouped: [String: RankedMessageLocation] = [:]

        for candidate in candidates {
            let displayPath = candidate.mailboxInfo.mailboxPath.joined(separator: " / ")
            let semanticScore = semanticScores[displayPath] ?? 0
            let catalogBoost = !candidate.contributesSimilarMessage && allowCatalogBoost ? Double(maximumResults / 3) : 0
            let similarHitBoost = candidate.contributesSimilarMessage ? Double(maximumResults / 3) : 0
            let relevance = Double(max(1, maximumResults - candidate.rank + 1)) + (semanticScore * Double(maximumResults)) + catalogBoost + similarHitBoost
            if var existing = grouped[displayPath] {
                existing.hitCount += 1
                existing.score = candidate.contributesSimilarMessage
                    ? existing.score + relevance
                    : max(existing.score, relevance)
                existing.semanticScore = max(existing.semanticScore, semanticScore)
                grouped[displayPath] = existing
            } else {
                grouped[displayPath] = RankedMessageLocation(
                    mailboxPath: candidate.mailboxInfo.mailboxPath,
                    accountHint: appleScriptAccountHint(candidate.mailboxInfo.accountHint),
                    score: relevance,
                    semanticScore: semanticScore,
                    hitCount: 1,
                    samplePath: candidate.path
                )
            }
        }

        return Array(grouped.values)
    }

    private func rankedLocations(_ locations: [RankedMessageLocation], preferHitCount: Bool) -> [RankedMessageLocation] {
        var merged: [String: RankedMessageLocation] = [:]
        for location in locations {
            if var existing = merged[location.displayPath] {
                existing.hitCount += location.hitCount
                existing.score += location.score
                existing.semanticScore = max(existing.semanticScore, location.semanticScore)
                merged[location.displayPath] = existing
            } else {
                merged[location.displayPath] = location
            }
        }

        return merged.values
            .sorted {
                if preferHitCount, $0.hitCount != $1.hitCount {
                    return $0.hitCount > $1.hitCount
                }
                let lhsScore = $0.score + min(Double($0.hitCount), 8) * 8
                let rhsScore = $1.score + min(Double($1.hitCount), 8) * 8
                if lhsScore == rhsScore {
                    return $0.hitCount > $1.hitCount
                }
                return lhsScore > rhsScore
            }
            .prefix(5)
            .map { $0 }
    }

    private func appleScriptAccountHint(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        return value
    }

    private func similarMessages(from candidates: [MessageCandidate], context: MailMessageContext) -> [SimilarMessage] {
        var seen = Set<String>()
        let scored = candidates.compactMap { candidate -> (candidate: MessageCandidate, score: Double, strict: Bool)? in
            guard candidate.contributesSimilarMessage,
                  !isExcludedMailbox(candidate.mailboxInfo.mailboxPath),
                  seen.insert(dedupeKey(for: candidate)).inserted else {
                return nil
            }
            let score = relatedMessageScore(candidate, context: context)
            let strict = score >= relatedMessageMinimumScore(candidate, context: context)
            guard strict || relaxedRelatedMessageFallback(candidate, context: context, score: score) else {
                return nil
            }

            return (candidate, score, strict)
        }

        let strictMatches = scored.filter(\.strict)
        let displayMatches = strictMatches.isEmpty ? scored : strictMatches

        return displayMatches
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return (lhs.candidate.header.date ?? .distantPast) > (rhs.candidate.header.date ?? .distantPast)
            }
            return lhs.score > rhs.score
        }
        .prefix(10)
        .map { item in
            let candidate = item.candidate
            return SimilarMessage(
                subject: candidate.header.subject ?? URL(fileURLWithPath: candidate.path).deletingPathExtension().lastPathComponent,
                sender: candidate.header.sender ?? "Unknown Sender",
                date: candidate.header.date,
                mailboxPath: candidate.mailboxInfo.mailboxPath,
                path: candidate.path,
                rank: candidate.rank
            )
        }
    }

    private func relatedMessageScore(_ candidate: MessageCandidate, context: MailMessageContext) -> Double {
        let contextSender = normalizedSender(context.senderEmail ?? context.sender)
        let candidateSender = normalizedSender(candidate.header.sender ?? "")
        let contextDomain = contextSender.split(separator: "@").last.map(String.init) ?? ""
        let candidateText = [
            candidate.header.sender ?? "",
            candidate.header.subject ?? "",
            candidate.bodyPreview,
            candidate.mailboxInfo.mailboxPath.joined(separator: " ")
        ]
        .joined(separator: "\n")
        .lowercased()

        let contextSubjectTerms = Set(SubjectTokenizer.terms(from: context.subject, limit: 10))
        let candidateSubjectTerms = Set(SubjectTokenizer.terms(from: candidate.header.subject ?? "", limit: 10))
        let subjectIntersection = contextSubjectTerms.intersection(candidateSubjectTerms)
        let subjectUnion = contextSubjectTerms.union(candidateSubjectTerms)

        let contextBodyTerms = Set(SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
        let candidateBodyTerms = Set(SubjectTokenizer.terms(from: candidate.bodyPreview, limit: 24))
        let bodyIntersection = contextBodyTerms.intersection(candidateBodyTerms)
        let bodyUnion = contextBodyTerms.union(candidateBodyTerms)

        let mailboxTerms = Set(SubjectTokenizer.terms(from: candidate.mailboxInfo.mailboxPath.joined(separator: " "), limit: 8))
        let contextTerms = Set(context.searchTerms.filter { $0.count >= 4 && !$0.contains("@") && !$0.contains(".") })
        let mailboxIntersection = mailboxTerms.intersection(contextTerms)

        var score = 0.0
        let sameSender = !contextSender.isEmpty && candidateSender == contextSender
        if sameSender {
            score += 18
        } else if !contextSender.isEmpty && candidateText.contains(contextSender) {
            score += 10
        }
        if !contextDomain.isEmpty, candidateText.contains(contextDomain) {
            score += 5
        }

        let contextSubject = normalizedSubject(context.subject)
        let candidateSubject = normalizedSubject(candidate.header.subject ?? "")
        if !contextSubject.isEmpty, contextSubject == candidateSubject {
            score += 70
        }

        score += Double(subjectIntersection.count) * 14
        if !subjectUnion.isEmpty {
            score += (Double(subjectIntersection.count) / Double(subjectUnion.count)) * 50
        }

        score += Double(min(bodyIntersection.count, 6)) * 5
        if !bodyUnion.isEmpty {
            score += (Double(bodyIntersection.count) / Double(bodyUnion.count)) * 25
        }

        score += Double(min(mailboxIntersection.count, 3)) * 4

        if hasRelatedTextSignal(candidate, context: context) {
            score += Double(max(0, min(8, maximumResults - candidate.rank)))
        }

        return score
    }

    private func relatedMessageMinimumScore(_ candidate: MessageCandidate, context: MailMessageContext) -> Double {
        guard hasRelatedTextSignal(candidate, context: context) else {
            return 36
        }
        let sameSender = normalizedSender(candidate.header.sender ?? "") == normalizedSender(context.senderEmail ?? context.sender)
        return sameSender ? 22 : 30
    }

    private func relaxedRelatedMessageFallback(_ candidate: MessageCandidate, context: MailMessageContext, score: Double) -> Bool {
        let contextSender = normalizedSender(context.senderEmail ?? context.sender)
        let candidateSender = normalizedSender(candidate.header.sender ?? "")
        guard !contextSender.isEmpty else {
            return false
        }

        if candidateSender == contextSender {
            return score >= 18
        }

        guard let contextDomain = contextSender.split(separator: "@").last,
              let candidateDomain = candidateSender.split(separator: "@").last else {
            return false
        }
        return contextDomain == candidateDomain && score >= 20
    }

    private func hasRelatedTextSignal(_ candidate: MessageCandidate, context: MailMessageContext) -> Bool {
        let contextSubject = normalizedSubject(context.subject)
        let candidateSubject = normalizedSubject(candidate.header.subject ?? "")
        if !contextSubject.isEmpty, contextSubject == candidateSubject {
            return true
        }

        let subjectOverlap = Set(SubjectTokenizer.terms(from: context.subject, limit: 10))
            .intersection(Set(SubjectTokenizer.terms(from: candidate.header.subject ?? "", limit: 10)))
        if !subjectOverlap.isEmpty {
            return true
        }

        let bodyOverlap = Set(SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
            .intersection(Set(SubjectTokenizer.terms(from: candidate.bodyPreview, limit: 24)))
        if bodyOverlap.count >= 2 {
            return true
        }

        let mailboxOverlap = Set(SubjectTokenizer.terms(from: candidate.mailboxInfo.mailboxPath.joined(separator: " "), limit: 8))
            .intersection(Set(context.searchTerms.filter { $0.count >= 4 && !$0.contains("@") && !$0.contains(".") }))
        return !mailboxOverlap.isEmpty
    }

    private func normalizedSubject(_ value: String) -> String {
        var subject = value.lowercased()
        while true {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("re:") {
                subject = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("fw:") {
                subject = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("fwd:") {
                subject = String(trimmed.dropFirst(4))
            } else {
                subject = trimmed
                break
            }
        }
        return subject
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .joined(separator: " ")
    }

    private func isExcludedMailbox(_ mailboxPath: [String]) -> Bool {
        mailboxPath.contains { excludedMailboxNames.contains($0.lowercased()) }
    }

    private func dedupeKey(for candidate: MessageCandidate) -> String {
        [
            candidate.header.subject ?? "",
            candidate.header.sender ?? "",
            candidate.header.date.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "",
            candidate.mailboxInfo.mailboxPath.joined(separator: "/")
        ]
        .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "|")
    }

    private func semanticScores(for candidates: [MessageCandidate], context: MailMessageContext) -> [String: Double] {
        let grouped = Dictionary(grouping: candidates) { $0.mailboxInfo.mailboxPath.joined(separator: " / ") }
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard grouped.count > 1 else {
            return [:]
        }

        let map = LSMMapCreate(nil, CFOptionFlags(kLSMMapPairs)).takeRetainedValue()
        guard LSMMapStartTraining(map) == noErr else {
            return [:]
        }

        var categoryByPath: [String: LSMCategory] = [:]
        var pathByCategory: [LSMCategory: String] = [:]

        for (displayPath, mailboxCandidates) in grouped {
            let category = LSMMapAddCategory(map)
            categoryByPath[displayPath] = category
            pathByCategory[category] = displayPath

            for candidate in mailboxCandidates.prefix(maximumTrainingMessagesPerMailbox) {
                let text = LSMTextCreate(nil, map).takeRetainedValue()
                let content = trainingText(for: candidate) as CFString
                if LSMTextAddWords(text, content, nil, 0) == noErr {
                    _ = LSMMapAddText(map, text, category)
                }
            }
        }

        guard !categoryByPath.isEmpty, LSMMapCompile(map) == noErr else {
            return [:]
        }

        let sample = LSMTextCreate(nil, map).takeRetainedValue()
        guard LSMTextAddWords(sample, context.semanticText as CFString, nil, 0) == noErr else {
            return [:]
        }

        let result = LSMResultCreate(nil, map, sample, CFIndex(categoryByPath.count), 0).takeRetainedValue()
        var scores: [String: Double] = [:]
        for index in 0..<LSMResultGetCount(result) {
            let category = LSMResultGetCategory(result, index)
            guard let path = pathByCategory[category] else {
                continue
            }
            let score = Double(LSMResultGetScore(result, index))
            if score.isFinite {
                scores[path] = score
            }
        }
        return scores
    }

    private func trainingText(for candidate: MessageCandidate) -> String {
        [
            candidate.header.sender ?? "",
            candidate.header.subject ?? "",
            candidate.bodyPreview
        ].joined(separator: "\n")
    }

    private func mailboxInfo(from path: String) -> MailboxInfo? {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        let mailboxPath = components
            .filter { $0.hasSuffix(".mbox") }
            .map(cleanMailboxName)

        guard !mailboxPath.isEmpty else {
            return nil
        }

        let accountHint = accountComponent(in: components)
        return MailboxInfo(mailboxPath: mailboxPath, accountHint: accountHint)
    }

    private func normalizedSender(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func accountComponent(in components: [String]) -> String? {
        guard let versionIndex = components.firstIndex(where: { component in
            component.range(of: #"^V\d+$"#, options: .regularExpression) != nil
        }) else {
            return nil
        }

        let accountIndex = components.index(after: versionIndex)
        guard components.indices.contains(accountIndex) else {
            return nil
        }
        return components[accountIndex]
    }

    private func cleanMailboxName(_ component: String) -> String {
        let stripped = String(component.dropLast(".mbox".count))
        return stripped.removingPercentEncoding ?? stripped
    }

    private func readMessage(path: String) -> (header: MessageHeader, bodyPreview: String) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return (MessageHeader(subject: nil, sender: nil, date: nil), "")
        }
        defer {
            try? handle.close()
        }

        let data = handle.readData(ofLength: 64 * 1024)
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (MessageHeader(subject: nil, sender: nil, date: nil), "")
        }

        let parts = splitMessage(raw)
        let headerText = parts.header
        let headers = unfoldedHeaders(from: headerText)
        let subject = headers["subject"].map(decodeHeaderValue)
        let sender = headers["from"].map(decodeHeaderValue)
        let date = headers["date"].flatMap { DateFormatter.rfc2822.date(from: $0) }
        let header = MessageHeader(subject: subject, sender: sender, date: date)
        return (header, String(parts.body.prefix(6000)))
    }

    private func splitMessage(_ raw: String) -> (header: String, body: String) {
        if let range = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (raw, "")
    }

    private func unfoldedHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                break
            }
            if line.first == " " || line.first == "\t", let currentKey {
                headers[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            currentKey = key
        }

        return headers
    }

    private func decodeHeaderValue(_ value: String) -> String {
        MIMEHeaderDecoder.decode(value)
    }

}

private struct MailboxInfo {
    var mailboxPath: [String]
    var accountHint: String?
}

private struct MessageHeader {
    var subject: String?
    var sender: String?
    var date: Date?
}

private struct MessageCandidate {
    var path: String
    var rank: Int
    var supportsMailFiling: Bool
    var contributesSimilarMessage: Bool
    var mailboxInfo: MailboxInfo
    var header: MessageHeader
    var bodyPreview: String

    var isLearnedMoveCandidate: Bool {
        path.hasPrefix("shelf-learning://")
    }
}

private enum MIMEHeaderDecoder {
    private static let encodedWordPattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#

    static func decode(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("=?"),
              let regex = try? NSRegularExpression(pattern: encodedWordPattern) else {
            return collapseSpaces(normalized)
        }

        let nsValue = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        let matches = regex.matches(in: normalized, range: fullRange)
        guard !matches.isEmpty else {
            return collapseSpaces(normalized)
        }

        var output = ""
        var cursor = 0
        var previousWasEncoded = false

        for match in matches {
            let plainRange = NSRange(location: cursor, length: match.range.location - cursor)
            if plainRange.length > 0 {
                let plain = nsValue.substring(with: plainRange)
                if !(previousWasEncoded && plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    output += plain
                }
            }

            if let decoded = decodeEncodedWord(match: match, in: nsValue) {
                output += decoded
                previousWasEncoded = true
            } else {
                output += nsValue.substring(with: match.range)
                previousWasEncoded = false
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsValue.length {
            output += nsValue.substring(from: cursor)
        }

        return collapseSpaces(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodeEncodedWord(match: NSTextCheckingResult, in value: NSString) -> String? {
        guard match.numberOfRanges == 4 else {
            return nil
        }
        let charset = value.substring(with: match.range(at: 1))
        let encoding = value.substring(with: match.range(at: 2)).lowercased()
        let payload = value.substring(with: match.range(at: 3))

        let data: Data?
        switch encoding {
        case "b":
            data = Data(base64Encoded: payload)
        case "q":
            data = qEncodedData(payload)
        default:
            data = nil
        }

        guard let data else {
            return nil
        }
        return string(from: data, charset: charset)
    }

    private static func qEncodedData(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "_") {
                decoded.append(UInt8(ascii: " "))
                index += 1
                continue
            }
            if byte == UInt8(ascii: "="),
               index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]),
               let low = hexValue(bytes[index + 2]) {
                decoded.append((high << 4) + low)
                index += 3
                continue
            }
            decoded.append(byte)
            index += 1
        }

        return Data(decoded)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }

    private static func string(from data: Data, charset: String) -> String? {
        let normalizedCharset = charset
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? charset.lowercased()

        let encoding: String.Encoding?
        switch normalizedCharset {
        case "utf-8", "utf8":
            encoding = .utf8
        case "us-ascii", "ascii":
            encoding = .ascii
        case "iso-8859-1", "latin1", "latin-1":
            encoding = .isoLatin1
        case "windows-1252", "cp1252":
            encoding = .windowsCP1252
        default:
            encoding = .utf8
        }

        if let encoding, let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func collapseSpaces(_ value: String) -> String {
        var current = value
        while current.contains("  ") {
            current = current.replacingOccurrences(of: "  ", with: " ")
        }
        return current
    }
}

private final class SpotlightMailQuery: NSObject {
    private static let queryStringKey = "NSMetadataQueryString"
    enum SearchMode {
        case sender
        case semantic
    }

    private static var active: [UUID: SpotlightMailQuery] = [:]

    private let id = UUID()
    private let context: MailMessageContext
    private let terms: [String]
    private let limit: Int
    private let mode: SearchMode
    private let continuation: CheckedContinuation<[MessageCandidate], Never>
    private var query: NSMetadataQuery?
    private var delayedFinish: DispatchWorkItem?
    private var timeoutFinish: DispatchWorkItem?
    private var didResume = false

    static func search(context: MailMessageContext, terms: [String], limit: Int, mode: SearchMode) async -> [MessageCandidate] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let runner = SpotlightMailQuery(
                    context: context,
                    terms: terms,
                    limit: limit,
                    mode: mode,
                    continuation: continuation
                )
                active[runner.id] = runner
                runner.start()
            }
        }
    }

    private init(
        context: MailMessageContext,
        terms: [String],
        limit: Int,
        mode: SearchMode,
        continuation: CheckedContinuation<[MessageCandidate], Never>
    ) {
        self.context = context
        self.terms = terms
        self.limit = limit
        self.mode = mode
        self.continuation = continuation
        super.init()
    }

    private func start() {
        guard !didResume else {
            return
        }

        let nextQuery = NSMetadataQuery()
        query = nextQuery
        nextQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        nextQuery.predicate = predicate()
        nextQuery.sortDescriptors = [
            NSSortDescriptor(key: "kMDItemContentCreationDate", ascending: false),
            NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)
        ]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: nextQuery
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: nextQuery
        )
        nextQuery.start()

        let timeoutFinish = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        self.timeoutFinish = timeoutFinish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: timeoutFinish)
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery,
              query === self.query,
              query.resultCount > 0 else {
            return
        }
        scheduleResultFinish()
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        finish()
    }

    private func scheduleResultFinish() {
        guard delayedFinish == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        delayedFinish = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func finish() {
        guard !didResume else {
            return
        }
        guard let query else {
            return
        }

        delayedFinish?.cancel()
        delayedFinish = nil
        timeoutFinish?.cancel()
        timeoutFinish = nil

        query.disableUpdates()
        let candidates = candidates(from: query)
        query.enableUpdates()
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        self.query = nil

        didResume = true
        NotificationCenter.default.removeObserver(self)
        continuation.resume(returning: candidates)
        Self.active[id] = nil
    }

    private func candidates(from query: NSMetadataQuery) -> [MessageCandidate] {
        var seenPaths = Set<String>()
        let inspectedLimit = min(max(limit * 2, 80), 160)
        return Array(query.results.prefix(inspectedLimit))
            .enumerated()
            .compactMap { index, item -> MessageCandidate? in
                guard let item = item as? NSMetadataItem else {
                    return nil
                }
                guard let candidate = candidate(from: item, rank: index + 1),
                      seenPaths.insert(candidate.path).inserted else {
                    return nil
                }
                return candidate
            }
            .sorted { lhs, rhs in
                let lhsScore = relevanceScore(for: lhs)
                let rhsScore = relevanceScore(for: rhs)
                if lhsScore == rhsScore {
                    return (lhs.header.date ?? .distantPast) > (rhs.header.date ?? .distantPast)
                }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map { $0 }
    }

    private func relevanceScore(for candidate: MessageCandidate) -> Int {
        let senderNeedle = normalizedEmail(context.senderEmail ?? context.sender)
        let candidateSender = normalizedEmail(candidate.header.sender ?? "")
        let text = [
            candidate.header.sender ?? "",
            candidate.header.subject ?? "",
            candidate.bodyPreview,
            candidate.mailboxInfo.mailboxPath.joined(separator: " ")
        ]
        .joined(separator: "\n")
        .lowercased()

        var score = 0
        if !senderNeedle.isEmpty, candidateSender == senderNeedle {
            score += 120
        } else if !senderNeedle.isEmpty, text.contains(senderNeedle) {
            score += 80
        }
        if let domain = senderNeedle.split(separator: "@").last, text.contains(domain.lowercased()) {
            score += 20
        }

        let uniqueTerms = Set(terms.map { $0.lowercased() }.filter { $0.count >= 4 && $0 != senderNeedle })
        for term in uniqueTerms {
            if candidate.header.subject?.lowercased().contains(term) == true {
                score += 18
            }
            if candidate.bodyPreview.lowercased().contains(term) {
                score += 8
            }
            if candidate.mailboxInfo.mailboxPath.joined(separator: " ").lowercased().contains(term) {
                score += 12
            }
        }

        return score + max(0, limit - min(candidate.rank, limit))
    }

    private func normalizedEmail(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func predicate() -> NSPredicate {
        let mailItem = mailItemPredicate()
        let needles = searchNeedles()

        guard !needles.isEmpty else {
            return mailItem
        }

        var matchPredicates: [NSPredicate] = []
        let needleLimit = mode == .semantic ? 10 : 6
        for needle in needles.prefix(needleLimit) {
            let pattern = "*\(needle)*"
            matchPredicates.append(NSPredicate(format: "%K ==[cd] %@", Self.queryStringKey, needle))
            matchPredicates.append(NSPredicate(format: "kMDItemTextContent LIKE[cd] %@", pattern))
            matchPredicates.append(NSPredicate(format: "kMDItemTitle LIKE[cd] %@", pattern))
            matchPredicates.append(NSPredicate(format: "kMDItemSubject LIKE[cd] %@", pattern))
            matchPredicates.append(NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", pattern))

            for key in Self.addressAttributeKeys {
                matchPredicates.append(NSPredicate(format: "ANY %K CONTAINS[cd] %@", key, needle))
            }
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            mailItem,
            NSCompoundPredicate(orPredicateWithSubpredicates: matchPredicates)
        ])
    }

    private func mailItemPredicate() -> NSPredicate {
        let contentTypes = [
            "public.email-message",
            "com.apple.mail.email",
            "com.apple.mail.emlx"
        ]
        var predicates = contentTypes.flatMap { contentType in
            [
                NSPredicate(format: "kMDItemContentType = %@", contentType),
                NSPredicate(format: "kMDItemContentTypeTree = %@", contentType),
                NSPredicate(format: "ANY kMDItemContentTypeTree = %@", contentType)
            ]
        }
        predicates.append(contentsOf: [
            NSPredicate(format: "kMDItemContentType = %@", "com.apple.mail.emlx"),
            NSPredicate(format: "kMDItemPath LIKE[c] %@", "*/Library/Mail/*"),
            NSPredicate(format: "kMDItemPath LIKE[c] %@", "*.emlx"),
            NSPredicate(format: "kMDItemPath LIKE[c] %@", "*.eml")
        ])
        return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }

    private static let addressAttributeKeys = [
        "kMDItemEmailAddresses",
        "kMDItemAuthorAddresses",
        "kMDItemRecipientAddresses",
        "kMDItemAuthors",
        "kMDItemRecipients",
        "kMDItemAuthorEmailAddresses",
        "kMDItemRecipientEmailAddresses"
    ]

    private func searchNeedles() -> [String] {
        var values: [String] = []
        let senderDomain = context.senderEmail?.split(separator: "@").last.map { String($0).lowercased() }
        if mode == .semantic {
            values.append(contentsOf: SubjectTokenizer.terms(from: context.subject, limit: 12))
            values.append(contentsOf: SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
            values.append(contentsOf: terms.filter { term in
                let term = term.lowercased()
                return !term.contains("@")
                    && !term.contains(".")
                    && term != senderDomain
            })
            if let senderEmail = context.senderEmail, !senderEmail.isEmpty {
                values.append(senderEmail)
                if let senderDomain {
                    values.append(senderDomain)
                }
            }
            values.append(context.sender)
            return Array(NSOrderedSet(array: values.map {
                $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { $0.count >= 4 })) as? [String] ?? []
        }

        if let senderEmail = context.senderEmail, !senderEmail.isEmpty {
            values.append(senderEmail)
            values.append(context.sender)
        } else if let email = EmailAddress.first(in: context.sender) {
            values.append(email)
        }

        return Array(NSOrderedSet(array: values.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count >= 4 })) as? [String] ?? []
    }

    private func candidate(from item: NSMetadataItem, rank: Int) -> MessageCandidate? {
        guard let path = item.value(forAttribute: "kMDItemPath") as? String else {
            return nil
        }
        guard isMailItem(path: path, item: item) else {
            return nil
        }
        let parsed = parseMessage(path: path)
        let subject = parsed.header.subject
            ?? item.value(forAttribute: "kMDItemSubject") as? String
            ?? item.value(forAttribute: "kMDItemTitle") as? String
            ?? item.value(forAttribute: "kMDItemDisplayName") as? String
        let sender = parsed.header.sender
            ?? firstString(from: item.value(forAttribute: "kMDItemAuthors"))
            ?? firstString(from: item.value(forAttribute: "kMDItemAuthorAddresses"))
            ?? firstString(from: item.value(forAttribute: "kMDItemAuthorEmailAddresses"))
        let date = parsed.header.date
            ?? item.value(forAttribute: "kMDItemContentCreationDate") as? Date
            ?? item.value(forAttribute: "kMDItemFSCreationDate") as? Date
        let mailboxInfo = Self.mailboxInfo(from: path)
        let decodedSubject = subject.map(MIMEHeaderDecoder.decode)
        let decodedSender = sender.map(MIMEHeaderDecoder.decode)

        return MessageCandidate(
            path: path,
            rank: rank,
            supportsMailFiling: path.contains("/Library/Mail/") && mailboxInfo.mailboxPath != ["Mail"],
            contributesSimilarMessage: true,
            mailboxInfo: mailboxInfo,
            header: MessageHeader(
                subject: decodedSubject,
                sender: decodedSender,
                date: date
            ),
            bodyPreview: parsed.bodyPreview.isEmpty ? decodedSubject ?? "" : parsed.bodyPreview
        )
    }

    private func parseMessage(path: String) -> (header: MessageHeader, bodyPreview: String) {
        guard path.hasSuffix(".emlx") || path.hasSuffix(".eml"),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return (MessageHeader(subject: nil, sender: nil, date: nil), "")
        }
        let data = handle.readData(ofLength: 32 * 1024)
        try? handle.close()
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (MessageHeader(subject: nil, sender: nil, date: nil), "")
        }

        let text = stripEmlxByteCount(raw)
        let parts = splitMessage(text)
        let headers = unfoldedHeaders(from: parts.header)
        return (
            MessageHeader(
                subject: headers["subject"].map(decodeHeaderValue),
                sender: headers["from"].map(decodeHeaderValue),
                date: headers["date"].flatMap(parseMailDate)
            ),
            String(parts.body.prefix(2000))
        )
    }

    private func stripEmlxByteCount(_ raw: String) -> String {
        guard let firstLine = raw.firstIndex(of: "\n"),
              raw[..<firstLine].allSatisfy({ $0.isNumber || $0 == "\r" }) else {
            return raw
        }
        return String(raw[raw.index(after: firstLine)...])
    }

    private func splitMessage(_ raw: String) -> (header: String, body: String) {
        if let range = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (raw, "")
    }

    private func unfoldedHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                break
            }
            if line.first == " " || line.first == "\t", let currentKey {
                headers[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            currentKey = key
        }

        return headers
    }

    private func decodeHeaderValue(_ value: String) -> String {
        MIMEHeaderDecoder.decode(value)
    }

    private func parseMailDate(_ value: String) -> Date? {
        DateFormatter.rfc2822.date(from: value)
            ?? DateFormatter.rfc2822WithSeconds.date(from: value)
            ?? DateFormatter.rfc2822NoWeekday.date(from: value)
    }

    private func isMailItem(path: String, item: NSMetadataItem) -> Bool {
        if path.contains("/Library/Mail/") || path.hasSuffix(".emlx") || path.hasSuffix(".eml") {
            return true
        }
        if let contentType = item.value(forAttribute: "kMDItemContentType") as? String,
           contentType.contains("com.apple.mail") || contentType == "public.email-message" {
            return true
        }
        if let contentTypes = item.value(forAttribute: "kMDItemContentTypeTree") as? [String],
           contentTypes.contains(where: { $0.contains("com.apple.mail") || $0 == "public.email-message" }) {
            return true
        }
        if let contentType = item.value(forAttribute: "kMDItemContentTypeTree") as? String,
           contentType.contains("com.apple.mail") || contentType == "public.email-message" {
            return true
        }
        return false
    }

    private func firstString(from value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let values = value as? [String] {
            return values.first
        }
        return nil
    }

    private static func mailboxInfo(from path: String) -> MailboxInfo {
        let components = URL(fileURLWithPath: path).pathComponents
        let mailboxPath = components
            .filter { $0.hasSuffix(".mbox") }
            .map { component -> String in
                let stripped = String(component.dropLast(".mbox".count))
                return stripped.removingPercentEncoding ?? stripped
            }
        let accountHint: String?
        if let versionIndex = components.firstIndex(where: { $0.range(of: #"^V\d+$"#, options: .regularExpression) != nil }) {
            let accountIndex = components.index(after: versionIndex)
            accountHint = components.indices.contains(accountIndex) ? components[accountIndex] : nil
        } else {
            accountHint = nil
        }
        return MailboxInfo(mailboxPath: mailboxPath.isEmpty ? ["Mail"] : mailboxPath, accountHint: accountHint)
    }
}

private actor MailHeaderCache {
    static let shared = MailHeaderCache()

    private let cacheVersion = 2
    private let headerReadLimit = 32 * 1024
    private let foregroundScanBudget: TimeInterval = 1.2
    private let foregroundMailboxBudget: TimeInterval = 0.45
    private let backgroundWarmInterval: TimeInterval = 15 * 60
    private let maximumStoredRecords = 120_000
    private let maximumStoredRecordsPerMailbox = 2_000
    private var loaded = false
    private var warming = false
    private var lastWarm: Date?
    private var recordsByPath: [String: MailHeaderRecord] = [:]
    private var pathsByEmail: [String: Set<String>] = [:]
    private var mailboxesByPath: [String: MailboxCatalogRecord] = [:]

    func candidates(for context: MailMessageContext, terms: [String], limit: Int) async -> (candidates: [MessageCandidate], diagnostic: String, requiresFullDiskAccess: Bool) {
        await loadIfNeeded()

        let sender = normalizedEmail(context.senderEmail ?? context.sender)
        guard !sender.isEmpty else {
            return ([], "Mail header cache has no sender to search.", false)
        }
        refreshMailboxCatalog(budget: foregroundMailboxBudget)

        let cached = rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
        if similarMessageCandidateCount(in: cached) >= min(4, limit) {
            startBackgroundWarmIfNeeded()
            return (cached, cacheDiagnostic(prefix: "Mail header cache returned", candidates: cached), false)
        }

        let foreground = await foregroundScan(context: context, sender: sender, terms: terms, limit: limit)
        if !foreground.isEmpty {
            await save()
            startBackgroundWarmIfNeeded()
            return (foreground, cacheDiagnostic(prefix: "Mail header cache warmed", candidates: foreground), false)
        }

        startBackgroundWarmIfNeeded()
        let root = mailRoot.path
        if !FileManager.default.isReadableFile(atPath: root) {
            return ([], "Mail header cache cannot read local Mail storage. Open Full Disk Access settings and add Shelf.", true)
        }
        return ([], "Mail header cache has no candidates yet; background warmup started.", false)
    }

    private func similarMessageCandidateCount(in candidates: [MessageCandidate]) -> Int {
        candidates.filter(\.contributesSimilarMessage).count
    }

    private func cacheDiagnostic(prefix: String, candidates: [MessageCandidate]) -> String {
        let messageCount = similarMessageCandidateCount(in: candidates)
        let filingCount = candidates.count - messageCount
        let messageLabel = "\(messageCount) message candidate\(messageCount == 1 ? "" : "s")"
        let filingLabel = "\(filingCount) filing candidate\(filingCount == 1 ? "" : "s")"
        return "\(prefix) \(messageLabel) and \(filingLabel)."
    }

    func cachedCandidates(for context: MailMessageContext, terms: [String], limit: Int) async -> [MessageCandidate] {
        await loadIfNeeded()

        let sender = normalizedEmail(context.senderEmail ?? context.sender)
        guard !sender.isEmpty else {
            return []
        }
        return rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
    }

    func globalCandidates(for context: MailMessageContext, terms: [String], limit: Int) async -> [MessageCandidate] {
        await loadIfNeeded()

        let normalizedTerms = globalSearchTerms(for: context, terms: terms)
        guard !normalizedTerms.isEmpty, limit > 0 else {
            return []
        }

        return recordsByPath.values
            .compactMap { record -> (MailHeaderRecord, Int)? in
                let score = globalScore(record, terms: normalizedTerms, context: context)
                guard score > 0 else {
                    return nil
                }
                return (record, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.date ?? lhs.0.modifiedAt) > (rhs.0.date ?? rhs.0.modifiedAt)
                }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .enumerated()
            .map { index, item in
                let record = item.0
                return MessageCandidate(
                    path: record.path,
                    rank: index + 1,
                    supportsMailFiling: true,
                    contributesSimilarMessage: true,
                    mailboxInfo: MailboxInfo(mailboxPath: record.mailboxPath, accountHint: record.accountHint),
                    header: MessageHeader(
                        subject: record.subject,
                        sender: record.sender,
                        date: record.date.map(Date.init(timeIntervalSince1970:))
                    ),
                    bodyPreview: record.subject ?? ""
                )
            }
    }

    private func loadIfNeeded() async {
        guard !loaded else {
            return
        }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(MailHeaderCachePayload.self, from: data),
              payload.version == cacheVersion else {
            return
        }

        for mailbox in payload.mailboxes {
            rememberMailbox(mailbox)
        }

        for record in payload.records.prefix(maximumStoredRecords) {
            insert(record)
        }
    }

    private func foregroundScan(context: MailMessageContext, sender: String, terms: [String], limit: Int) async -> [MessageCandidate] {
        let deadline = Date().addingTimeInterval(foregroundScanBudget)
        let roots = prioritizedMailboxRoots(for: context, sender: sender, terms: terms)
        for root in roots {
            scan(root: root, sender: sender, deadline: deadline, stopAfterMatches: limit)
            let candidates = rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
            if candidates.count >= min(4, limit) || Date() >= deadline {
                return candidates
            }
        }

        if Date() < deadline {
            scan(root: mailRoot, sender: sender, deadline: deadline, stopAfterMatches: limit)
        }
        return rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
    }

    private func startBackgroundWarmIfNeeded() {
        guard !warming else {
            return
        }
        if let lastWarm, Date().timeIntervalSince(lastWarm) < backgroundWarmInterval {
            return
        }
        warming = true
        Task.detached(priority: .background) { [weak self] in
            await self?.warmAll()
        }
    }

    private func warmAll() async {
        let deadline = Date().addingTimeInterval(120)
        scan(root: mailRoot, sender: nil, deadline: deadline, stopAfterMatches: nil)
        lastWarm = Date()
        warming = false
        await save()
    }

    private func prioritizedMailboxRoots(for context: MailMessageContext, sender: String, terms: [String]) -> [URL] {
        let needles = mailboxNeedles(context: context, sender: sender, terms: terms)
        guard !needles.isEmpty,
              let enumerator = FileManager.default.enumerator(
                at: mailRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let deadline = Date().addingTimeInterval(foregroundMailboxBudget)
        var roots: [URL] = []
        var seen = Set<String>()
        for case let url as URL in enumerator {
            if Date() >= deadline || roots.count >= 12 {
                break
            }
            guard url.pathExtension == "mbox" else {
                continue
            }
            rememberMailbox(url: url)
            let name = cleanMailboxName(url.lastPathComponent).lowercased()
            guard needles.contains(where: { name.contains($0) }) else {
                continue
            }
            if seen.insert(url.path).inserted {
                roots.append(url)
            }
        }
        return roots
    }

    private func scan(root: URL, sender: String?, deadline: Date, stopAfterMatches: Int?) {
        guard Date() < deadline,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        var matches = 0
        for case let url as URL in enumerator {
            if Date() >= deadline {
                break
            }
            if url.pathExtension == "mbox" {
                rememberMailbox(url: url)
                continue
            }
            guard url.pathExtension == "emlx" else {
                continue
            }
            guard let record = record(for: url) else {
                continue
            }
            insert(record)
            if let sender, record.emails.contains(sender) {
                matches += 1
                if let stopAfterMatches, matches >= stopAfterMatches {
                    break
                }
            }
            trimIfNeeded()
        }
    }

    private func record(for url: URL) -> MailHeaderRecord? {
        let path = url.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = Int64(values?.fileSize ?? 0)
        if let existing = recordsByPath[path],
           existing.modifiedAt == modifiedAt,
           existing.size == size {
            return existing
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        let data = handle.readData(ofLength: headerReadLimit)
        try? handle.close()
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let headerText = messageHeaderText(from: raw)
        let headers = unfoldedHeaders(from: headerText)
        let sender = headers["from"].map(decodeHeaderValue)
        let subject = headers["subject"].map(decodeHeaderValue)
        let date = headers["date"].flatMap(parseMailDate)
        let emailValues = [
            sender,
            headers["to"],
            headers["cc"],
            headers["bcc"]
        ]
        let emails = Array(Set(emailValues.compactMap { $0 }.flatMap(EmailAddress.all(in:)).map(normalizedEmail))).filter { !$0.isEmpty }
        guard !emails.isEmpty || subject?.isEmpty == false else {
            return nil
        }

        let mailboxInfo = mailboxInfo(from: path)
        return MailHeaderRecord(
            path: path,
            modifiedAt: modifiedAt,
            size: size,
            sender: sender,
            subject: subject,
            date: date?.timeIntervalSince1970,
            emails: emails,
            mailboxPath: mailboxInfo.mailboxPath,
            accountHint: mailboxInfo.accountHint
        )
    }

    private func insert(_ record: MailHeaderRecord) {
        var record = record
        record.sender = record.sender.map(MIMEHeaderDecoder.decode)
        record.subject = record.subject.map(MIMEHeaderDecoder.decode)
        if let previous = recordsByPath[record.path] {
            for email in previous.emails {
                pathsByEmail[email]?.remove(record.path)
            }
        }
        recordsByPath[record.path] = record
        rememberMailbox(
            MailboxCatalogRecord(
                displayPath: record.mailboxPath.joined(separator: "\u{1F}"),
                mailboxPath: record.mailboxPath,
                accountHint: record.accountHint,
                samplePath: mailboxSamplePath(from: record.path),
                lastSeen: record.modifiedAt,
                messageCount: 1
            )
        )
        for email in record.emails {
            pathsByEmail[email, default: []].insert(record.path)
        }
    }

    private func trimIfNeeded() {
        trimMailboxOverflows()
        guard recordsByPath.count > maximumStoredRecords else {
            return
        }
        let overflow = recordsByPath.count - maximumStoredRecords
        let oldPaths = recordsByPath.values
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .prefix(overflow)
            .map(\.path)
        for path in oldPaths {
            guard let record = recordsByPath.removeValue(forKey: path) else {
                continue
            }
            for email in record.emails {
                pathsByEmail[email]?.remove(path)
            }
        }
    }

    private func trimMailboxOverflows() {
        let grouped = Dictionary(grouping: recordsByPath.values) { $0.mailboxPath.joined(separator: "\u{1F}") }
        for records in grouped.values where records.count > maximumStoredRecordsPerMailbox {
            let overflow = records.count - maximumStoredRecordsPerMailbox
            let oldPaths = records
                .sorted { $0.modifiedAt < $1.modifiedAt }
                .prefix(overflow)
                .map(\.path)
            for path in oldPaths {
                guard let record = recordsByPath.removeValue(forKey: path) else {
                    continue
                }
                for email in record.emails {
                    pathsByEmail[email]?.remove(path)
                }
            }
        }
    }

    private func rankedCandidates(for context: MailMessageContext, sender: String, terms: [String], limit: Int) -> [MessageCandidate] {
        let paths = pathsByEmail[sender] ?? []
        let normalizedTerms = Set(terms.map { $0.lowercased() }.filter { $0.count >= 4 && $0 != sender })
        let folderLimit = min(20, max(4, limit / 4))
        let messageLimit = max(10, limit - folderLimit)
        let messageCandidates = paths
            .compactMap { recordsByPath[$0] }
            .sorted { lhs, rhs in
                let lhsScore = score(lhs, terms: normalizedTerms)
                let rhsScore = score(rhs, terms: normalizedTerms)
                if lhsScore == rhsScore {
                    return (lhs.date ?? lhs.modifiedAt) > (rhs.date ?? rhs.modifiedAt)
                }
                return lhsScore > rhsScore
            }
            .prefix(messageLimit)
            .enumerated()
            .map { index, record in
                MessageCandidate(
                    path: record.path,
                    rank: index + 1,
                    supportsMailFiling: true,
                    contributesSimilarMessage: true,
                    mailboxInfo: MailboxInfo(mailboxPath: record.mailboxPath, accountHint: record.accountHint),
                    header: MessageHeader(
                        subject: record.subject,
                        sender: record.sender,
                        date: record.date.map(Date.init(timeIntervalSince1970:))
                    ),
                    bodyPreview: record.subject ?? ""
                )
            }
        let usedMailboxPaths = Set(messageCandidates.map { $0.mailboxInfo.mailboxPath.joined(separator: "\u{1F}") })
        let folderCandidates = rankedMailboxCandidates(
            context: context,
            sender: sender,
            terms: normalizedTerms,
            excluding: usedMailboxPaths,
            startingRank: messageCandidates.count + 1,
            limit: folderLimit
        )
        return Array((messageCandidates + folderCandidates).prefix(limit))
    }

    private func globalSearchTerms(for context: MailMessageContext, terms: [String]) -> Set<String> {
        let sender = normalizedEmail(context.senderEmail ?? context.sender)
        let senderDomain = sender.split(separator: "@").last.map(String.init)
        var values = SubjectTokenizer.terms(from: context.subject, limit: 12)
        values.append(contentsOf: SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
        values.append(contentsOf: terms)
        return Set(values.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { term in
            term.count >= 4
                && !term.contains("@")
                && !term.contains(".")
                && term != sender
                && term != senderDomain
        })
    }

    private func globalScore(_ record: MailHeaderRecord, terms: Set<String>, context: MailMessageContext) -> Int {
        let subject = (record.subject ?? "").lowercased()
        let mailbox = record.mailboxPath.joined(separator: " ").lowercased()
        let sender = (record.sender ?? "").lowercased()
        let currentSubject = normalizedSubject(context.subject)
        let recordSubject = normalizedSubject(record.subject ?? "")

        var score = 0
        if !currentSubject.isEmpty, currentSubject == recordSubject {
            score += 90
        }

        for term in terms {
            if subject.contains(term) {
                score += 16
            }
            if mailbox.contains(term) {
                score += 8
            }
            if sender.contains(term) {
                score += 3
            }
        }

        let senderNeedle = normalizedEmail(context.senderEmail ?? context.sender)
        if !senderNeedle.isEmpty, record.emails.contains(senderNeedle) {
            score += 6
        }

        return score
    }

    private func normalizedSubject(_ value: String) -> String {
        var subject = value.lowercased()
        while true {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("re:") {
                subject = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("fw:") {
                subject = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("fwd:") {
                subject = String(trimmed.dropFirst(4))
            } else {
                subject = trimmed
                break
            }
        }
        return subject
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .joined(separator: " ")
    }

    private func score(_ record: MailHeaderRecord, terms: Set<String>) -> Int {
        let subject = (record.subject ?? "").lowercased()
        let mailbox = record.mailboxPath.joined(separator: " ").lowercased()
        var score = 10
        for term in terms {
            if subject.contains(term) {
                score += 4
            }
            if mailbox.contains(term) {
                score += 6
            }
        }
        return score
    }

    private func save() async {
        let records = recordsByPath.values
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumStoredRecords)
        let payload = MailHeaderCachePayload(
            version: cacheVersion,
            records: Array(records),
            mailboxes: Array(mailboxesByPath.values)
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private var mailRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("MailHeaderCache.json")
    }

    private func mailboxNeedles(context: MailMessageContext, sender: String, terms: [String]) -> [String] {
        var values = terms
        values.append(sender)
        if let local = sender.split(separator: "@").first {
            values.append(String(local))
        }
        values.append(context.currentMailbox)
        return Array(NSOrderedSet(array: values.map {
            $0.lowercased()
                .replacingOccurrences(of: ".com", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count >= 4 })) as? [String] ?? []
    }

    private func refreshMailboxCatalog(budget: TimeInterval) {
        guard let enumerator = FileManager.default.enumerator(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let deadline = Date().addingTimeInterval(budget)
        for case let url as URL in enumerator {
            if Date() >= deadline {
                break
            }
            if url.pathExtension == "mbox" {
                rememberMailbox(url: url)
            }
        }
    }

    private func rankedMailboxCandidates(
        context: MailMessageContext,
        sender: String,
        terms: Set<String>,
        excluding usedMailboxPaths: Set<String>,
        startingRank: Int,
        limit: Int
    ) -> [MessageCandidate] {
        guard limit > 0 else {
            return []
        }

        let folderTerms = Set(mailboxNeedles(context: context, sender: sender, terms: Array(terms)))
        let scored = mailboxesByPath.values
            .filter { mailbox in
                !usedMailboxPaths.contains(mailbox.displayPath)
                    && !mailbox.mailboxPath.isEmpty
                    && !isLikelySystemMailbox(mailbox.mailboxPath)
            }
            .map { mailbox -> (MailboxCatalogRecord, Int) in
                (mailbox, score(mailbox: mailbox, terms: folderTerms))
            }
            .filter { _, score in score > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    if lhs.0.messageCount == rhs.0.messageCount {
                        return lhs.0.lastSeen > rhs.0.lastSeen
                    }
                    return lhs.0.messageCount > rhs.0.messageCount
                }
                return lhs.1 > rhs.1
            }
        return scored
            .prefix(limit)
            .enumerated()
            .map { offset, item in
                let mailbox = item.0
                return MessageCandidate(
                    path: mailbox.samplePath,
                    rank: startingRank + offset,
                    supportsMailFiling: true,
                    contributesSimilarMessage: false,
                    mailboxInfo: MailboxInfo(mailboxPath: mailbox.mailboxPath, accountHint: mailbox.accountHint),
                    header: MessageHeader(subject: mailbox.mailboxPath.joined(separator: " / "), sender: nil, date: nil),
                    bodyPreview: ""
                )
            }
    }

    private func score(mailbox: MailboxCatalogRecord, terms: Set<String>) -> Int {
        let name = mailbox.mailboxPath.joined(separator: " ").lowercased()
        var score = 0
        for term in terms where term.count >= 3 {
            if name == term {
                score += 40
            } else if name.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(term) {
                score += 24
            } else if name.contains(term) {
                score += 12
            }
        }
        if mailbox.mailboxPath.count > 1 {
            score += 4
        }
        return score
    }

    private func rememberMailbox(url: URL) {
        let info = mailboxInfo(from: url.path)
        guard !info.mailboxPath.isEmpty, info.mailboxPath != ["Mail"] else {
            return
        }
        rememberMailbox(
            MailboxCatalogRecord(
                displayPath: info.mailboxPath.joined(separator: "\u{1F}"),
                mailboxPath: info.mailboxPath,
                accountHint: info.accountHint,
                samplePath: url.path,
                lastSeen: Date().timeIntervalSince1970,
                messageCount: 0
            )
        )
    }

    private func rememberMailbox(_ mailbox: MailboxCatalogRecord) {
        guard !mailbox.mailboxPath.isEmpty else {
            return
        }
        let key = mailbox.displayPath
        if var existing = mailboxesByPath[key] {
            existing.lastSeen = max(existing.lastSeen, mailbox.lastSeen)
            existing.messageCount += mailbox.messageCount
            if existing.samplePath.isEmpty {
                existing.samplePath = mailbox.samplePath
            }
            if existing.accountHint == nil {
                existing.accountHint = mailbox.accountHint
            }
            mailboxesByPath[key] = existing
        } else {
            mailboxesByPath[key] = mailbox
        }
    }

    private func mailboxSamplePath(from messagePath: String) -> String {
        let components = URL(fileURLWithPath: messagePath).pathComponents
        guard let lastMailboxIndex = components.lastIndex(where: { $0.hasSuffix(".mbox") }) else {
            return messagePath
        }
        let path = NSString.path(withComponents: Array(components[0...lastMailboxIndex]))
        return path
    }

    private func isLikelySystemMailbox(_ mailboxPath: [String]) -> Bool {
        let names = Set(mailboxPath.map { $0.lowercased() })
        return !names.isDisjoint(with: [
            "deleted items", "deleted messages", "trash", "bin", "junk", "junk email", "spam",
            "drafts", "sent", "sent mail", "sent items", "outbox"
        ])
    }

    private func messageHeaderText(from raw: String) -> String {
        let withoutByteCount: Substring
        if let firstLine = raw.firstIndex(of: "\n"),
           raw[..<firstLine].allSatisfy({ $0.isNumber || $0 == "\r" }) {
            withoutByteCount = raw[raw.index(after: firstLine)...]
        } else {
            withoutByteCount = raw[...]
        }
        if let range = withoutByteCount.range(of: "\r\n\r\n") ?? withoutByteCount.range(of: "\n\n") {
            return String(withoutByteCount[..<range.lowerBound])
        }
        return String(withoutByteCount)
    }

    private func unfoldedHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                break
            }
            if line.first == " " || line.first == "\t", let currentKey {
                headers[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            currentKey = key
        }

        return headers
    }

    private func decodeHeaderValue(_ value: String) -> String {
        MIMEHeaderDecoder.decode(value)
    }

    private func normalizedEmail(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func parseMailDate(_ value: String) -> Date? {
        DateFormatter.rfc2822.date(from: value)
            ?? DateFormatter.rfc2822WithSeconds.date(from: value)
            ?? DateFormatter.rfc2822NoWeekday.date(from: value)
    }

    private func mailboxInfo(from path: String) -> MailboxInfo {
        let components = URL(fileURLWithPath: path).pathComponents
        let mailboxPath = components
            .filter { $0.hasSuffix(".mbox") }
            .map(cleanMailboxName)
        let accountHint: String?
        if let versionIndex = components.firstIndex(where: { $0.range(of: #"^V\d+$"#, options: .regularExpression) != nil }) {
            let accountIndex = components.index(after: versionIndex)
            accountHint = components.indices.contains(accountIndex) ? components[accountIndex] : nil
        } else {
            accountHint = nil
        }
        return MailboxInfo(mailboxPath: mailboxPath.isEmpty ? ["Mail"] : mailboxPath, accountHint: accountHint)
    }

    private func cleanMailboxName(_ component: String) -> String {
        let stripped = String(component.dropLast(".mbox".count))
        return stripped.removingPercentEncoding ?? stripped
    }
}

private struct MailHeaderCachePayload: Codable {
    var version: Int
    var records: [MailHeaderRecord]
    var mailboxes: [MailboxCatalogRecord]
}

private struct MailHeaderRecord: Codable {
    var path: String
    var modifiedAt: TimeInterval
    var size: Int64
    var sender: String?
    var subject: String?
    var date: TimeInterval?
    var emails: [String]
    var mailboxPath: [String]
    var accountHint: String?
}

private struct MailboxCatalogRecord: Codable {
    var displayPath: String
    var mailboxPath: [String]
    var accountHint: String?
    var samplePath: String
    var lastSeen: TimeInterval
    var messageCount: Int
}

private extension DateFormatter {
    static let rfc2822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static let appleScriptMailDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    static let rfc2822WithSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static let rfc2822NoWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

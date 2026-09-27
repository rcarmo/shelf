import Foundation
import LatentSemanticMapping

private func normalizedDisplayName(from value: String) -> String {
    var cleaned = MIMEHeaderDecoder.decode(value)
    cleaned = cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(
        of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        with: " ",
        options: [.regularExpression, .caseInsensitive]
    )
    cleaned = cleaned
        .replacingOccurrences(of: "\"", with: " ")
        .replacingOccurrences(of: "'", with: " ")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)

    while cleaned.contains("  ") {
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
    }
    return cleaned
}

final class SpotlightMessageRanker {
    private let maximumResults = 80
    private let maximumTrainingMessagesPerMailbox = 8
    private let excludedMailboxNames: Set<String> = [
        "deleted items", "deleted messages", "trash", "bin", "junk", "junk email", "spam"
    ]

    func suggestions(for context: MailMessageContext) async -> MailSuggestions {
        var finalSuggestions = MailSuggestions.empty
        for await update in suggestionUpdates(for: context) {
            finalSuggestions = update.suggestions
        }
        return finalSuggestions
    }

    func suggestionUpdates(for context: MailMessageContext) -> AsyncStream<MailSuggestionUpdate> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let senderNeedle = normalizedSender(context.senderEmail ?? context.sender)
                guard !senderNeedle.isEmpty else {
                    continuation.yield(MailSuggestionUpdate(suggestions: .empty, isFinal: true))
                    continuation.finish()
                    return
                }

                let terms = context.searchTerms.filter { !$0.isEmpty }
                let accounts = await MailAccountResolver.shared.directory()
                var merged: [MessageCandidate] = []
                var indexByPath: [String: Int] = [:]
                var diagnosticsBySource: [SpotlightCandidateChunk.Source: String] = [:]
                var requiresFullDiskAccess = false

                for await chunk in candidateChunks(for: context, terms: terms) {
                    guard !Task.isCancelled else {
                        break
                    }

                    if let diagnostic = chunk.diagnostic, !diagnostic.isEmpty {
                        diagnosticsBySource[chunk.source] = diagnostic
                    }
                    requiresFullDiskAccess = requiresFullDiskAccess || chunk.requiresFullDiskAccess

                    for candidate in chunk.candidates {
                        if let existingIndex = indexByPath[candidate.path] {
                            merged[existingIndex] = mergedCandidate(merged[existingIndex], candidate)
                            continue
                        }
                        guard merged.count < maximumResults * 9 else { continue }
                        var ranked = candidate
                        ranked.rank = merged.count + 1
                        indexByPath[ranked.path] = merged.count
                        merged.append(ranked)
                    }

                    var suggestions = await mailSuggestions(
                        from: merged,
                        context: context,
                        diagnostic: streamingDiagnostic(from: diagnosticsBySource),
                        requiresFullDiskAccess: requiresFullDiskAccess,
                        accounts: accounts
                    )
                    suggestions = await resolvedSuggestions(suggestions, accounts: accounts, context: context)
                    continuation.yield(MailSuggestionUpdate(suggestions: suggestions, isFinal: false))
                }

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                var finalSuggestions = await mailSuggestions(
                    from: merged,
                    context: context,
                    diagnostic: streamingDiagnostic(from: diagnosticsBySource),
                    requiresFullDiskAccess: requiresFullDiskAccess,
                    accounts: accounts
                )
                finalSuggestions = await resolvedSuggestions(finalSuggestions, accounts: accounts, context: context)
                if !finalSuggestions.messages.isEmpty || !finalSuggestions.locations.isEmpty || !finalSuggestions.diagnostic.isEmpty {
                    continuation.yield(MailSuggestionUpdate(suggestions: finalSuggestions, isFinal: true))
                } else {
                    continuation.yield(MailSuggestionUpdate(suggestions: .empty, isFinal: true))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func mailSuggestions(
        from candidates: [MessageCandidate],
        context: MailMessageContext,
        diagnostic: String,
        requiresFullDiskAccess: Bool,
        accounts: MailAccountDirectory = MailAccountDirectory()
    ) async -> MailSuggestions {
        await Task.detached(priority: .userInitiated) { [self] in
            let directory = accounts.including(context)
            let canonical = candidates.map { candidate in
                var candidate = candidate
                candidate.mailboxInfo.accountHint = directory.canonicalHint(candidate.mailboxInfo.accountHint)
                return candidate
            }
            let ranked = rankedCandidates(canonical)
            guard !ranked.isEmpty else {
                return MailSuggestions(
                    locations: [],
                    messages: [],
                    diagnostic: diagnostic,
                    requiresFullDiskAccess: requiresFullDiskAccess
                )
            }

            let messages = similarMessages(from: ranked, context: context)
            let rankedLocations = groupedLocations(from: ranked, currentMailbox: context.currentMailbox, context: context,
                                                   visibleMessages: messages)
            let orders = folderOrders(rankedLocations: rankedLocations, messages: messages, candidates: ranked)
            let fullBaseline = orders.shortlist.map { location in
                var location = location
                location.accountDisplayName = directory.displayName(for: location.accountHint)
                return location
            }
            let locations = Array(fullBaseline.prefix(orders.displayed.count))
            let lsmDiagnostic = "LSM ranked \(locations.count) filing destination\(locations.count == 1 ? "" : "s")."
            return MailSuggestions(
                locations: locations,
                messages: messages,
                diagnostic: [diagnostic, lsmDiagnostic].filter { !$0.isEmpty }.joined(separator: " "),
                requiresFullDiskAccess: requiresFullDiskAccess,
                decisionEvidence: decisionEvidence(locations: fullBaseline, candidates: ranked, messages: messages, context: context)
            )
        }.value
    }

    private func resolvedSuggestions(_ suggestions: MailSuggestions, accounts: MailAccountDirectory,
                                     context: MailMessageContext) async -> MailSuggestions {
        let identities = await MailActionService.shared.resolve(suggestions.decisionEvidence.map(\.location))
        return MailDestinationSelection.resolved(suggestions, identities: identities, accounts: accounts.including(context), context: context)
    }

    private func candidateChunks(for context: MailMessageContext, terms: [String]) -> AsyncStream<SpotlightCandidateChunk> {
        AsyncStream { continuation in
            let cachedTask = Task {
                let candidates = await MailHeaderCache.shared.cachedCandidates(for: context, terms: terms, limit: maximumResults)
                continuation.yield(SpotlightCandidateChunk(source: .cachedHeader, candidates: candidates))
            }
            let semanticTask = Task {
                for await candidates in SpotlightMailQuery.stream(context: context, terms: terms, limit: maximumResults, mode: .semantic) {
                    let diagnostic = candidates.isEmpty
                        ? nil
                        : "Spotlight semantic returned \(candidates.count) email candidate\(candidates.count == 1 ? "" : "s")."
                    continuation.yield(SpotlightCandidateChunk(source: .semanticSpotlight, candidates: candidates, diagnostic: diagnostic))
                }
            }
            let threadSubjectTask = Task {
                for await candidates in SpotlightMailQuery.stream(context: context, terms: terms, limit: maximumResults, mode: .threadSubject) {
                    let diagnostic = candidates.isEmpty
                        ? nil
                        : "Spotlight thread subject returned \(candidates.count) email candidate\(candidates.count == 1 ? "" : "s")."
                    continuation.yield(SpotlightCandidateChunk(source: .threadSubjectSpotlight, candidates: candidates, diagnostic: diagnostic))
                }
            }
            let senderTask = Task {
                for await candidates in SpotlightMailQuery.stream(context: context, terms: terms, limit: maximumResults, mode: .sender) {
                    let diagnostic = candidates.isEmpty
                        ? nil
                        : "Spotlight sender returned \(candidates.count) email candidate\(candidates.count == 1 ? "" : "s")."
                    continuation.yield(SpotlightCandidateChunk(source: .senderSpotlight, candidates: candidates, diagnostic: diagnostic))
                }
            }
            let globalHeaderTask = Task {
                let candidates = await MailHeaderCache.shared.globalCandidates(for: context, terms: terms, limit: maximumResults)
                let diagnostic = candidates.isEmpty
                    ? nil
                    : "Global header search returned \(candidates.count) topic candidate\(candidates.count == 1 ? "" : "s")."
                continuation.yield(SpotlightCandidateChunk(source: .globalHeader, candidates: candidates, diagnostic: diagnostic))
            }
            let threadHeaderTask = Task {
                let result = await MailHeaderCache.shared.threadCandidates(for: context, limit: maximumResults)
                continuation.yield(SpotlightCandidateChunk(
                    source: .threadHeader,
                    candidates: result.candidates,
                    diagnostic: result.diagnostic,
                    requiresFullDiskAccess: result.requiresFullDiskAccess
                ))
            }
            let senderHeaderTask = Task {
                let result = await MailHeaderCache.shared.candidates(for: context, terms: terms, limit: maximumResults)
                continuation.yield(SpotlightCandidateChunk(
                    source: .senderHeader,
                    candidates: result.candidates,
                    diagnostic: result.diagnostic,
                    requiresFullDiskAccess: result.requiresFullDiskAccess
                ))
            }
            let learnedTask = Task {
                let candidates = await learnedMoveCandidates(for: context, limit: 8)
                let diagnostic = "Filing memory ranked \(candidates.count) destination\(candidates.count == 1 ? "" : "s")."
                continuation.yield(SpotlightCandidateChunk(source: .learnedMoves, candidates: candidates, diagnostic: diagnostic))
            }
            let logicalMailTask = Task {
                let result = await MailLogicalMessageSearch.shared.messages(for: context, limit: maximumResults)
                let candidates = result.records.enumerated().map { index, record in
                    MessageCandidate(
                        path: "shelf-mail-message://\(record.libraryID)",
                        rank: index + 1,
                        supportsMailFiling: true,
                        contributesSimilarMessage: true,
                        mailboxInfo: MailboxInfo(mailboxPath: record.mailboxPath, accountHint: record.accountName ?? "local"),
                        header: MessageHeader(subject: record.subject, sender: record.sender, date: record.date),
                        bodyPreview: record.subject
                    )
                }
                let diagnostic = "Mail logical search returned \(candidates.count) candidate\(candidates.count == 1 ? "" : "s"). \(result.diagnostic)"
                continuation.yield(SpotlightCandidateChunk(source: .logicalMail, candidates: candidates, diagnostic: diagnostic))
            }
            let finishTask = Task {
                _ = await cachedTask.result
                _ = await semanticTask.result
                _ = await threadSubjectTask.result
                _ = await senderTask.result
                _ = await globalHeaderTask.result
                _ = await threadHeaderTask.result
                _ = await senderHeaderTask.result
                _ = await learnedTask.result
                _ = await logicalMailTask.result
                continuation.finish()
            }

            continuation.onTermination = { _ in
                cachedTask.cancel()
                semanticTask.cancel()
                threadSubjectTask.cancel()
                senderTask.cancel()
                globalHeaderTask.cancel()
                threadHeaderTask.cancel()
                senderHeaderTask.cancel()
                learnedTask.cancel()
                logicalMailTask.cancel()
                finishTask.cancel()
            }
        }
    }

    private func streamingDiagnostic(from diagnosticsBySource: [SpotlightCandidateChunk.Source: String]) -> String {
        [
            diagnosticsBySource[.semanticSpotlight],
            diagnosticsBySource[.threadSubjectSpotlight],
            diagnosticsBySource[.globalHeader],
            diagnosticsBySource[.threadHeader],
            diagnosticsBySource[.senderSpotlight],
            diagnosticsBySource[.senderHeader],
            diagnosticsBySource[.learnedMoves],
            diagnosticsBySource[.logicalMail]
        ]
        .compactMap { $0 }
        .joined(separator: " ")
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
        merged.filingMemoryScore = max(existing.filingMemoryScore, incoming.filingMemoryScore)
        merged.filingMemoryCount = max(existing.filingMemoryCount, incoming.filingMemoryCount)
        merged.senderMemoryCount = max(existing.senderMemoryCount, incoming.senderMemoryCount)
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
                bodyPreview: recommendation.sampleText,
                filingMemoryScore: recommendation.memoryScore,
                filingMemoryCount: recommendation.exampleCount,
                senderMemoryCount: recommendation.senderMatchCount,
                learnedEvidenceSender: recommendation.sampleSender,
                learnedEvidenceSubject: recommendation.sampleSubject,
                learnedEvidenceBody: recommendation.sampleBody
            )
        }
    }

    private func rankedCandidates(_ candidates: [MessageCandidate]) -> [MessageCandidate] {
        var seenLearnedDestinations = Set<String>()
        var ranked: [MessageCandidate] = []

        for candidate in candidates {
            if !candidate.contributesSimilarMessage {
                let key = ([candidate.mailboxInfo.accountHint ?? ""] + candidate.mailboxInfo.mailboxPath).joined(separator: "\u{1F}")
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

    func groupedLocations(from candidates: [MessageCandidate], currentMailbox: String, context: MailMessageContext,
                          visibleMessages: [SimilarMessage]? = nil) -> [RankedMessageLocation] {
        let visiblePaths = Set((visibleMessages ?? similarMessages(from: candidates, context: context)).map(\.path))
        let usableCandidates = candidates.filter {
            $0.supportsMailFiling && isFilingDestination($0.mailboxInfo.mailboxPath, currentMailbox: currentMailbox)
                && (!$0.contributesSimilarMessage || visiblePaths.contains($0.path) || hasFilingEvidence($0, context: context))
        }
        let semanticScores = semanticScores(for: usableCandidates, context: context)
        let similarBackedLocations = groupedLocations(
            from: usableCandidates.filter(\.contributesSimilarMessage),
            semanticScores: semanticScores,
            allowCatalogBoost: false,
            context: context
        )

        let learnedFallbackLocations = groupedLocations(
            from: usableCandidates.filter { $0.isLearnedMoveCandidate
                && (similarBackedLocations.isEmpty || $0.filingMemoryScore >= 0.35) },
            semanticScores: semanticScores,
            allowCatalogBoost: false,
            context: context
        )
        let catalogFallbackLocations = groupedLocations(
            from: usableCandidates.filter { !$0.contributesSimilarMessage && !$0.isLearnedMoveCandidate
                && Self.mailboxNameMatchesTopic($0.mailboxInfo.mailboxPath, subject: context.subject) },
            semanticScores: semanticScores,
            allowCatalogBoost: false,
            context: context
        )
        let backed = rankedLocations(similarBackedLocations + learnedFallbackLocations, preferHitCount: true)
        let backedPaths = Set(backed.map(\.id))
        // Folder-name evidence can fill spare slots, but never displace filed-message evidence.
        return backed + rankedLocations(catalogFallbackLocations, preferHitCount: false)
            .filter { !backedPaths.contains($0.id) }
    }

    static func mailboxNameMatchesTopic(_ path: [String], subject: String) -> Bool {
        guard let leaf = path.last else { return false }
        let generic: Set<String> = ["mail", "archive", "archives", "personal", "projects", "work", "messages", "inbox", "drafts", "sent"]
        let folderTerms = MailSubjectMatch.terms(leaf).filter { $0.count >= 4 && !generic.contains($0) }
        let subjectTerms = Set(MailSubjectMatch.terms(subject))
        return folderTerms.contains { term in
            subjectTerms.contains(term) || subjectTerms.contains(term + "s")
                || (term.hasSuffix("s") && subjectTerms.contains(String(term.dropLast())))
        }
    }

    private func groupedLocations(
        from candidates: [MessageCandidate],
        semanticScores: [String: Double],
        allowCatalogBoost: Bool,
        context: MailMessageContext
    ) -> [RankedMessageLocation] {
        var grouped: [String: RankedMessageLocation] = [:]
        var seen = Set<String>()
        let recentCutoff = Date().addingTimeInterval(-(90 * 24 * 60 * 60))

        for candidate in candidates {
            let displayPath = candidate.mailboxInfo.mailboxPath.joined(separator: " / ")
            let account = canonicalAccountHint(candidate.mailboxInfo.accountHint, context: context)
            let key = ([account ?? ""] + candidate.mailboxInfo.mailboxPath).joined(separator: "\u{1F}")
            // A Spotlight hit and the native header for it are one filing example.
            if candidate.contributesSimilarMessage,
               !seen.insert(key + "\u{1E}" + dedupeKey(for: candidate)).inserted { continue }
            let sameSender = candidate.contributesSimilarMessage
                && !normalizedSender(context.senderEmail ?? context.sender).isEmpty
                && normalizedSender(context.senderEmail ?? context.sender) == normalizedSender(candidate.header.sender ?? "")
            let sameThread = candidate.contributesSimilarMessage && MailSubjectMatch(context.subject, candidate.header.subject ?? "").exact
            let semanticScore = semanticScores[displayPath] ?? 0
            let catalogBoost = !candidate.contributesSimilarMessage && allowCatalogBoost ? Double(maximumResults / 3) : 0
            let similarHitBoost = candidate.contributesSimilarMessage ? Double(maximumResults / 3) : 0
            let senderAndThreadBoost = filingSimilarityScore(candidate, context: context) * Double(maximumResults)
            let memoryBoost = candidate.filingMemoryScore * Double(maximumResults * 2)
                + min(Double(candidate.filingMemoryCount), 6) * 8
                + min(Double(candidate.senderMemoryCount), 6) * 12
            let relevance = Double(max(1, maximumResults - candidate.rank + 1))
                + (semanticScore * Double(maximumResults))
                + senderAndThreadBoost
                + memoryBoost
                + catalogBoost
                + similarHitBoost
            if var existing = grouped[key] {
                existing.hitCount += candidate.contributesSimilarMessage || candidate.isLearnedMoveCandidate ? 1 : 0
                existing.senderHitCount += sameSender ? 1 : 0
                existing.threadHitCount += sameThread ? 1 : 0
                if candidate.contributesSimilarMessage,
                   let date = candidate.header.date,
                   date >= recentCutoff {
                    existing.recentHitCount += 1
                }
                existing.score = candidate.contributesSimilarMessage
                    ? existing.score + relevance
                    : max(existing.score, relevance)
                existing.semanticScore = max(existing.semanticScore, semanticScore)
                grouped[key] = existing
            } else {
                grouped[key] = RankedMessageLocation(
                    mailboxPath: candidate.mailboxInfo.mailboxPath,
                    accountHint: account,
                    score: relevance,
                    semanticScore: semanticScore,
                    hitCount: candidate.contributesSimilarMessage || candidate.isLearnedMoveCandidate ? 1 : 0,
                    recentHitCount: candidate.contributesSimilarMessage
                        && candidate.header.date.map { $0 >= recentCutoff } == true ? 1 : 0,
                    samplePath: candidate.path,
                    senderHitCount: sameSender ? 1 : 0,
                    threadHitCount: sameThread ? 1 : 0
                )
            }
        }

        return Array(grouped.values)
    }

    func filingSimilarityScore(_ candidate: MessageCandidate, context: MailMessageContext) -> Double {
        let contextSender = normalizedSender(context.senderEmail ?? context.sender)
        let candidateSender = normalizedSender(candidate.header.sender ?? "")
        let contextSenderName = normalizedSenderDisplayName(context.sender)
        let candidateSenderName = normalizedSenderDisplayName(candidate.header.sender ?? "")
        let sameSender = (!contextSender.isEmpty && contextSender == candidateSender)
            || (!contextSenderName.isEmpty && contextSenderName == candidateSenderName)
        let subject = MailSubjectMatch(context.subject, candidate.header.subject ?? "")
        var score = subject.filingBoost + (sameSender ? 0.60 : 0)
        if candidate.isLogicalMailCandidate {
            score += 0.50
        }

        return score
    }

    func rankedLocations(_ locations: [RankedMessageLocation], preferHitCount: Bool) -> [RankedMessageLocation] {
        var merged: [String: RankedMessageLocation] = [:]
        for location in locations {
            if var existing = merged[location.id] {
                existing.hitCount = max(existing.hitCount, location.hitCount)
                existing.recentHitCount = max(existing.recentHitCount, location.recentHitCount)
                existing.score += location.score
                existing.semanticScore = max(existing.semanticScore, location.semanticScore)
                existing.senderHitCount = max(existing.senderHitCount, location.senderHitCount)
                existing.threadHitCount = max(existing.threadHitCount, location.threadHitCount)
                merged[location.id] = existing
            } else {
                merged[location.id] = location
            }
        }

        return merged.values
            .sorted { lhs, rhs in
                if (lhs.threadHitCount > 0) != (rhs.threadHitCount > 0) { return lhs.threadHitCount > 0 }
                let lhsHasStrongHitEvidence = lhs.recentHitCount >= 3 || lhs.hitCount >= 5
                let rhsHasStrongHitEvidence = rhs.recentHitCount >= 3 || rhs.hitCount >= 5
                if lhsHasStrongHitEvidence != rhsHasStrongHitEvidence {
                    return lhsHasStrongHitEvidence
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if preferHitCount, lhs.hitCount != rhs.hitCount {
                    return lhs.hitCount > rhs.hitCount
                }
                if lhs.semanticScore != rhs.semanticScore {
                    return lhs.semanticScore > rhs.semanticScore
                }
                if lhs.hitCount != rhs.hitCount {
                    return lhs.hitCount > rhs.hitCount
                }
                return lhs.displayPath < rhs.displayPath
            }
            .map { $0 }
    }

    private func appleScriptAccountHint(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func canonicalAccountHint(_ value: String?, context: MailMessageContext) -> String? {
        return appleScriptAccountHint(value)
    }

    func folderOrders(rankedLocations: [RankedMessageLocation], messages: [SimilarMessage], candidates: [MessageCandidate])
        -> (displayed: [RankedMessageLocation], shortlist: [RankedMessageLocation]) {
        // Message relevance already orders the evidence. Promote its destinations before cutting the list.
        let full = locationsIncludingVisibleMessageFolders(rankedLocations, messages: messages, candidates: candidates)
        return (Array(full.prefix(5)), full)
    }

    func locationsIncludingVisibleMessageFolders(
        _ locations: [RankedMessageLocation],
        messages: [SimilarMessage],
        candidates: [MessageCandidate]
    ) -> [RankedMessageLocation] {
        var locationByKey = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
        var prioritized: [RankedMessageLocation] = []
        for message in messages {
            let matches = locations.filter { $0.mailboxPath == message.mailboxPath
                && (message.accountHint == nil || $0.accountHint == message.accountHint) }
            guard matches.count == 1, let key = matches.first?.id else { continue }
            // Destinations must come from actual Mail candidates, never catalog-only rows.
            if let location = locationByKey[key], location.hitCount > 0 {
                locationByKey.removeValue(forKey: key)
                prioritized.append(location)
            }
        }

        let remaining = locations.filter {
            locationByKey[$0.id] != nil
        }
        return prioritized + remaining
    }

    private func isFilingDestination(_ path: [String], currentMailbox: String) -> Bool {
        MailFilingRetrieval.isDestination(path, currentMailbox: currentMailbox)
    }

    private func hasFilingEvidence(_ candidate: MessageCandidate, context: MailMessageContext) -> Bool {
        let subject = MailSubjectMatch(context.subject, candidate.header.subject ?? "")
        let sender = normalizedSender(context.senderEmail ?? context.sender)
        let sameSender = !sender.isEmpty && sender == normalizedSender(candidate.header.sender ?? "")
        // A generic body/footer or a single cross-sender word is not a filing example.
        return subject.exact || subject.strong || sameSender
    }

    private func decisionEvidence(locations: [RankedMessageLocation], candidates: [MessageCandidate],
                                  messages: [SimilarMessage], context: MailMessageContext) -> [MailFolderEvidence] {
        locations.map { location in
            let matches = candidates.filter { $0.mailboxInfo.mailboxPath == location.mailboxPath
                && canonicalAccountHint($0.mailboxInfo.accountHint, context: context) == location.accountHint }
            let accounts = Set(matches.compactMap { appleScriptAccountHint($0.mailboxInfo.accountHint) })
            var seen = Set<String>()
            let records = matches.filter { $0.contributesSimilarMessage || $0.isLearnedMoveCandidate }.sorted {
                if $0.bodyPreview.utf8.count != $1.bodyPreview.utf8.count { return $0.bodyPreview.utf8.count > $1.bodyPreview.utf8.count }
                return $0.path < $1.path
            }.compactMap { candidate -> MailEvidenceRecord? in
                let key = candidate.isLearnedMoveCandidate ? candidate.path : dedupeKey(for: candidate)
                guard seen.insert(key).inserted else { return nil }
                let sender = normalizedSender(context.senderEmail ?? context.sender)
                let name = normalizedSenderDisplayName(context.sender)
                let subject = normalizedSubject(context.subject)
                let evidenceSender = candidate.learnedEvidenceSender ?? candidate.header.sender ?? ""
                let evidenceSubject = candidate.learnedEvidenceSubject ?? candidate.header.subject ?? ""
                return MailEvidenceRecord(
                    sourceID: key, subject: evidenceSubject, excerpt: candidate.learnedEvidenceBody ?? candidate.bodyPreview,
                    sameSender: (!sender.isEmpty && sender == normalizedSender(evidenceSender))
                        || (!name.isEmpty && name == normalizedSenderDisplayName(evidenceSender)),
                    sameThread: !subject.isEmpty && subject == normalizedSubject(evidenceSubject),
                    date: candidate.header.date, isLearnedMove: candidate.isLearnedMoveCandidate,
                    moveCount: candidate.filingMemoryCount, senderMoveCount: candidate.senderMemoryCount
                )
            }
            return MailFolderEvidence(location: location, records: records,
                                      visibleRelatedCount: messages.filter { $0.mailboxPath == location.mailboxPath }.count,
                                      ambiguousAccount: accounts.count > 1)
        }
    }

    func similarMessages(from candidates: [MessageCandidate], context: MailMessageContext) -> [SimilarMessage] {
        let scored = candidates.compactMap { candidate -> (candidate: MessageCandidate, score: Double, strict: Bool)? in
            guard candidate.contributesSimilarMessage,
                  !isExcludedMailbox(candidate.mailboxInfo.mailboxPath) else {
                return nil
            }
            let sameSender = normalizedSender(candidate.header.sender ?? "") == normalizedSender(context.senderEmail ?? context.sender)
            guard sameSender || hasRelatedTextSignal(candidate, context: context) else { return nil }
            let score = relatedMessageScore(candidate, context: context)
            let strict = score >= relatedMessageMinimumScore(candidate, context: context)
            guard strict || relaxedRelatedMessageFallback(candidate, context: context, score: score) else {
                return nil
            }

            return (candidate, score, strict)
        }

        var seen = Set<String>()
        return scored
        .sorted { lhs, rhs in
            if lhs.strict != rhs.strict { return lhs.strict }
            if lhs.score == rhs.score {
                let lhsDate = lhs.candidate.header.date ?? .distantPast
                let rhsDate = rhs.candidate.header.date ?? .distantPast
                return lhsDate == rhsDate ? lhs.candidate.path < rhs.candidate.path : lhsDate > rhsDate
            }
            return lhs.score > rhs.score
        }
        // Choose the best copy after scoring; a header-only hit must not hide a richer hit.
        .filter { seen.insert(dedupeKey(for: $0.candidate)).inserted }
        .prefix(10)
        .map { item in
            let candidate = item.candidate
            return SimilarMessage(
                subject: candidate.header.subject ?? URL(fileURLWithPath: candidate.path).deletingPathExtension().lastPathComponent,
                sender: candidate.header.sender ?? "Unknown Sender",
                date: candidate.header.date,
                mailboxPath: candidate.mailboxInfo.mailboxPath,
                path: candidate.path,
                rank: candidate.rank,
                accountHint: canonicalAccountHint(candidate.mailboxInfo.accountHint, context: context)
            )
        }
    }

    private func relatedMessageScore(_ candidate: MessageCandidate, context: MailMessageContext) -> Double {
        let contextSender = normalizedSender(context.senderEmail ?? context.sender)
        let candidateSender = normalizedSender(candidate.header.sender ?? "")
        let contextSenderName = normalizedSenderDisplayName(context.sender)
        let candidateSenderName = normalizedSenderDisplayName(candidate.header.sender ?? "")
        let contextDomain = contextSender.split(separator: "@").last.map(String.init) ?? ""
        let candidateText = [
            candidate.header.sender ?? "",
            candidate.header.subject ?? "",
            candidate.bodyPreview,
            candidate.mailboxInfo.mailboxPath.joined(separator: " ")
        ]
        .joined(separator: "\n")
        .lowercased()

        let subjectMatch = MailSubjectMatch(context.subject, candidate.header.subject ?? "")

        let contextBodyTerms = Set(SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
        let candidateBodyTerms = Set(SubjectTokenizer.terms(from: candidate.bodyPreview, limit: 24))
        let bodyIntersection = contextBodyTerms.intersection(candidateBodyTerms)
        let bodyUnion = contextBodyTerms.union(candidateBodyTerms)

        let mailboxTerms = Set(SubjectTokenizer.terms(from: candidate.mailboxInfo.mailboxPath.joined(separator: " "), limit: 8))
        let contextTerms = Set(context.searchTerms.filter { $0.count >= 4 && !$0.contains("@") && !$0.contains(".") })
        let mailboxIntersection = mailboxTerms.intersection(contextTerms)

        var score = 0.0
        if candidate.isLogicalMailCandidate {
            score += 40
        }
        let sameSenderEmail = !contextSender.isEmpty && candidateSender == contextSender
        let sameSenderName = !contextSenderName.isEmpty && contextSenderName == candidateSenderName
        let sameSender = sameSenderEmail || sameSenderName
        score += subjectMatch.relatedBoost
        if sameSender { score += 45 }
        if !sameSender, !contextSender.isEmpty, candidateText.contains(contextSender) {
            score += 45
        }
        if !contextDomain.isEmpty, candidateText.contains(contextDomain) {
            score += 18
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
        let subjectOverlap = Set(MailSubjectMatch.terms(context.subject))
            .intersection(MailSubjectMatch.terms(candidate.header.subject ?? ""))
        let bodyOverlap = Set(SubjectTokenizer.terms(from: context.bodyPreview, limit: 24))
            .intersection(SubjectTokenizer.terms(from: candidate.bodyPreview, limit: 24))
        if score >= 18, !subjectOverlap.isEmpty || bodyOverlap.count >= 2 { return true }
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
        return contextDomain == candidateDomain && score >= 20 && hasRelatedTextSignal(candidate, context: context)
    }

    private func hasRelatedTextSignal(_ candidate: MessageCandidate, context: MailMessageContext) -> Bool {
        let contextSubject = normalizedSubject(context.subject)
        let candidateSubject = normalizedSubject(candidate.header.subject ?? "")
        if !contextSubject.isEmpty, contextSubject == candidateSubject {
            return true
        }

        let subjectOverlap = Set(MailSubjectMatch.terms(context.subject))
            .intersection(Set(MailSubjectMatch.terms(candidate.header.subject ?? "")))
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
        MailSubjectMatch.normalized(value)
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

    private func normalizedSenderDisplayName(_ value: String) -> String {
        normalizedDisplayName(from: value)
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

struct MailboxInfo {
    var mailboxPath: [String]
    var accountHint: String?
}

struct MessageHeader {
    var subject: String?
    var sender: String?
    var date: Date?
}

struct MessageCandidate {
    var path: String
    var rank: Int
    var supportsMailFiling: Bool
    var contributesSimilarMessage: Bool
    var mailboxInfo: MailboxInfo
    var header: MessageHeader
    var bodyPreview: String
    var filingMemoryScore: Double = 0
    var filingMemoryCount: Int = 0
    var senderMemoryCount: Int = 0
    var learnedEvidenceSender: String?
    var learnedEvidenceSubject: String?
    var learnedEvidenceBody: String?

    var isLearnedMoveCandidate: Bool {
        path.hasPrefix("shelf-learning://")
    }

    var isLogicalMailCandidate: Bool {
        path.hasPrefix("shelf-mail-message://")
    }
}

private struct SpotlightCandidateChunk {
    enum Source: Hashable {
        case cachedHeader
        case semanticSpotlight
        case threadSubjectSpotlight
        case globalHeader
        case threadHeader
        case senderSpotlight
        case senderHeader
        case learnedMoves
        case logicalMail
    }

    var source: Source
    var candidates: [MessageCandidate]
    var diagnostic: String?
    var requiresFullDiskAccess = false
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

final class SpotlightMailQuery: NSObject {
    private static let queryStringKey = "NSMetadataQueryString"
    enum SearchMode {
        case sender
        case semantic
        case threadSubject
    }

    private static var active: [UUID: SpotlightMailQuery] = [:]

    private let id = UUID()
    private let context: MailMessageContext
    private let terms: [String]
    private let limit: Int
    private let mode: SearchMode
    private let continuation: CheckedContinuation<[MessageCandidate], Never>?
    private let streamContinuation: AsyncStream<[MessageCandidate]>.Continuation?
    private var query: NSMetadataQuery?
    private var timeoutFinish: DispatchWorkItem?
    private var didResume = false
    private var lastChunkSignature = ""
    private var lastSnapshotTime = ContinuousClock.now - .seconds(1)
    private let processingQueue = DispatchQueue(label: "com.taoofmac.shelf.spotlight-results", qos: .userInitiated)
    private var processingSnapshot = false
    private var parsedMessages: [String: (header: MessageHeader, bodyPreview: String)] = [:]

    private var timeoutDelay: TimeInterval {
        switch mode {
        case .semantic, .threadSubject:
            return 4.0
        case .sender:
            return 2.5
        }
    }

    static func matchingPredicate(context: MailMessageContext, terms: [String], mode: SearchMode) -> NSPredicate {
        SpotlightMailQuery(context: context, terms: terms, limit: 80, mode: mode, streamContinuation: nil).predicate()
    }

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

    static func stream(context: MailMessageContext, terms: [String], limit: Int, mode: SearchMode) -> AsyncStream<[MessageCandidate]> {
        AsyncStream { continuation in
            DispatchQueue.main.async {
                let runner = SpotlightMailQuery(
                    context: context,
                    terms: terms,
                    limit: limit,
                    mode: mode,
                    streamContinuation: continuation
                )
                active[runner.id] = runner
                let id = runner.id
                continuation.onTermination = { _ in
                    DispatchQueue.main.async { active[id]?.finish(includeCandidates: false) }
                }
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
        self.streamContinuation = nil
        super.init()
    }

    private init(
        context: MailMessageContext,
        terms: [String],
        limit: Int,
        mode: SearchMode,
        streamContinuation: AsyncStream<[MessageCandidate]>.Continuation?
    ) {
        self.context = context
        self.terms = terms
        self.limit = limit
        self.mode = mode
        self.continuation = nil
        self.streamContinuation = streamContinuation
        super.init()
    }

    private func start() {
        guard !didResume else {
            return
        }

        let nextQuery = NSMetadataQuery()
        query = nextQuery
        nextQuery.searchScopes = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail", isDirectory: true)]
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryGatheringProgress,
            object: nextQuery
        )
        guard nextQuery.start() else {
            finish()
            return
        }

        let timeoutFinish = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        self.timeoutFinish = timeoutFinish
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutDelay, execute: timeoutFinish)
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery,
              query === self.query,
              query.resultCount > 0 else {
            return
        }
        yieldCurrentCandidates()
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        finish()
    }

    private func finish(includeCandidates: Bool = true) {
        guard !didResume else {
            return
        }
        if !includeCandidates {
            stopQuery()
            complete([])
            return
        }
        guard query != nil else {
            return
        }
        let items = snapshotItems()
        stopQuery()
        processingQueue.async {
            let candidates = self.candidates(from: items)
            DispatchQueue.main.async { self.complete(candidates) }
        }
    }

    private func stopQuery() {
        timeoutFinish?.cancel()
        timeoutFinish = nil
        query?.stop()
        self.query = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func complete(_ candidates: [MessageCandidate]) {
        guard !didResume else { return }
        didResume = true
        if let continuation {
            continuation.resume(returning: candidates)
        }
        if let streamContinuation {
            yield(candidates)
            streamContinuation.finish()
        }
        Self.active[id] = nil
    }

    private func yieldCurrentCandidates() {
        guard query != nil, streamContinuation != nil, !processingSnapshot,
              lastSnapshotTime.duration(to: .now) >= .milliseconds(300) else {
            return
        }
        lastSnapshotTime = .now

        let items = snapshotItems()
        processingSnapshot = true
        processingQueue.async {
            let candidates = self.candidates(from: items)
            DispatchQueue.main.async {
                self.processingSnapshot = false
                guard !self.didResume, self.query != nil else { return }
                self.yield(candidates)
            }
        }
    }

    private func yield(_ candidates: [MessageCandidate]) {
        guard let streamContinuation, !candidates.isEmpty else {
            return
        }

        let signature = candidates.map(\.path).joined(separator: "\u{1F}")
        guard signature != lastChunkSignature else {
            return
        }
        lastChunkSignature = signature
        streamContinuation.yield(candidates)
    }

    private func snapshotItems() -> [NSMetadataItem] {
        guard let query else { return [] }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let inspectedLimit: Int
        switch mode {
        case .semantic:
            inspectedLimit = min(max(limit * 30, 1_200), 3_000)
        case .threadSubject:
            inspectedLimit = min(max(limit * 40, 1_600), 5_000)
        case .sender:
            inspectedLimit = min(max(limit * 20, 800), 2_000)
        }
        // Retain a bounded result snapshot; never access the live query from the worker.
        return query.results.prefix(inspectedLimit).compactMap { $0 as? NSMetadataItem }
    }

    private func candidates(from items: [NSMetadataItem]) -> [MessageCandidate] {
        var seenPaths = Set<String>()
        let ranked = items
            .enumerated()
            .compactMap { index, item -> MessageCandidate? in
                guard let candidate = candidate(from: item, rank: index + 1),
                      seenPaths.insert(candidate.path).inserted else {
                    return nil
                }
                return candidate
            }
            .map { (candidate: $0, score: relevanceScore(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return (lhs.candidate.header.date ?? .distantPast) > (rhs.candidate.header.date ?? .distantPast)
                }
                return lhs.score > rhs.score
            }
            .map(\.candidate)
        return MailFilingRetrieval.candidates(ranked, context: context, limit: limit)
    }

    static func relevanceScore(for candidate: MessageCandidate, context: MailMessageContext, terms: [String], limit: Int = 80) -> Int {
        SpotlightMailQuery(context: context, terms: terms, limit: limit, mode: .semantic, streamContinuation: nil)
            .relevanceScore(for: candidate)
    }

    private func relevanceScore(for candidate: MessageCandidate) -> Int {
        let senderNeedle = normalizedEmail(context.senderEmail ?? context.sender)
        let candidateSender = normalizedEmail(candidate.header.sender ?? "")
        let contextSenderName = normalizedDisplayName(from: context.sender)
        let candidateSenderName = normalizedDisplayName(from: candidate.header.sender ?? "")
        let text = [
            candidate.header.sender ?? "",
            candidate.header.subject ?? "",
            candidate.bodyPreview,
            candidate.mailboxInfo.mailboxPath.joined(separator: " ")
        ]
        .joined(separator: "\n")
        .lowercased()

        var score = 0
        let subjectMatch = MailSubjectMatch(context.subject, candidate.header.subject ?? "")
        let sameSenderEmail = !senderNeedle.isEmpty && candidateSender == senderNeedle
        let sameSenderName = !contextSenderName.isEmpty && contextSenderName == candidateSenderName
        let sameSender = sameSenderEmail || sameSenderName
        score += subjectMatch.retrievalBoost
        if sameSender { score += 140 }
        if !sameSender, !senderNeedle.isEmpty, text.contains(senderNeedle) {
            score += 110
        }
        if let domain = senderNeedle.split(separator: "@").last, text.contains(domain.lowercased()) {
            score += 30
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

    private func normalizedSubject(_ value: String) -> String {
        MailSubjectMatch.normalized(value)
    }

    private func predicate() -> NSPredicate {
        let mailItem = mailItemPredicate()
        let needles = searchNeedles()

        guard !needles.isEmpty else {
            return NSPredicate(value: false)
        }

        if mode == .threadSubject {
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                mailItem,
                threadSubjectPredicate(needles: needles)
            ])
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

    private func threadSubjectPredicate(needles: [String]) -> NSPredicate {
        let subjectTerms = needles.prefix(8).map { "*\($0)*" }
        let perTermPredicates = subjectTerms.map { pattern in
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "kMDItemSubject LIKE[cd] %@", pattern),
                NSPredicate(format: "kMDItemTitle LIKE[cd] %@", pattern),
                NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", pattern)
            ])
        }
        guard perTermPredicates.count > 1 else {
            return NSCompoundPredicate(orPredicateWithSubpredicates: perTermPredicates)
        }
        // Two subject terms survive changing dates, prefixes and conversation titles.
        // Keep this subject-only; body matches already have their own broader query.
        let pairs = perTermPredicates.indices.flatMap { first in
            perTermPredicates.indices.dropFirst(first + 1).map { second in
                NSCompoundPredicate(andPredicateWithSubpredicates: [perTermPredicates[first], perTermPredicates[second]])
            }
        }
        return NSCompoundPredicate(orPredicateWithSubpredicates: pairs)
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
        if mode == .threadSubject {
            return Array(NSOrderedSet(array: MailSubjectMatch.terms(context.subject))) as? [String] ?? []
        }

        if mode == .semantic {
            values.append(contentsOf: MailSubjectMatch.terms(context.subject))
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
            }.filter { $0.count >= 3 })) as? [String] ?? []
        }

        if let senderEmail = context.senderEmail, !senderEmail.isEmpty {
            values.append(senderEmail)
            values.append(context.sender)
        } else if let email = EmailAddress.first(in: context.sender) {
            values.append(email)
        } else {
            values.append(normalizedDisplayName(from: context.sender))
        }

        return Array(NSOrderedSet(array: values.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count >= 4 })) as? [String] ?? []
    }

    private func candidate(from item: NSMetadataItem, rank: Int) -> MessageCandidate? {
        guard let path = item.value(forAttribute: "kMDItemPath") as? String,
              Self.isManagedMailPath(path) else {
            return nil
        }
        guard isMailItem(path: path, item: item) else {
            return nil
        }
        let parsed = parsedMessages[path] ?? parseMessage(path: path)
        parsedMessages[path] = parsed
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
            supportsMailFiling: mailboxInfo.mailboxPath != ["Mail"],
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

    static func isManagedMailPath(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = home.appendingPathComponent("Library/Mail", isDirectory: true).standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path.hasPrefix(root) && url.pathComponents.contains { $0.hasSuffix(".mbox") }
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
    private let foregroundThreadScanBudget: TimeInterval = 1.5
    private let foregroundMailboxBudget: TimeInterval = 0.45
    private let backgroundWarmInterval: TimeInterval = 15 * 60
    private let maximumStoredRecords = 120_000
    private let maximumStoredRecordsPerMailbox = 2_000
    private var loaded = false
    private var warming = false
    private var lastWarm: Date?
    private var warmEnumerator: FileManager.DirectoryEnumerator?
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
        if similarMessageCandidateCount(in: cached) >= min(4, limit),
           cached.contains(where: { MailSubjectMatch(context.subject, $0.header.subject ?? "").strong }) {
            startBackgroundWarmIfNeeded()
            return (cached, cacheDiagnostic(prefix: "Mail header cache returned", candidates: cached), !FileManager.default.isReadableFile(atPath: mailRoot.path))
        }

        let foreground = await foregroundScan(context: context, sender: sender, terms: terms, limit: limit)
        if !foreground.isEmpty {
            await save()
            startBackgroundWarmIfNeeded()
            return (foreground, cacheDiagnostic(prefix: "Mail header cache warmed", candidates: foreground), !FileManager.default.isReadableFile(atPath: mailRoot.path))
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

        let ranked = recordsByPath.values
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
        return MailFilingRetrieval.select(ranked, limit: limit) {
            MailFilingRetrieval.folderKey(path: $0.0.mailboxPath, account: $0.0.accountHint,
                                         subject: $0.0.subject, sender: $0.0.sender, context: context)
        }
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

    func threadCandidates(for context: MailMessageContext, limit: Int) async -> (candidates: [MessageCandidate], diagnostic: String, requiresFullDiskAccess: Bool) {
        await loadIfNeeded()

        let threadSubject = normalizedSubject(context.subject)
        guard !threadSubject.isEmpty, limit > 0 else {
            return ([], "Mail header thread search has no subject to search.", false)
        }

        let cached = rankedThreadCandidates(for: context, normalizedThreadSubject: threadSubject, limit: limit)
        if !cached.isEmpty {
            startBackgroundWarmIfNeeded()
            return (cached, "Mail header thread search returned \(cached.count) local thread candidate\(cached.count == 1 ? "" : "s").", !FileManager.default.isReadableFile(atPath: mailRoot.path))
        }

        let foreground = await foregroundThreadScan(context: context, normalizedThreadSubject: threadSubject, limit: limit)
        if !foreground.isEmpty {
            await save()
            startBackgroundWarmIfNeeded()
            return (foreground, "Mail header thread scan found \(foreground.count) local thread candidate\(foreground.count == 1 ? "" : "s").", false)
        }

        startBackgroundWarmIfNeeded()
        let root = mailRoot.path
        if !FileManager.default.isReadableFile(atPath: root) {
            return ([], "Mail header thread search cannot read local Mail storage. Open Full Disk Access settings and add Shelf.", true)
        }
        return ([], "Mail header thread search found no local header matches; background warmup started.", false)
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
        let roots = currentAccountRoots(for: context) + prioritizedMailboxRoots(for: context, sender: sender, terms: terms)
        for root in roots {
            scan(root: root, sender: sender, deadline: deadline, stopAfterMatches: limit)
            let candidates = rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
            if similarMessageCandidateCount(in: candidates) >= min(4, limit) || Date() >= deadline {
                return candidates
            }
        }

        if Date() < deadline {
            scan(root: mailRoot, sender: sender, deadline: deadline, stopAfterMatches: limit)
        }
        return rankedCandidates(for: context, sender: sender, terms: terms, limit: limit)
    }

    private func foregroundThreadScan(context: MailMessageContext, normalizedThreadSubject: String, limit: Int) async -> [MessageCandidate] {
        let deadline = Date().addingTimeInterval(foregroundThreadScanBudget)
        let roots = currentAccountRoots(for: context)
        for root in roots.isEmpty ? [mailRoot] : roots {
            scan(root: root, sender: nil, deadline: deadline, stopAfterMatches: nil)
        }
        return rankedThreadCandidates(for: context, normalizedThreadSubject: normalizedThreadSubject, limit: limit)
    }

    private func currentAccountRoots(for context: MailMessageContext) -> [URL] {
        guard let accountID = context.selection.first?.accountID, UUID(uuidString: accountID) != nil,
              let versions = try? FileManager.default.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: nil) else { return [] }
        return versions.filter { $0.lastPathComponent.range(of: #"^V\d+$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .prefix(3).map { $0.appendingPathComponent(accountID, isDirectory: true) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func startBackgroundWarmIfNeeded() {
        guard !warming else {
            return
        }
        if let lastWarm, Date().timeIntervalSince(lastWarm) < (warmEnumerator == nil ? backgroundWarmInterval : 30) {
            return
        }
        warming = true
        Task.detached(priority: .background) { [weak self] in
            await self?.warmAll()
        }
    }

    private func warmAll() async {
        if warmEnumerator == nil {
            warmEnumerator = FileManager.default.enumerator(
                at: mailRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        }
        // Resume the same walk after each bounded pass, yielding to foreground searches.
        let deadline = Date().addingTimeInterval(8)
        var visited = 0
        while !Task.isCancelled, Date() < deadline, visited < 8_192 {
            guard let url = warmEnumerator?.nextObject() as? URL else {
                warmEnumerator = nil
                break
            }
            visited += 1
            if url.pathExtension == "mbox" { rememberMailbox(url: url) }
            if url.pathExtension == "emlx", let record = record(for: url) { insert(record) }
            if visited.isMultiple(of: 128) {
                trimIfNeeded()
                await Task.yield()
            }
        }
        trimIfNeeded()
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
        var inserted = 0
        defer { trimIfNeeded() }
        for case let url as URL in enumerator {
            if Task.isCancelled || Date() >= deadline {
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
            inserted += 1
            if let sender, record.emails.contains(sender) {
                matches += 1
                if let stopAfterMatches, matches >= stopAfterMatches {
                    break
                }
            }
            if inserted.isMultiple(of: 128) { trimIfNeeded() }
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
        let ranked = paths
            .compactMap { recordsByPath[$0] }
            .map { ($0, score($0, terms: normalizedTerms) + MailSubjectMatch(context.subject, $0.subject ?? "").retrievalBoost) }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.date ?? lhs.0.modifiedAt) > (rhs.0.date ?? rhs.0.modifiedAt)
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
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
        let messageCandidates = MailFilingRetrieval.candidates(ranked, context: context, limit: messageLimit)
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

    private func rankedThreadCandidates(
        for context: MailMessageContext,
        normalizedThreadSubject: String,
        limit: Int
    ) -> [MessageCandidate] {
        guard !normalizedThreadSubject.isEmpty else {
            return []
        }

        let contextSender = normalizedEmail(context.senderEmail ?? context.sender)
        let contextSenderName = normalizedDisplayName(from: context.sender)
        let ranked = recordsByPath.values
            .compactMap { record -> (MailHeaderRecord, Int)? in
                guard normalizedSubject(record.subject ?? "") == normalizedThreadSubject else {
                    return nil
                }

                var score = 180
                let recordSenderName = normalizedDisplayName(from: record.sender ?? "")
                let sameSender = (!contextSender.isEmpty && record.emails.contains(contextSender))
                    || (!contextSenderName.isEmpty && contextSenderName == recordSenderName)
                if sameSender {
                    score += 180
                }
                if record.path.contains("/Library/Mail/") {
                    score += 6
                }
                return (record, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.date ?? lhs.0.modifiedAt) > (rhs.0.date ?? rhs.0.modifiedAt)
                }
                return lhs.1 > rhs.1
            }
        return MailFilingRetrieval.select(ranked, limit: limit) {
            MailFilingRetrieval.folderKey(path: $0.0.mailboxPath, account: $0.0.accountHint,
                                         subject: $0.0.subject, sender: $0.0.sender, context: context)
        }
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
        let currentSenderName = normalizedDisplayName(from: context.sender)
        let recordSenderName = normalizedDisplayName(from: record.sender ?? "")

        var score = 0
        let senderNeedle = normalizedEmail(context.senderEmail ?? context.sender)
        let exactSender = !senderNeedle.isEmpty && record.emails.contains(senderNeedle)
        let displaySender = !currentSenderName.isEmpty && currentSenderName == recordSenderName
        let sameSender = exactSender || displaySender
        score += MailSubjectMatch(context.subject, record.subject ?? "").retrievalBoost

        for term in terms {
            if subject.contains(term) {
                score += 16
            }
            if mailbox.contains(term) {
                score += 8
            }
            if sender.contains(term) {
                score += 8
            }
        }

        if sameSender {
            score += 64
        }

        return score
    }

    private func normalizedSubject(_ value: String) -> String {
        MailSubjectMatch.normalized(value)
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

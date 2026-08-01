import Foundation
import LatentSemanticMapping

private func normalizedDisplayName(from value: String) -> String {
    var cleaned = value
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

struct LearnedMoveRecommendation {
    var mailboxPath: [String]
    var accountHint: String?
    var displayPath: String
    var memoryScore: Double
    var exampleCount: Int
    var senderMatchCount: Int
    var lastMovedAt: TimeInterval
    var sampleText: String
}

actor MailMoveLearningStore {
    static let shared = MailMoveLearningStore()

    private let cacheVersion = 1
    private let maximumRecords = 1_000
    private let maximumRecordsPerMailbox = 80
    private var loaded = false
    private var records: [LearnedMailMoveRecord] = []

    func record(context: MailMessageContext, destination: RankedMessageLocation) async {
        await loadIfNeeded()

        let now = Date().timeIntervalSince1970
        let displayPath = destination.displayPath
        let record = LearnedMailMoveRecord(
            id: UUID().uuidString,
            createdAt: now,
            sender: context.sender,
            senderEmail: context.senderEmail,
            subject: context.subject,
            currentMailbox: context.currentMailbox,
            currentAccount: context.currentAccount,
            bodyPreview: context.bodyPreview,
            mailboxPath: destination.mailboxPath,
            accountHint: destination.accountHint,
            displayPath: displayPath,
            semanticText: trainingText(for: context)
        )

        records.append(record)
        trimIfNeeded()
        await save()
    }

    func recommendations(for context: MailMessageContext, limit: Int) async -> [LearnedMoveRecommendation] {
        await loadIfNeeded()
        guard !records.isEmpty, limit > 0 else {
            return []
        }

        let grouped = Dictionary(grouping: records, by: \.displayPath)
        let lsmScores = semanticScores(for: context, grouped: grouped)

        return grouped.compactMap { displayPath, mailboxRecords -> LearnedMoveRecommendation? in
            let summary = matchSummary(for: context, records: mailboxRecords)
            let lsmScore = max(0, min(lsmScores[displayPath] ?? 0, 1))
            let memoryScore = summary.score + (lsmScore * 0.35)
            guard memoryScore >= 0.20,
                  let example = summary.bestRecord ?? mailboxRecords.max(by: { $0.createdAt < $1.createdAt }) else {
                return nil
            }
            return LearnedMoveRecommendation(
                mailboxPath: example.mailboxPath,
                accountHint: example.accountHint,
                displayPath: displayPath,
                memoryScore: memoryScore,
                exampleCount: max(1, summary.matchCount),
                senderMatchCount: summary.senderMatchCount,
                lastMovedAt: summary.lastMatchedAt ?? example.createdAt,
                sampleText: example.semanticText
            )
        }
        .sorted { lhs, rhs in
            let lhsScore = lhs.memoryScore + recencyBoost(lhs.lastMovedAt)
            let rhsScore = rhs.memoryScore + recencyBoost(rhs.lastMovedAt)
            if lhsScore == rhsScore {
                return lhs.lastMovedAt > rhs.lastMovedAt
            }
            return lhsScore > rhsScore
        }
        .prefix(limit)
        .map { $0 }
    }

    private func loadIfNeeded() async {
        guard !loaded else {
            return
        }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(LearnedMailMovePayload.self, from: data),
              payload.version == cacheVersion else {
            return
        }
        records = Array(payload.records.suffix(maximumRecords))
    }

    private func save() async {
        let payload = LearnedMailMovePayload(version: cacheVersion, records: records)
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private func trimIfNeeded() {
        let grouped = Dictionary(grouping: records, by: \.displayPath)
        var trimmed: [LearnedMailMoveRecord] = []
        for mailboxRecords in grouped.values {
            trimmed.append(contentsOf: mailboxRecords.sorted { $0.createdAt > $1.createdAt }.prefix(maximumRecordsPerMailbox))
        }
        records = Array(trimmed.sorted { $0.createdAt > $1.createdAt }.prefix(maximumRecords))
    }

    private func semanticScores(
        for context: MailMessageContext,
        grouped: [String: [LearnedMailMoveRecord]]
    ) -> [String: Double] {
        guard !grouped.isEmpty else {
            return [:]
        }

        let map = LSMMapCreate(nil, CFOptionFlags(kLSMMapPairs)).takeRetainedValue()
        guard LSMMapStartTraining(map) == noErr else {
            return [:]
        }

        var categoryByPath: [String: LSMCategory] = [:]
        var pathByCategory: [LSMCategory: String] = [:]

        for (displayPath, mailboxRecords) in grouped {
            let category = LSMMapAddCategory(map)
            categoryByPath[displayPath] = category
            pathByCategory[category] = displayPath

            for record in mailboxRecords.sorted(by: { $0.createdAt > $1.createdAt }).prefix(20) {
                let text = LSMTextCreate(nil, map).takeRetainedValue()
                if LSMTextAddWords(text, record.semanticText as CFString, nil, 0) == noErr {
                    _ = LSMMapAddText(map, text, category)
                }
            }
        }

        guard !categoryByPath.isEmpty, LSMMapCompile(map) == noErr else {
            return [:]
        }

        let sample = LSMTextCreate(nil, map).takeRetainedValue()
        guard LSMTextAddWords(sample, trainingText(for: context) as CFString, nil, 0) == noErr else {
            return [:]
        }

        let result = LSMResultCreate(nil, map, sample, CFIndex(categoryByPath.count), 0).takeRetainedValue()
        var scores: [String: Double] = [:]
        for index in 0..<LSMResultGetCount(result) {
            let category = LSMResultGetCategory(result, index)
            guard let displayPath = pathByCategory[category] else {
                continue
            }
            let score = Double(LSMResultGetScore(result, index))
            if score.isFinite {
                scores[displayPath] = score
            }
        }
        return scores
    }

    private func matchSummary(
        for context: MailMessageContext,
        records: [LearnedMailMoveRecord]
    ) -> LearnedMoveMatchSummary {
        let currentSender = normalizedEmail(context.senderEmail ?? context.sender)
        let currentSenderName = normalizedDisplayName(from: context.sender)
        let currentSubject = normalizedSubject(context.subject)
        let currentSubjectTerms = Set(SubjectTokenizer.terms(from: context.subject, limit: 12))
        let currentBodyTerms = Set(SubjectTokenizer.terms(from: context.bodyPreview, limit: 30))
        let currentTerms = Set(context.searchTerms.filter { $0.count >= 4 && !$0.contains("@") })

        let matches = records
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(40)
            .compactMap { record -> LearnedMoveRecordMatch? in
                let recordSender = normalizedEmail(record.senderEmail ?? record.sender)
                let recordSenderName = normalizedDisplayName(from: record.sender)
                let sameSender = (!currentSender.isEmpty && currentSender == recordSender)
                    || (!currentSenderName.isEmpty && currentSenderName == recordSenderName)
                let sameThread = !currentSubject.isEmpty && currentSubject == normalizedSubject(record.subject)
                let subjectSimilarity = jaccard(
                    currentSubjectTerms,
                    Set(SubjectTokenizer.terms(from: record.subject, limit: 12))
                )
                let bodySimilarity = jaccard(
                    currentBodyTerms,
                    Set(SubjectTokenizer.terms(from: record.bodyPreview, limit: 30))
                )
                let recordTerms = Set(
                    SubjectTokenizer.terms(from: record.subject, limit: 12)
                        + SubjectTokenizer.terms(from: record.bodyPreview, limit: 30)
                )
                let generalSimilarity = jaccard(currentTerms, recordTerms)

                var score = 0.0
                if sameSender {
                    score += 0.95
                }
                if sameThread {
                    score += 0.80
                }
                score += subjectSimilarity * 0.55
                score += bodySimilarity * 0.30
                score += generalSimilarity * 0.25

                guard score >= 0.18 else {
                    return nil
                }
                let weightedScore = score * (0.75 + (recencyWeight(record.createdAt) * 0.25))
                return LearnedMoveRecordMatch(record: record, score: weightedScore, sameSender: sameSender)
            }

        guard let best = matches.max(by: { $0.score < $1.score }) else {
            return .empty
        }

        let rankedMatches = matches.sorted { $0.score > $1.score }
        let supportingScore = rankedMatches.dropFirst().prefix(4).reduce(0) { $0 + ($1.score * 0.18) }
        let senderMatchCount = matches.filter(\.sameSender).count
        let frequencyBoost = min(Double(matches.count), 6) * 0.05
        let senderFrequencyBoost = min(Double(senderMatchCount), 6) * 0.09
        let mostRecent = matches.map(\.record.createdAt).max()
        let recentBoost = mostRecent.map { recencyWeight($0) * 0.15 } ?? 0

        return LearnedMoveMatchSummary(
            score: best.score + supportingScore + frequencyBoost + senderFrequencyBoost + recentBoost,
            matchCount: matches.count,
            senderMatchCount: senderMatchCount,
            lastMatchedAt: mostRecent,
            bestRecord: best.record
        )
    }

    private func trainingText(for context: MailMessageContext) -> String {
        ([context.semanticText] + context.searchTerms).joined(separator: "\n")
    }

    private func normalizedEmail(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedSubject(_ value: String) -> String {
        var subject = value.lowercased()
        while true {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("re:") || trimmed.hasPrefix("fw:") {
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

    private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else {
            return 0
        }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    private func recencyWeight(_ timestamp: TimeInterval) -> Double {
        let ageInDays = max(0, Date().timeIntervalSince1970 - timestamp) / (60 * 60 * 24)
        switch ageInDays {
        case ...7:
            return 1
        case ...30:
            return 0.80
        case ...90:
            return 0.55
        case ...365:
            return 0.25
        default:
            return 0.10
        }
    }

    private func recencyBoost(_ timestamp: TimeInterval) -> Double {
        let age = max(0, Date().timeIntervalSince1970 - timestamp)
        return max(0, 0.12 - (age / (60 * 60 * 24 * 30)) * 0.12)
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("MailMoveLearning.json")
    }
}

private struct LearnedMoveRecordMatch {
    var record: LearnedMailMoveRecord
    var score: Double
    var sameSender: Bool
}

private struct LearnedMoveMatchSummary {
    var score: Double
    var matchCount: Int
    var senderMatchCount: Int
    var lastMatchedAt: TimeInterval?
    var bestRecord: LearnedMailMoveRecord?

    static let empty = LearnedMoveMatchSummary(
        score: 0,
        matchCount: 0,
        senderMatchCount: 0,
        lastMatchedAt: nil,
        bestRecord: nil
    )
}

private struct LearnedMailMovePayload: Codable {
    var version: Int
    var records: [LearnedMailMoveRecord]
}

private struct LearnedMailMoveRecord: Codable {
    var id: String
    var createdAt: TimeInterval
    var sender: String
    var senderEmail: String?
    var subject: String
    var currentMailbox: String
    var currentAccount: String?
    var bodyPreview: String
    var mailboxPath: [String]
    var accountHint: String?
    var displayPath: String
    var semanticText: String
}

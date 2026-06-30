import Foundation
import LatentSemanticMapping

struct LearnedMoveRecommendation {
    var mailboxPath: [String]
    var accountHint: String?
    var displayPath: String
    var semanticScore: Double
    var exampleCount: Int
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
        let fallbackScores = fallbackScores(for: context, grouped: grouped)

        return grouped.compactMap { displayPath, mailboxRecords -> LearnedMoveRecommendation? in
            guard let latest = mailboxRecords.max(by: { $0.createdAt < $1.createdAt }) else {
                return nil
            }
            let semanticScore = lsmScores[displayPath] ?? fallbackScores[displayPath] ?? 0
            guard semanticScore > 0 || exactSenderMatch(context: context, records: mailboxRecords) else {
                return nil
            }
            return LearnedMoveRecommendation(
                mailboxPath: latest.mailboxPath,
                accountHint: latest.accountHint,
                displayPath: displayPath,
                semanticScore: semanticScore,
                exampleCount: mailboxRecords.count,
                lastMovedAt: latest.createdAt,
                sampleText: latest.semanticText
            )
        }
        .sorted { lhs, rhs in
            let lhsScore = lhs.semanticScore + min(Double(lhs.exampleCount), 6) * 0.03 + recencyBoost(lhs.lastMovedAt)
            let rhsScore = rhs.semanticScore + min(Double(rhs.exampleCount), 6) * 0.03 + recencyBoost(rhs.lastMovedAt)
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

    private func fallbackScores(
        for context: MailMessageContext,
        grouped: [String: [LearnedMailMoveRecord]]
    ) -> [String: Double] {
        var scores: [String: Double] = [:]
        let currentTerms = Set(context.searchTerms)
        let currentSender = normalizedEmail(context.senderEmail ?? context.sender)

        for (displayPath, mailboxRecords) in grouped {
            var score = 0.0
            for record in mailboxRecords.prefix(20) {
                if normalizedEmail(record.senderEmail ?? record.sender) == currentSender {
                    score += 0.25
                }
                let recordTerms = Set(SubjectTokenizer.terms(from: record.subject) + SubjectTokenizer.terms(from: record.bodyPreview))
                let overlap = currentTerms.intersection(recordTerms).count
                score += min(Double(overlap) * 0.04, 0.24)
            }
            scores[displayPath] = score
        }
        return scores
    }

    private func exactSenderMatch(context: MailMessageContext, records: [LearnedMailMoveRecord]) -> Bool {
        let currentSender = normalizedEmail(context.senderEmail ?? context.sender)
        return records.contains { normalizedEmail($0.senderEmail ?? $0.sender) == currentSender }
    }

    private func trainingText(for context: MailMessageContext) -> String {
        ([context.semanticText] + context.searchTerms).joined(separator: "\n")
    }

    private func normalizedEmail(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

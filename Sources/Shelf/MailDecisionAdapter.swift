import Foundation
import DecisionCore

enum MailDecisionMode: String, CaseIterable { case off, shadow, rerank }
enum MailRankingPolicy: String { case full = "full-v1", protectedGroups = "protected-groups-v2" }

/// Volatile, content-free diagnostics; opaque candidate IDs only, no subjects, bodies or addresses.
struct MailDecisionRecord: Encodable {
    let namespace = "com.taoofmac.shelf"
    let workflow = "mail-folder-suggestions"
    let workflowVersion = 1
    let evidencePolicy = "mail-evidence-v1"
    let rankingPolicy = "protected-groups-v2"
    let packageVersion = DecisionVersion.package
    let contractVersion = DecisionVersion.contract
    let promptVersion = DecisionVersion.prompt
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let requestID: String
    let outcome: String
    let elapsedMilliseconds: Int
    let candidateCount: Int
    let omittedCandidates: Int
    let response: DecisionResponse?
    let fullRanking: [String]?
    let protectedRanking: [String]?
}

struct MailEvidenceRecord: Equatable, Sendable {
    let sourceID: String
    let subject: String
    let excerpt: String
    let sameSender: Bool
    let sameThread: Bool
    let date: Date?
    let isLearnedMove: Bool
    let moveCount: Int
    let senderMoveCount: Int
}

struct MailFolderEvidence: Equatable, Sendable {
    let location: RankedMessageLocation
    let records: [MailEvidenceRecord]
    let visibleRelatedCount: Int
    let ambiguousAccount: Bool

    var protectionGroup: Int {
        if visibleRelatedCount >= 1 { return 0 }
        return location.recentHitCount >= 3 || location.hitCount >= 5 ? 1 : 2
    }
}

struct MailDecisionSnapshot: Sendable {
    let generation: UUID
    let selectionSignature: String
    let request: DecisionRequest
    let fullBaseline: [RankedMessageLocation]
    let shortlist: [MailFolderEvidence]
    let omittedCandidates: Int
    let evidencePolicyVersion: String
    let evidenceSources: [String: String]
}

struct MailDecisionEvaluation: Sendable {
    let outcome: String
    let response: DecisionResponse?
    let fullRanking: [String]?
    let protectedRanking: [String]?
    let displayed: [RankedMessageLocation]
}

/// App-owned snapshots, evidence budgets and policy. The package never sees Mail objects.
enum MailDecisionAdapter {
    static let evidencePolicyVersion = "mail-evidence-v1"
    static let rankingApproved = false
    static let rubric = Rubric(id: "mail-folder-fit-v1", version: 1, levels: [
        .init(id: "unsuitable", label: "Unsuitable", description: "Evidence positively indicates a different purpose or topic."),
        .init(id: "weak", label: "Weak", description: "Broad connection with little support for filing here."),
        .init(id: "plausible", label: "Plausible", description: "Topic or usage fits; supporting evidence is incomplete."),
        .init(id: "strong", label: "Strong", description: "Clear fit supported by related messages or established filing behaviour."),
        .init(id: "direct", label: "Direct", description: "Continuation of a conversation or filing pattern represented here.")
    ])

    static func snapshot(context: MailMessageContext, folders: [MailFolderEvidence], generation: UUID) throws -> MailDecisionSnapshot {
        guard !context.selection.isEmpty else { throw DecisionFailure(.invalidRequest, "missing_message_identity") }
        guard !folders.isEmpty else { throw DecisionFailure(.invalidRequest, "empty_shortlist") }
        let shortlist = Array(folders.prefix(6))
        guard !shortlist.contains(where: \.ambiguousAccount) else { throw DecisionFailure(.invalidRequest, "ambiguous_destination") }
        struct MessageInput: Encodable {
            let sender: String; let subject: String; let bodyExcerpt: String; let omittedBodyBytes: Int
        }
        let body = excerpt(context.bodyPreview, bytes: 600)
        let state = try json(MessageInput(sender: excerpt(context.sender, bytes: 160), subject: excerpt(context.subject, bytes: 200),
                                          bodyExcerpt: body, omittedBodyBytes: max(0, context.bodyPreview.utf8.count - body.utf8.count)))
        var evidenceSources: [String: String] = [:]
        let candidates = try shortlist.enumerated().map { index, folder -> DecisionCandidate in
            struct FolderInput: Encodable {
                let account: String; let path: [String]; let relatedCount: Int; let recentCount: Int
                let visibleRelatedCount: Int; let omittedEvidenceCount: Int
            }
            let records = representatives(folder.records)
            let messages = folder.records.filter { !$0.isLearnedMove }
            let recentCutoff = Date().addingTimeInterval(-90 * 86_400)
            let text = try json(FolderInput(account: folder.location.accountHint ?? "Account unresolved",
                                           path: folder.location.mailboxPath, relatedCount: messages.count,
                                           recentCount: messages.filter { ($0.date ?? .distantPast) >= recentCutoff }.count,
                                           visibleRelatedCount: folder.visibleRelatedCount,
                                           omittedEvidenceCount: max(0, folder.records.count - records.count)))
            let evidence = try records.enumerated().map { offset, record -> Evidence in
                struct EvidenceInput: Encodable {
                    let subject: String; let partialExcerpt: String; let omittedExcerptBytes: Int
                    let sameSender: Bool; let sameThread: Bool; let previousMove: Bool
                    let moveCount: Int; let senderMoveCount: Int; let ageDays: Int?
                }
                let preview = excerpt(record.excerpt, bytes: 160)
                evidenceSources["f\(index)e\(offset)"] = record.sourceID
                return Evidence(id: "f\(index)e\(offset)", text: try json(EvidenceInput(
                    subject: excerpt(record.subject, bytes: 120), partialExcerpt: preview,
                    omittedExcerptBytes: max(0, record.excerpt.utf8.count - preview.utf8.count),
                    sameSender: record.sameSender, sameThread: record.sameThread, previousMove: record.isLearnedMove,
                    moveCount: record.moveCount, senderMoveCount: record.senderMoveCount,
                    ageDays: record.date.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) }
                )))
            }
            return DecisionCandidate(id: "f\(index)", text: text, evidence: evidence)
        }
        let request = DecisionRequest(
            identity: .init(namespace: "com.taoofmac.shelf", workflow: "mail-folder-suggestions", workflowVersion: 1,
                            requestID: generation.uuidString),
            mode: .comparative, state: state,
            assessment: .init(instruction: "Assess semantic filing suitability using only the supplied partial evidence; absent evidence is insufficient_evidence, not unsuitable.", rubric: rubric),
            candidates: candidates
        )
        // One fixed policy pass; do not trim and retry a request that exceeds this budget.
        guard try DecisionJSON.encode(request).count <= 12_000 else {
            throw DecisionFailure(.invalidRequest, "evidence_budget_exceeded")
        }
        try DecisionValidation.validate(request)
        return MailDecisionSnapshot(generation: generation, selectionSignature: context.selectionSignature, request: request,
                                    fullBaseline: folders.map(\.location), shortlist: shortlist,
                                    omittedCandidates: max(0, folders.count - shortlist.count), evidencePolicyVersion: evidencePolicyVersion,
                                    evidenceSources: evidenceSources)
    }

    static func evaluate(_ response: DecisionResponse, snapshot: MailDecisionSnapshot, mode: MailDecisionMode,
                         activeGeneration: UUID, selectionSignature: String,
                         interactionStarted: Bool, policy: MailRankingPolicy = .protectedGroups,
                         rerankingApproved: Bool = rankingApproved) -> MailDecisionEvaluation {
        let baseline = Array(snapshot.fullBaseline.prefix(5))
        func fallback(_ reason: String) -> MailDecisionEvaluation {
            .init(outcome: reason, response: nil, fullRanking: nil, protectedRanking: nil, displayed: baseline)
        }
        guard activeGeneration == snapshot.generation, selectionSignature == snapshot.selectionSignature,
              response.identity == snapshot.request.identity else { return fallback("stale_result") }
        guard response.mode == .comparative, response.answers.map(\.id) == snapshot.request.candidates.map(\.id),
              response.answers.allSatisfy({ $0.rubricID == rubric.id && $0.rubricVersion == rubric.version }) else {
            return fallback("invalid_result")
        }
        guard response.answers.allSatisfy({ $0.status == .assessed && $0.score != nil }) else {
            return .init(outcome: "insufficient_evidence", response: response, fullRanking: nil, protectedRanking: nil, displayed: baseline)
        }
        guard response.answers.allSatisfy({ answer in
            guard let index = rubric.levels.firstIndex(where: { $0.id == answer.selectedID }) else { return false }
            return answer.type == .rankedScore && answer.score == index && answer.label == rubric.levels[index].label
        }) else { return fallback("invalid_result") }
        let scores = response.answers.map { $0.score! }
        let full = stableOrder(scores: scores, groups: nil)
        let protected = stableOrder(scores: scores, groups: snapshot.shortlist.map(\.protectionGroup))
        let ids = snapshot.request.candidates.map(\.id)
        let selected = policy == .full ? full : protected
        let canApply = mode == .rerank && rerankingApproved && !interactionStarted
        let displayed = canApply ? Array(selected.prefix(5).map { snapshot.shortlist[$0].location }) : baseline
        let outcome = mode == .shadow ? "shadow_ok" : !rerankingApproved ? "rerank_not_approved"
            : interactionStarted ? "interaction_locked" : "reranked"
        return .init(outcome: outcome, response: response, fullRanking: full.map { ids[$0] },
                     protectedRanking: protected.map { ids[$0] }, displayed: displayed)
    }

    static func stableOrder(scores: [Int], groups: [Int]?) -> [Int] {
        let indices = Array(scores.indices)
        func sorted(_ values: [Int]) -> [Int] {
            values.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        }
        guard let groups else { return sorted(indices) }
        var result = indices
        for group in Set(groups) {
            let slots = indices.filter { groups[$0] == group }
            for (slot, index) in zip(slots, sorted(slots)) { result[slot] = index }
        }
        return result
    }

    private static func representatives(_ input: [MailEvidenceRecord]) -> [MailEvidenceRecord] {
        var seen = Set<String>()
        let records = input.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.sourceID < $1.sourceID
        }.filter { seen.insert($0.sourceID).inserted }
        if let memory = records.first(where: \.isLearnedMove), let message = records.first(where: { !$0.isLearnedMove }) {
            return [message, memory]
        }
        return Array(records.prefix(2))
    }

    private static func excerpt(_ text: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if count + size > bytes { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try DecisionJSON.encode(value), as: UTF8.self)
    }
}

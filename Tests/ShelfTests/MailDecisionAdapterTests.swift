import XCTest
import DecisionCore
import DecisionFoundationModels
@testable import Shelf

final class MailDecisionAdapterTests: XCTestCase, @unchecked Sendable {
    private func context() -> MailMessageContext {
        .init(sender: "Example <example@example.org>", senderEmail: "example@example.org", subject: "Design review",
              currentMailbox: "Inbox", currentAccount: "Work", bodyPreview: "Discuss the design.",
              selection: [.init(libraryID: 42, accountID: "account-1")])
    }

    private func folders() -> [MailFolderEvidence] {
        (0..<8).map { index in
            let location = RankedMessageLocation(mailboxPath: ["Projects", "Project \(index)"], accountHint: "Work",
                                                 score: Double(1000 - index), semanticScore: 0.5, hitCount: index == 0 ? 6 : 1,
                                                 samplePath: "fixture-\(index)")
            return MailFolderEvidence(location: location, records: [
                .init(sourceID: "m\(index)", subject: "Example", excerpt: "A design discussion", sameSender: true,
                      sameThread: false, date: Date(timeIntervalSince1970: 100), isLearnedMove: false, moveCount: 0, senderMoveCount: 0)
            ], visibleRelatedCount: index == 0 ? 2 : 0, ambiguousAccount: false)
        }
    }

    func testSnapshotPreservesFullBaselineAndIncludesMoreThanFive() throws {
        let snapshot = try MailDecisionAdapter.snapshot(context: context(), folders: folders(), generation: UUID())
        XCTAssertEqual(snapshot.fullBaseline, folders().map(\.location))
        XCTAssertEqual(snapshot.shortlist.count, 6)
        XCTAssertEqual(snapshot.omittedCandidates, 2)
        XCTAssertEqual(snapshot.request.candidates.map(\.id), ["f0", "f1", "f2", "f3", "f4", "f5"])
        XCTAssertFalse(snapshot.request.candidates[0].text.contains("semanticScore"))
    }

    func testShadowAndUnscorableResultsPreserveAllBaselineActions() throws {
        let snapshot = try MailDecisionAdapter.snapshot(context: context(), folders: folders(), generation: UUID())
        for unknown in [false, true] {
            let answers = snapshot.request.candidates.enumerated().map { index, candidate in
                ModelAnswer(id: candidate.id, status: unknown && index == 0 ? .insufficientEvidence : .assessed,
                            selectedID: unknown && index == 0 ? nil : index == 5 ? "direct" : "weak")
            }
            let response = try DecisionValidation.assemble(answers, for: snapshot.request)
            let result = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: .shadow,
                                                       activeGeneration: snapshot.generation, selectionSignature: context().selectionSignature,
                                                       interactionStarted: false)
            XCTAssertEqual(result.displayed, Array(snapshot.fullBaseline.prefix(5)))
            XCTAssertEqual(result.outcome, unknown ? "insufficient_evidence" : "shadow_ok")
            XCTAssertEqual(result.fullRanking?.first, unknown ? nil : "f5")
            XCTAssertEqual(result.protectedRanking?.first, unknown ? nil : "f0")
        }
    }

    func testStaleIdentityGatingAndInteractionLock() throws {
        let snapshot = try MailDecisionAdapter.snapshot(context: context(), folders: folders(), generation: UUID())
        let response = try DecisionValidation.assemble(snapshot.request.candidates.map { .init(id: $0.id, selectedID: "strong") }, for: snapshot.request)
        let stale = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: .rerank, activeGeneration: UUID(),
                                                 selectionSignature: context().selectionSignature, interactionStarted: false)
        XCTAssertEqual(stale.outcome, "stale_result")
        for approved in [false, true] {
            let result = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: .rerank, activeGeneration: snapshot.generation,
                                                       selectionSignature: context().selectionSignature, interactionStarted: true,
                                                       rerankingApproved: approved)
            XCTAssertEqual(result.displayed, Array(snapshot.fullBaseline.prefix(5)))
            XCTAssertEqual(result.outcome, approved ? "interaction_locked" : "rerank_not_approved")
        }
        var changed = context()
        changed.selection = [.init(libraryID: 43, accountID: "account-1")]
        XCTAssertNotEqual(changed.selectionSignature, snapshot.selectionSignature)
        let wrongSelection = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: .shadow, activeGeneration: snapshot.generation,
                                                          selectionSignature: changed.selectionSignature, interactionStarted: false)
        XCTAssertEqual(wrongSelection.outcome, "stale_result")
    }

    func testStablePolicyDoesNotMixProtectedGroups() {
        XCTAssertEqual(MailDecisionAdapter.stableOrder(scores: [1, 4, 3, 3], groups: nil), [1, 2, 3, 0])
        XCTAssertEqual(MailDecisionAdapter.stableOrder(scores: [1, 4, 3, 3], groups: [0, 1, 1, 1]), [0, 1, 2, 3])
    }

    func testMoveRemainsBoundToCapturedMessageAccountAndFolder() {
        let destination = MailDestinationIdentity(accountID: "account-1", path: ["Projects", "A"])
        let binding = MailActionBinding(selection: context().selection, destination: destination)
        XCTAssertTrue(binding.matches(selection: context().selection, destination: destination))
        XCTAssertFalse(binding.matches(selection: [.init(libraryID: 43, accountID: "account-1")], destination: destination))
        XCTAssertFalse(binding.matches(selection: [.init(libraryID: 42, accountID: "account-2")], destination: destination))
        XCTAssertFalse(binding.matches(selection: context().selection, destination: .init(accountID: "account-2", path: destination.path)))
        XCTAssertFalse(binding.matches(selection: context().selection, destination: .init(accountID: "account-1", path: ["Projects", "B"])))
        XCTAssertFalse(binding.matches(selection: context().selection, destination: nil))
    }

    func testAmbiguousAccountsAndUnboundedFolderDataFallBackBeforeInference() {
        let first = folders()[0]
        let ambiguous = MailFolderEvidence(location: first.location, records: first.records, visibleRelatedCount: 0, ambiguousAccount: true)
        XCTAssertThrowsError(try MailDecisionAdapter.snapshot(context: context(), folders: [ambiguous], generation: UUID()))
        var huge = first.location
        huge.mailboxPath = [String(repeating: "x", count: 20_000)]
        XCTAssertThrowsError(try MailDecisionAdapter.snapshot(context: context(), folders: [
            .init(location: huge, records: first.records, visibleRelatedCount: 0, ambiguousAccount: false)
        ], generation: UUID()))
    }

    func testOptInSixFolderLocalModelSnapshot() async throws {
        guard ProcessInfo.processInfo.environment["TYPED_DECISIONS_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in synthetic Mail snapshot; no Mail access.")
        }
        let model = AppleDecisionModel()
        let availability = await model.availability()
        guard availability.available else { throw XCTSkip(availability.reason) }
        let snapshot = try MailDecisionAdapter.snapshot(context: context(), folders: folders(), generation: UUID())
        let start = ContinuousClock.now
        let response = try await DecisionEngine(model: model).decide(snapshot.request, timeout: .seconds(8))
        XCTAssertEqual(response.answers.map(\.id), snapshot.request.candidates.map(\.id))
        let result = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: .shadow,
                                                  activeGeneration: snapshot.generation, selectionSignature: context().selectionSignature,
                                                  interactionStarted: false)
        XCTAssertEqual(result.displayed, Array(snapshot.fullBaseline.prefix(5)))
        print("Synthetic six-folder snapshot: \(start.duration(to: .now)); outcome=\(result.outcome); full=\(result.fullRanking ?? []); protected=\(result.protectedRanking ?? [])")
    }
}

import XCTest
import DecisionCore
import DecisionFoundationModels

private actor RecordingModel: DecisionModel {
    private(set) var batches: [ModelBatch] = []
    let failure: DecisionFailure?
    init(failure: DecisionFailure? = nil) { self.failure = failure }
    func availability() -> ModelAvailability { .init(available: true, metadata: "fake") }
    func generate(_ batch: ModelBatch) async throws -> [ModelAnswer] {
        batches.append(batch)
        if let failure { throw failure }
        return batch.fields.map { field in
            .init(id: field.question.id, booleanValue: field.question.type == .boolean ? true : nil,
                  selectedID: field.question.type == .boolean ? nil : (field.question.rubric?.levels ?? field.question.options).last!.id)
        }
    }
    func calls() -> [[String]] { batches.map { $0.fields.map { $0.question.id } } }
}

final class EngineTests: XCTestCase, @unchecked Sendable {
    func testIndependentQuestionsAndWorkflowsRemainIsolated() async throws {
        let model = RecordingModel()
        let engine = DecisionEngine(model: model)
        let first = try await engine.decide(ContractTests.request())
        let second = try await engine.decide(ContractTests.comparative())
        let calls = await model.calls()
        XCTAssertEqual(calls, [["blocked"], ["team"], ["severity"], ["a", "b"]])
        XCTAssertEqual(first.answers.count, 3)
        XCTAssertEqual(second.answers.count, 2)
    }

    func testErrorsNeverBecomeFalseOrPartialResults() async throws {
        for code: DecisionFailure.Code in [.refused, .contextLimit, .modelUnavailable, .generationFailed] {
            let engine = DecisionEngine(model: RecordingModel(failure: .init(code, "fixture")))
            do { _ = try await engine.decide(ContractTests.request()); XCTFail("Expected failure") }
            catch { XCTAssertEqual((error as? DecisionFailure)?.code, code) }
        }
    }

    func testComparativePermutationRestoresInputIdentityOrder() async throws {
        let original = ContractTests.comparative()
        let reversed = DecisionRequest(identity: original.identity, mode: .comparative, state: original.state,
                                       assessment: original.assessment, candidates: original.candidates.reversed())
        let engine = DecisionEngine(model: RecordingModel())
        let result = try await engine.decide(reversed)
        XCTAssertEqual(result.answers.map(\.id), ["b", "a"])
    }
}

final class LocalModelTests: XCTestCase, @unchecked Sendable {
    func testOptInLocalModelContracts() async throws {
        guard ProcessInfo.processInfo.environment["TYPED_DECISIONS_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set TYPED_DECISIONS_LIVE_TESTS=1 on an eligible Mac to run synthetic model fixtures.")
        }
        let model = AppleDecisionModel()
        let availability = await model.availability()
        guard availability.available else { throw XCTSkip(availability.reason) }
        let engine = DecisionEngine(model: model)
        let comparison = DecisionRequest(identity: ContractTests.request().identity, mode: .comparative,
            state: "Assess the operational impact of each service incident.",
            assessment: .init(instruction: "Assess each incident's operational impact. Both incidents contain sufficient evidence.", rubric: ContractTests.rubric),
            candidates: [
                .init(id: "a", text: "Service outage", evidence: [.init(id: "e1", text: "Every user is blocked; no workaround exists.")]),
                .init(id: "b", text: "Cosmetic issue", evidence: [.init(id: "e2", text: "A label is misspelled; work continues normally with limited impact.")])
            ])
        let withoutReferences = DecisionRequest(identity: comparison.identity, mode: .comparative, state: comparison.state,
                                                 assessment: comparison.assessment,
                                                 candidates: comparison.candidates.map { .init(id: $0.id, text: $0.text) })
        for request in [ContractTests.request(), withoutReferences, comparison] {
            let start = ContinuousClock.now
            let result = try await engine.decide(request, timeout: .seconds(20))
            XCTAssertEqual(result.identity, request.identity)
            XCTAssertEqual(result.answers.count, request.mode == .independent ? 3 : 2)
            print("Local model contract \(request.mode.rawValue): \(start.duration(to: .now)); \(result.osVersion)")
        }
    }
}

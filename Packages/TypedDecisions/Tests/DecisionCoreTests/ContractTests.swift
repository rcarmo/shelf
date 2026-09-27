import XCTest
@testable import DecisionCore

final class ContractTests: XCTestCase {
    static let rubric = Rubric(id: "severity", version: 1, levels: [
        .init(id: "low", label: "Low", description: "Limited impact"),
        .init(id: "high", label: "High", description: "Work is blocked")
    ])

    static func request(id: String = "r1") -> DecisionRequest {
        .init(identity: .init(namespace: "test", workflow: "triage", workflowVersion: 1, requestID: id), state: "A service outage.", questions: [
            .init(id: "blocked", type: .boolean, prompt: "Blocked?", yesWhen: "Explicitly blocked", noWhen: "Otherwise, including absent evidence"),
            .init(id: "team", type: .choice, prompt: "Choose team", options: [.init(id: "ops", label: "Operations", description: "Service incidents")]),
            .init(id: "severity", type: .rankedScore, prompt: "Impact?", rubric: rubric, allowInsufficientEvidence: true)
        ])
    }

    static func comparative() -> DecisionRequest {
        .init(identity: request().identity, mode: .comparative, state: "Service outage", assessment: .init(instruction: "Assess relevance", rubric: rubric), candidates: [
            .init(id: "a", text: "First", evidence: [.init(id: "e1", text: "First evidence")]),
            .init(id: "b", text: "Second", evidence: [.init(id: "e2", text: "Second evidence")])
        ])
    }

    func testTypedValuesAndDeclarationOrderAreDerived() throws {
        let response = try DecisionValidation.assemble([
            .init(id: "severity", selectedID: "high"), .init(id: "team", selectedID: "ops"), .init(id: "blocked", booleanValue: true)
        ], for: Self.request())
        XCTAssertEqual(response.answers.map(\.id), ["blocked", "team", "severity"])
        XCTAssertEqual(response.answers[1].label, "Operations")
        XCTAssertEqual(response.answers[2].score, 1)
        XCTAssertEqual(response.answers[2].rubricVersion, 1)
    }

    func testUnknownMissingDuplicateIDsAndCrossCandidateEvidenceFail() throws {
        for answers: [ModelAnswer] in [
            [.init(id: "a", selectedID: "high")],
            [.init(id: "a", selectedID: "high"), .init(id: "a", selectedID: "low")],
            [.init(id: "a", selectedID: "invented"), .init(id: "b", selectedID: "low")],
            [.init(id: "a", selectedID: "high", evidenceIDs: ["e2"]), .init(id: "b", selectedID: "low")],
            [.init(id: "a", selectedID: "high"), .init(id: "unknown", selectedID: "low")]
        ] {
            XCTAssertThrowsError(try DecisionValidation.assemble(answers, for: Self.comparative()))
        }
    }

    func testInsufficientEvidenceHasNoValue() throws {
        let result = try DecisionValidation.assemble([
            .init(id: "a", status: .insufficientEvidence), .init(id: "b", selectedID: "low")
        ], for: Self.comparative())
        XCTAssertNil(result.answers[0].score)
        XCTAssertNil(result.answers[0].label)
        XCTAssertThrowsError(try DecisionValidation.assemble([
            .init(id: "a", status: .insufficientEvidence, selectedID: "low"), .init(id: "b", selectedID: "low")
        ], for: Self.comparative()))
    }

    func testStrictJSONAndDefinitionValidation() throws {
        let data = try DecisionJSON.encode(Self.request())
        XCTAssertEqual(try DecisionJSON.decodeRequest(data), Self.request())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["confidence"] = 0.9
        XCTAssertThrowsError(try DecisionJSON.decodeRequest(JSONSerialization.data(withJSONObject: object)))
        let duplicate = DecisionRequest(identity: Self.request().identity, mode: .comparative, state: "x",
                                        assessment: Self.comparative().assessment,
                                        candidates: [.init(id: "a", text: "x"), .init(id: "a", text: "y")])
        XCTAssertThrowsError(try DecisionValidation.validate(duplicate))
        XCTAssertThrowsError(try DecisionValidation.validate(.init(identity: Self.request().identity, state: "x", questions: [
            .init(id: "bad", type: .boolean, prompt: "Is this true?")
        ])))
    }
}

private actor ControlledModel: DecisionModel {
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    var waitForStart: [CheckedContinuation<Void, Never>] = []
    func availability() -> ModelAvailability { .init(available: true, metadata: "fake") }
    func generate(_ batch: ModelBatch) async throws -> [ModelAnswer] {
        calls += 1
        // Deliberately ignores cancellation until released, like a slow framework cleanup.
        await withCheckedContinuation { continuation in
            pending = continuation
            for waiter in waitForStart { waiter.resume() }
            waitForStart = []
        }
        return batch.fields.map { .init(id: $0.question.id, selectedID: "high") }
    }
    func started() async {
        if calls > 0 { return }
        await withCheckedContinuation { waitForStart.append($0) }
    }
    func release() { pending?.resume(); pending = nil }
}

final class AdmissionTests: XCTestCase, @unchecked Sendable {
    func testTimeoutReturnsButGateStaysBusyUntilWorkerTerminates() async throws {
        let model = ControlledModel()
        let engine = DecisionEngine(model: model)
        let request = ContractTests.comparative()
        let task = Task { try await engine.decide(request, timeout: .milliseconds(40)) }
        await model.started()
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? DecisionFailure)?.code, .timeout) }
        do { _ = try await engine.decide(request); XCTFail("Expected busy") }
        catch { XCTAssertEqual((error as? DecisionFailure)?.code, .busy) }
        await model.release()
    }

    func testCancellationDoesNotAdmitReplacementOverRunningWork() async throws {
        let model = ControlledModel()
        let engine = DecisionEngine(model: model)
        let task = Task { try await engine.decide(ContractTests.comparative()) }
        await model.started()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? DecisionFailure)?.code, .cancelled) }
        do { _ = try await engine.decide(ContractTests.comparative()); XCTFail("Expected busy") }
        catch { XCTAssertEqual((error as? DecisionFailure)?.code, .busy) }
        await model.release()
    }
}

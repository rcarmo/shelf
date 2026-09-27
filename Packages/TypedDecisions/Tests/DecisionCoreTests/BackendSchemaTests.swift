import XCTest
import FoundationModels
@testable import DecisionCore
@testable import DecisionFoundationModels

final class BackendSchemaTests: XCTestCase {
    func testComparativeSchemaNullValueAndEvidenceReferences() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires FoundationModels SDK runtime") }
        let request = ContractTests.comparative()
        let batch = ModelBatch(state: request.state, fields: DecisionValidation.fields(for: request), mode: .comparative)
        let model = AppleDecisionModel()
        _ = try model.compileSchema(batch)
        let content = try GeneratedContent(json: """
        {"a0":{"status":"insufficient_evidence","value":null,"support":{"r0":false}},"a1":{"status":"assessed","value":"high","support":{"r0":true}}}
        """)
        let answers = try model.decode(content, batch: batch)
        let response = try DecisionValidation.assemble(answers, for: request)
        XCTAssertNil(response.answers[0].score)
        XCTAssertEqual(response.answers[1].evidenceIDs, ["e2"])
        XCTAssertThrowsError(try model.decode(GeneratedContent(json: "{\"invented\":true}"), batch: batch))
    }
}

import Foundation

public enum DecisionValidation {
    public static func validate(_ request: DecisionRequest, limits: DecisionLimits = .init()) throws {
        let identity = request.identity
        try require(identity.contractVersion == DecisionVersion.contract, "contract_version")
        try require(validID(identity.namespace) && validID(identity.workflow) && validID(identity.requestID)
                    && identity.workflowVersion > 0, "identity")
        try require(!request.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty_state")
        switch request.mode {
        case .independent:
            try require(!request.questions.isEmpty && request.questions.count <= limits.questions
                        && request.assessment == nil && request.candidates.isEmpty, "independent_shape")
            try unique(request.questions.map(\.id))
            for question in request.questions { try validate(question, limits: limits) }
            try validateEvidence(request.evidence)
        case .comparative:
            try require(request.questions.isEmpty && request.evidence.isEmpty && !request.candidates.isEmpty
                        && request.candidates.count <= limits.candidates, "comparative_shape")
            guard let assessment = request.assessment else { throw invalid("missing_assessment") }
            try require(!assessment.instruction.isEmpty, "empty_instruction")
            try validate(assessment.rubric, limits: limits)
            try unique(request.candidates.map(\.id))
            for candidate in request.candidates {
                try require(!candidate.text.isEmpty, "empty_candidate")
                try validateEvidence(candidate.evidence)
            }
        }
        let evidence = request.evidence + request.candidates.flatMap(\.evidence)
        try require(evidence.count <= limits.evidenceEntries, "evidence_limit")
        let bytes = request.state.utf8.count + request.candidates.reduce(0) { $0 + $1.text.utf8.count }
            + evidence.reduce(0) { $0 + $1.text.utf8.count }
        try require(bytes <= limits.inputBytes, "input_bytes")
        let encoded = try JSONEncoder().encode(request)
        try require(encoded.count - bytes <= limits.definitionBytes, "definition_bytes")
    }

    static func fields(for request: DecisionRequest) -> [ModelField] {
        if let assessment = request.assessment, request.mode == .comparative {
            return request.candidates.map {
                ModelField(question: Question(id: $0.id, type: .rankedScore, prompt: assessment.instruction,
                                             rubric: assessment.rubric,
                                             allowInsufficientEvidence: assessment.allowInsufficientEvidence),
                           data: $0.text, evidence: $0.evidence)
            }
        }
        return request.questions.map { ModelField(question: $0, data: "", evidence: request.evidence) }
    }

    public static func assemble(_ answers: [ModelAnswer], for request: DecisionRequest,
                                modelMetadata: String = "unspecified", limits: DecisionLimits = .init()) throws -> DecisionResponse {
        try validate(request, limits: limits)
        let fields = fields(for: request)
        guard answers.count == fields.count, Set(answers.map(\.id)).count == answers.count,
              Set(answers.map(\.id)) == Set(fields.map { $0.question.id }) else {
            throw DecisionFailure(.generationFailed, "answer_membership")
        }
        let byID = Dictionary(uniqueKeysWithValues: answers.map { ($0.id, $0) })
        let values = try fields.map { field -> DecisionAnswer in
            let question = field.question
            let answer = byID[question.id]!
            guard Set(answer.evidenceIDs).count == answer.evidenceIDs.count,
                  Set(answer.evidenceIDs).isSubset(of: Set(field.evidence.map(\.id))) else {
                throw DecisionFailure(.generationFailed, "evidence_membership")
            }
            var label: String?
            var score: Int?
            if answer.status == .insufficientEvidence {
                guard question.allowInsufficientEvidence, answer.booleanValue == nil, answer.selectedID == nil else {
                    throw DecisionFailure(.generationFailed, "insufficient_evidence_value")
                }
            } else if question.type == .boolean {
                guard answer.booleanValue != nil, answer.selectedID == nil else {
                    throw DecisionFailure(.generationFailed, "boolean_value")
                }
            } else {
                let options = question.rubric?.levels ?? question.options
                guard answer.booleanValue == nil, let selected = answer.selectedID,
                      let index = options.firstIndex(where: { $0.id == selected }) else {
                    throw DecisionFailure(.generationFailed, "selection_membership")
                }
                label = options[index].label
                score = question.type == .rankedScore ? index : nil
            }
            return DecisionAnswer(id: question.id, type: question.type, status: answer.status,
                                  booleanValue: answer.booleanValue, selectedID: answer.selectedID,
                                  label: label, score: score, rubricID: question.rubric?.id,
                                  rubricVersion: question.rubric?.version, evidenceIDs: answer.evidenceIDs)
        }
        return DecisionResponse(identity: request.identity, mode: request.mode, answers: values,
                                packageVersion: DecisionVersion.package, promptVersion: DecisionVersion.prompt,
                                osVersion: ProcessInfo.processInfo.operatingSystemVersionString, modelMetadata: modelMetadata)
    }

    private static func validate(_ question: Question, limits: DecisionLimits) throws {
        try require(validID(question.id) && !question.prompt.isEmpty, "question")
        switch question.type {
        case .boolean:
            try require(question.yesWhen?.isEmpty == false && question.noWhen?.isEmpty == false
                        && question.options.isEmpty && question.rubric == nil, "boolean_criteria")
        case .choice:
            try require(question.yesWhen == nil && question.noWhen == nil && question.rubric == nil, "choice_shape")
            try validateOptions(question.options, minimum: 1, limits: limits)
        case .rankedScore:
            try require(question.yesWhen == nil && question.noWhen == nil && question.options.isEmpty, "rubric_shape")
            guard let rubric = question.rubric else { throw invalid("missing_rubric") }
            try validate(rubric, limits: limits)
        }
    }

    private static func validate(_ rubric: Rubric, limits: DecisionLimits) throws {
        try require(validID(rubric.id) && rubric.version > 0, "rubric_identity")
        try validateOptions(rubric.levels, minimum: 2, limits: limits)
    }

    private static func validateOptions(_ options: [ChoiceOption], minimum: Int, limits: DecisionLimits) throws {
        try require(options.count >= minimum && options.count <= limits.options, "option_count")
        try unique(options.map(\.id))
        try require(Set(options.map(\.label)).count == options.count
                    && options.allSatisfy { !$0.label.isEmpty && !$0.description.isEmpty }, "option_definition")
    }

    private static func validateEvidence(_ evidence: [Evidence]) throws {
        try unique(evidence.map(\.id))
        try require(evidence.allSatisfy { !$0.text.isEmpty }, "empty_evidence")
    }

    private static func unique(_ ids: [String]) throws {
        try require(ids.allSatisfy(validID) && Set(ids).count == ids.count, "duplicate_or_invalid_id")
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.contains(where: { $0.isNewline || $0.isWhitespace })
    }
    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw invalid(reason) }
    }
    private static func invalid(_ reason: String) -> DecisionFailure { .init(.invalidRequest, reason) }
}

/// Strict replay boundary: synthesized Codable normally ignores unknown keys.
public enum DecisionJSON {
    public static func decodeRequest(_ data: Data) throws -> DecisionRequest {
        guard data.count <= 64_000 else { throw DecisionFailure(.invalidRequest, "json_bytes") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try check(object, kind: "request")
            let request = try JSONDecoder().decode(DecisionRequest.self, from: data)
            try DecisionValidation.validate(request)
            return request
        } catch let failure as DecisionFailure { throw failure }
        catch { throw DecisionFailure(.invalidRequest, "json_shape") }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func check(_ value: Any, kind: String) throws {
        let keys: [String: Set<String>] = [
            "request": ["identity", "mode", "state", "questions", "evidence", "assessment", "candidates"],
            "identity": ["namespace", "workflow", "workflowVersion", "requestID", "contractVersion"],
            "question": ["id", "type", "prompt", "yesWhen", "noWhen", "options", "rubric", "allowInsufficientEvidence"],
            "option": ["id", "label", "description"], "rubric": ["id", "version", "levels"],
            "evidence": ["id", "text"], "candidate": ["id", "text", "evidence"],
            "assessment": ["instruction", "rubric", "allowInsufficientEvidence"]
        ]
        guard let object = value as? [String: Any], let allowed = keys[kind],
              Set(object.keys).isSubset(of: allowed) else {
            throw DecisionFailure(.invalidRequest, "unknown_fields_or_shape")
        }
        let children = ["identity": "identity", "rubric": "rubric", "assessment": "assessment"]
        let arrays = ["questions": "question", "options": "option", "levels": "option", "evidence": "evidence", "candidates": "candidate"]
        for (key, child) in children where object[key] != nil && !(object[key] is NSNull) {
            try check(object[key]!, kind: child)
        }
        for (key, child) in arrays where object[key] != nil {
            guard let items = object[key] as? [Any] else { throw DecisionFailure(.invalidRequest, "array_shape") }
            for item in items { try check(item, kind: child) }
        }
    }
}

import Foundation

public enum DecisionVersion {
    public static let package = "0.1.0"
    public static let contract = 1
    public static let prompt = 1
}

public struct RequestIdentity: Codable, Equatable, Sendable {
    public let namespace: String
    public let workflow: String
    public let workflowVersion: Int
    public let requestID: String
    public let contractVersion: Int

    public init(namespace: String, workflow: String, workflowVersion: Int, requestID: String,
                contractVersion: Int = DecisionVersion.contract) {
        self.namespace = namespace
        self.workflow = workflow
        self.workflowVersion = workflowVersion
        self.requestID = requestID
        self.contractVersion = contractVersion
    }
}

public enum DecisionMode: String, Codable, Sendable { case independent, comparative }
public enum DecisionKind: String, Codable, Sendable { case boolean, choice, rankedScore = "ranked_score" }
public enum AssessmentStatus: String, Codable, Sendable { case assessed, insufficientEvidence = "insufficient_evidence" }

public struct ChoiceOption: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public init(id: String, label: String, description: String) {
        self.id = id; self.label = label; self.description = description
    }
}

public struct Rubric: Codable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public let levels: [ChoiceOption]
    public init(id: String, version: Int, levels: [ChoiceOption]) {
        self.id = id; self.version = version; self.levels = levels
    }
}

public struct Evidence: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct Question: Codable, Equatable, Sendable {
    public let id: String
    public let type: DecisionKind
    public let prompt: String
    public let yesWhen: String?
    public let noWhen: String?
    public let options: [ChoiceOption]
    public let rubric: Rubric?
    public let allowInsufficientEvidence: Bool

    public init(id: String, type: DecisionKind, prompt: String, yesWhen: String? = nil,
                noWhen: String? = nil, options: [ChoiceOption] = [], rubric: Rubric? = nil,
                allowInsufficientEvidence: Bool = false) {
        self.id = id; self.type = type; self.prompt = prompt
        self.yesWhen = yesWhen; self.noWhen = noWhen; self.options = options
        self.rubric = rubric; self.allowInsufficientEvidence = allowInsufficientEvidence
    }
}

public struct ComparativeAssessment: Codable, Equatable, Sendable {
    public let instruction: String
    public let rubric: Rubric
    public let allowInsufficientEvidence: Bool
    public init(instruction: String, rubric: Rubric, allowInsufficientEvidence: Bool = true) {
        self.instruction = instruction; self.rubric = rubric
        self.allowInsufficientEvidence = allowInsufficientEvidence
    }
}

public struct DecisionCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let evidence: [Evidence]
    public init(id: String, text: String, evidence: [Evidence] = []) {
        self.id = id; self.text = text; self.evidence = evidence
    }
}

public struct DecisionRequest: Codable, Equatable, Sendable {
    public let identity: RequestIdentity
    public let mode: DecisionMode
    public let state: String
    public let questions: [Question]
    public let evidence: [Evidence]
    public let assessment: ComparativeAssessment?
    public let candidates: [DecisionCandidate]

    public init(identity: RequestIdentity, mode: DecisionMode = .independent, state: String,
                questions: [Question] = [], evidence: [Evidence] = [],
                assessment: ComparativeAssessment? = nil, candidates: [DecisionCandidate] = []) {
        self.identity = identity; self.mode = mode; self.state = state
        self.questions = questions; self.evidence = evidence
        self.assessment = assessment; self.candidates = candidates
    }
}

public struct DecisionLimits: Sendable {
    public var questions = 8
    public var candidates = 8
    public var options = 16
    public var evidenceEntries = 32
    public var inputBytes = 24_000
    public var definitionBytes = 12_000
    public init() {}
}

public struct DecisionFailure: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request", modelUnavailable = "model_unavailable"
        case contextLimit = "context_limit", refused, timeout, busy, cancelled
        case generationFailed = "generation_failed"
    }
    public let code: Code
    // Machine-readable, content-free detail; never an underlying model error description.
    public let reason: String
    public init(_ code: Code, _ reason: String) { self.code = code; self.reason = reason }
}

public struct DecisionAnswer: Codable, Equatable, Sendable {
    public let id: String
    public let type: DecisionKind
    public let status: AssessmentStatus
    public let booleanValue: Bool?
    public let selectedID: String?
    public let label: String?
    public let score: Int?
    public let rubricID: String?
    public let rubricVersion: Int?
    public let evidenceIDs: [String]
}

public struct DecisionResponse: Codable, Equatable, Sendable {
    public let identity: RequestIdentity
    public let mode: DecisionMode
    public let answers: [DecisionAnswer]
    public let packageVersion: String
    public let promptVersion: Int
    public let osVersion: String
    public let modelMetadata: String
}

public struct ModelAvailability: Codable, Equatable, Sendable {
    public let available: Bool
    public let reason: String
    public let metadata: String
    public init(available: Bool, reason: String = "available", metadata: String = "unspecified") {
        self.available = available; self.reason = reason; self.metadata = metadata
    }
}

/// One generation contract, containing trusted definitions and separately encoded untrusted data.
public struct ModelBatch: Sendable {
    public let state: String
    public let fields: [ModelField]
    public let mode: DecisionMode
}

public struct ModelField: Sendable {
    public let question: Question
    public let data: String
    public let evidence: [Evidence]
}

/// Only selections are supplied by the model; labels and scores are derived by the core.
public struct ModelAnswer: Sendable {
    public let id: String
    public let status: AssessmentStatus
    public let booleanValue: Bool?
    public let selectedID: String?
    public let evidenceIDs: [String]
    public init(id: String, status: AssessmentStatus = .assessed, booleanValue: Bool? = nil,
                selectedID: String? = nil, evidenceIDs: [String] = []) {
        self.id = id; self.status = status; self.booleanValue = booleanValue
        self.selectedID = selectedID; self.evidenceIDs = evidenceIDs
    }
}

public protocol DecisionModel: Sendable {
    func availability() async -> ModelAvailability
    /// Must create a fresh session and propagate task cancellation, with no tools or retries.
    func generate(_ batch: ModelBatch) async throws -> [ModelAnswer]
}

public struct DecisionDiagnostic: Codable, Sendable {
    public let identity: RequestIdentity
    public let outcome: String
    public let elapsedMilliseconds: Int
}

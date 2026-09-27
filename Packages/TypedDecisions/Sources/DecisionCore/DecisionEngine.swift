import Foundation

/// One instance per application process. Actor isolation alone is not the admission gate.
public actor DecisionEngine {
    private let model: any DecisionModel
    private let limits: DecisionLimits
    private let diagnostics: @Sendable (DecisionDiagnostic) -> Void
    private var active: Pending?

    private struct Pending {
        let token: UUID
        let identity: RequestIdentity
        let start: ContinuousClock.Instant
        var continuation: CheckedContinuation<DecisionResponse, any Error>?
        let worker: Task<Void, Never>
        let deadline: Task<Void, Never>
    }

    public init(model: any DecisionModel, limits: DecisionLimits = .init(),
                diagnostics: @escaping @Sendable (DecisionDiagnostic) -> Void = { _ in }) {
        self.model = model; self.limits = limits; self.diagnostics = diagnostics
    }

    public func availability() async -> ModelAvailability { await model.availability() }

    public func decide(_ request: DecisionRequest, timeout: Duration = .seconds(8)) async throws -> DecisionResponse {
        try DecisionValidation.validate(request, limits: limits)
        guard timeout > .zero && timeout <= .seconds(120) else { throw DecisionFailure(.invalidRequest, "deadline") }
        guard !Task.isCancelled else { throw DecisionFailure(.cancelled, "caller_cancelled") }
        guard active == nil else { throw DecisionFailure(.busy, "request_in_flight") }
        let token = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = Task.detached(priority: .userInitiated) { [model, limits] in
                    let result: Result<DecisionResponse, any Error>
                    do {
                        let availability = await model.availability()
                        try Task.checkCancellation()
                        guard availability.available else {
                            throw DecisionFailure(.modelUnavailable, availability.reason)
                        }
                        let fields = DecisionValidation.fields(for: request)
                        var answers: [ModelAnswer] = []
                        if request.mode == .comparative {
                            answers = try await model.generate(ModelBatch(state: request.state, fields: fields, mode: .comparative))
                        } else {
                            for field in fields {
                                try Task.checkCancellation()
                                let generated = try await model.generate(ModelBatch(state: request.state, fields: [field], mode: .independent))
                                guard generated.count == 1, generated[0].id == field.question.id else {
                                    throw DecisionFailure(.generationFailed, "independent_answer_membership")
                                }
                                answers += generated
                            }
                        }
                        try Task.checkCancellation()
                        result = .success(try DecisionValidation.assemble(answers, for: request, modelMetadata: availability.metadata, limits: limits))
                    } catch is CancellationError {
                        result = .failure(DecisionFailure(.cancelled, "caller_cancelled"))
                    } catch let failure as DecisionFailure {
                        result = .failure(failure)
                    } catch {
                        result = .failure(DecisionFailure(.generationFailed, "model_error"))
                    }
                    await self.finished(token, result: result)
                }
                let deadline = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.endWaiting(token, failure: DecisionFailure(.timeout, "deadline_exceeded"))
                }
                active = Pending(token: token, identity: request.identity, start: .now,
                                 continuation: continuation, worker: worker, deadline: deadline)
            }
        } onCancel: {
            Task { await self.endWaiting(token, failure: DecisionFailure(.cancelled, "caller_cancelled")) }
        }
        guard !Task.isCancelled else { throw DecisionFailure(.cancelled, "caller_cancelled") }
        return response
    }

    private func endWaiting(_ token: UUID, failure: DecisionFailure) {
        guard var pending = active, pending.token == token, let continuation = pending.continuation else { return }
        pending.continuation = nil
        active = pending
        pending.worker.cancel()
        pending.deadline.cancel()
        report(pending, outcome: failure.code.rawValue)
        continuation.resume(throwing: failure)
        // Keep admission reserved until the model call actually terminates.
    }

    private func finished(_ token: UUID, result: Result<DecisionResponse, any Error>) {
        guard let pending = active, pending.token == token else { return }
        active = nil
        pending.deadline.cancel()
        guard let continuation = pending.continuation else { return }
        let outcome: String
        switch result {
        case .success: outcome = "ok"
        case .failure(let error): outcome = (error as? DecisionFailure)?.code.rawValue ?? "generation_failed"
        }
        report(pending, outcome: outcome)
        continuation.resume(with: result)
    }

    private func report(_ pending: Pending, outcome: String) {
        let elapsed = pending.start.duration(to: .now).components
        diagnostics(DecisionDiagnostic(identity: pending.identity, outcome: outcome,
                                       elapsedMilliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)))
    }
}

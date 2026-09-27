import Foundation
import DecisionCore
import DecisionFoundationModels

@main
struct Consumer {
    static func main() async throws {
        let namespace = CommandLine.arguments.first(where: { $0.hasPrefix("--namespace=") })
            .map { String($0.dropFirst("--namespace=".count)) } ?? "example.documents"
        let urgency = Rubric(id: "document-urgency", version: 1, levels: [
            .init(id: "routine", label: "Routine", description: "No urgent deadline stated."),
            .init(id: "urgent", label: "Urgent", description: "Explicit deadline within one day.")
        ])
        let documents = DecisionRequest(
            identity: .init(namespace: namespace, workflow: "document-classification", workflowVersion: 1, requestID: "doc-1"),
            state: "Invoice for office supplies; payment due tomorrow.", questions: [
                .init(id: "type", type: .choice, prompt: "Classify the document.", options: [
                    .init(id: "invoice", label: "Invoice", description: "Requests payment for goods or services."),
                    .init(id: "note", label: "Note", description: "General correspondence.")
                ]),
                .init(id: "urgency", type: .rankedScore, prompt: "Assess urgency.", rubric: urgency)
            ])
        let task = DecisionRequest(
            identity: .init(namespace: namespace, workflow: "task-actionability", workflowVersion: 1, requestID: "task-1"),
            state: "Please review the proposed meeting agenda.", questions: [
                .init(id: "actionable", type: .boolean, prompt: "Does this request an action?",
                      yesWhen: "An explicit task is requested.", noWhen: "No explicit task is present, including absent evidence.")
            ])
        let engine = DecisionEngine(model: AppleDecisionModel())
        for request in [documents, task] {
            if CommandLine.arguments.contains("--live") {
                do { print(String(decoding: try DecisionJSON.encode(await engine.decide(request, timeout: .seconds(15))), as: UTF8.self)) }
                catch let failure as DecisionFailure { print(String(decoding: try DecisionJSON.encode(failure), as: UTF8.self)) }
            } else {
                // Default emits two independent workflow fixtures; it does not start inference.
                print(String(decoding: try DecisionJSON.encode(request), as: UTF8.self))
            }
        }
    }
}

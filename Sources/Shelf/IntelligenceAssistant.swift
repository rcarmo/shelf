import Foundation
import FoundationModels
import SwiftIntelligence

final class IntelligenceAssistant {
    func summarizeSearchHits(
        mailContext: MailMessageContext,
        similarMessages: [SimilarMessage]
    ) async throws -> String {
        let session = IntelligenceSession(model: .appleIntelligence()) {
            "You are a helpful, concise assistant for a Swift app. Keep answers under 100 words."
        }

        let reply = try await session.respond(
            to: prompt(
                mailContext: mailContext,
                similarMessages: similarMessages
            ),
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120)
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prompt(
        mailContext: MailMessageContext,
        similarMessages: [SimilarMessage]
    ) -> String {
        var lines: [String] = [
            "We are looking at an e-mail message.",
            "- \(mailContext.subject) from \(mailContext.sender) in \(mailContext.currentMailbox)",
        ]

        if let senderEmail = mailContext.senderEmail {
            lines.append("Current sender email: \(senderEmail)")
        }

        lines.append("We have found a number of similar messages:")
        lines.append(contentsOf: similarMessages.prefix(10).map { message in
            let date = message.date.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none)
            } ?? "unknown date"
            return "- \(message.subject) from \(message.sender), \(date), in \(message.displayPath)"
        })
        lines.append("Provide a summary of what the similar messages seem to be about and any filing location pattern. Only the summary and the filing location pattern, no preamble, no chatter, no formatting whatsoever.")
        return lines.joined(separator: "\n")
    }
}

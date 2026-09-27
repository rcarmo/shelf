import Foundation

/// Subject-based conversation evidence, not RFC Message-ID thread membership.
struct MailSubjectMatch {
    let exact: Bool
    let sharedTerms: Int
    let similarity: Double
    let strong: Bool

    init(_ current: String, _ candidate: String) {
        let lhs = Self.normalized(current)
        let rhs = Self.normalized(candidate)
        let left = Set(Self.terms(lhs))
        let right = Set(Self.terms(rhs))
        sharedTerms = left.intersection(right).count
        let union = left.union(right).count
        similarity = union == 0 ? 0 : Double(sharedTerms) / Double(union)
        exact = !left.isEmpty && lhs == rhs
        let smaller = min(left.count, right.count)
        strong = sharedTerms >= 2 && similarity >= 0.35
            && Double(sharedTerms) / Double(max(1, smaller)) >= 0.5
    }

    var relatedBoost: Double {
        (exact ? 300 : strong ? 120 : 0) + Double(min(sharedTerms, 6)) * 18 + similarity * 80
    }

    var retrievalBoost: Int {
        (exact ? 640 : strong ? 280 : 0) + min(sharedTerms, 6) * 24 + Int(similarity * 160)
    }

    var filingBoost: Double {
        (exact ? 3.0 : strong ? 1.5 : 0) + similarity * 1.2
    }

    static func terms(_ value: String) -> [String] {
        // Common correspondence labels are not evidence of a shared topic.
        SubjectTokenizer.terms(from: normalized(value), limit: 24)
            .filter { !["follow", "followup", "update", "hello", "thanks", "regards"].contains($0) }
    }

    static func normalized(_ value: String) -> String {
        var subject = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let prefix = subject.range(of: #"^(re|fw|fwd)(\[\d+\])?\s*:\s*"#, options: .regularExpression) {
            subject.removeSubrange(prefix)
        }
        // Preserve bracketed ticket/project identifiers and short numeric tokens.
        return subject.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

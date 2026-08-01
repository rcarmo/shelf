import AppKit
import Contacts
import Foundation

enum HintKind: String, CaseIterable, Identifiable {
    case url = "URL"
    case email = "Email"
    case name = "Name"
    case file = "File"
    case contact = "Contact"
    case window = "Window"
    case unknown = "Unknown"

    var id: String { rawValue }
}

struct AppHint: Identifiable, Equatable {
    let id = UUID()
    var bundleIdentifier: String
    var applicationName: String
    var kind: HintKind
    var title: String
    var subtitle: String
    var value: String
    var url: URL?
    var email: String?
    var fileURL: URL?
    var contactIdentifier: String?
    var mailContext: MailMessageContext?
    var confidence: Double
    var createdAt = Date()

    var signature: String {
        [
            bundleIdentifier,
            kind.rawValue,
            value,
            title,
            subtitle
        ].joined(separator: "|")
    }
}

struct ContactClue: Identifiable, Equatable {
    var id: String
    var displayName: String
    var organization: String
    var emails: [String]
    var urls: [URL]
    var phoneNumbers: [String]
    var imageData: Data?

    var subtitle: String {
        if !organization.isEmpty {
            return organization
        }
        if let email = emails.first {
            return email
        }
        if let url = urls.first {
            return url.absoluteString
        }
        return "Contact"
    }

    var initials: String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(parts)
        return value.isEmpty ? "?" : value.uppercased()
    }
}

struct MailMessageContext: Equatable {
    var sender: String
    var senderEmail: String?
    var recipients: [String] = []
    var subject: String
    var sentDate: Date?
    var currentMailbox: String
    var currentAccount: String?
    var bodyPreview: String

    var searchTerms: [String] {
        var terms: [String] = []
        if let senderEmail, !senderEmail.isEmpty {
            terms.append(senderEmail)
            if let domain = senderEmail.split(separator: "@").last {
                terms.append(String(domain))
            }
        }
        for recipient in recipients.prefix(6) {
            terms.append(recipient)
            if let domain = recipient.split(separator: "@").last {
                terms.append(String(domain))
            }
        }
        terms.append(contentsOf: SubjectTokenizer.terms(from: subject))
        terms.append(contentsOf: SubjectTokenizer.terms(from: bodyPreview).prefix(18))
        return Array(NSOrderedSet(array: terms.map { $0.lowercased() })) as? [String] ?? terms
    }

    var semanticText: String {
        [
            sender,
            senderEmail ?? "",
            recipients.joined(separator: " "),
            subject,
            sentDate.map { DateFormatter.mailContextDate.string(from: $0) } ?? "",
            currentMailbox,
            currentAccount ?? "",
            bodyPreview
        ].joined(separator: "\n")
    }
}

struct RankedMessageLocation: Identifiable, Equatable {
    var id: String { displayPath }
    var mailboxPath: [String]
    var accountHint: String?
    var score: Double
    var semanticScore: Double
    var hitCount: Int
    var recentHitCount: Int = 0
    var samplePath: String

    var mailboxName: String {
        mailboxPath.last ?? displayPath
    }

    var displayPath: String {
        mailboxPath.isEmpty ? samplePath : mailboxPath.joined(separator: " / ")
    }
}

struct SimilarMessage: Identifiable, Equatable {
    var id: String { path }
    var subject: String
    var sender: String
    var date: Date?
    var mailboxPath: [String]
    var path: String
    var rank: Int

    var mailboxName: String {
        mailboxPath.last ?? "Mail"
    }

    var displayPath: String {
        mailboxPath.isEmpty ? mailboxName : mailboxPath.joined(separator: " / ")
    }
}

struct MailSuggestions: Equatable {
    var locations: [RankedMessageLocation]
    var messages: [SimilarMessage]
    var diagnostic: String
    var requiresFullDiskAccess: Bool

    static let empty = MailSuggestions(locations: [], messages: [], diagnostic: "", requiresFullDiskAccess: false)
}

struct MailSuggestionUpdate: Equatable {
    var suggestions: MailSuggestions
    var isFinal: Bool
}

struct AutomationResult: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var isError: Bool
    var shouldAutoClear = true
}

struct AppAutomationAction: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var systemImage: String
    var run: @MainActor () async -> AutomationResult
}

enum PermissionState: String {
    case unknown = "Unknown"
    case allowed = "Allowed"
    case denied = "Denied"
    case notDetermined = "Not Determined"
}

struct URLNormalizer {
    static func normalized(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("/") {
            value.removeLast()
        }
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasPrefix("www.flickr.") {
            value = value.replacingOccurrences(of: "www.flickr.", with: "flickr.")
        }
        return value
    }
}

struct EmailAddress {
    static func first(in string: String) -> String? {
        all(in: string).first
    }

    static func all(in string: String) -> [String] {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: string) else {
                return nil
            }
            return String(string[swiftRange]).lowercased()
        }
    }
}

struct SubjectTokenizer {
    private static let stopWords: Set<String> = [
        "re", "fw", "fwd", "the", "and", "for", "with", "from", "this", "that",
        "your", "you", "our", "are", "was", "were", "will", "can", "has", "have",
        "about", "into", "onto", "over", "under"
    ]

    static func terms(from subject: String, limit: Int = 6) -> [String] {
        let filtered = subject
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return Array(filtered.prefix(limit))
    }
}

extension CNContactStore {
    static func contactsPermissionState() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return .allowed
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }
}

private extension DateFormatter {
    static let mailContextDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

import Foundation

enum SlackViewKind: String, Codable, Sendable {
    case channel = "Channel", directMessage = "Direct Message", groupMessage = "Group Message"
    case thread = "Thread", search = "Search", activity = "Activity", files = "Files"
    case canvas = "Canvas", later = "Later", huddle = "Huddle", drafts = "Drafts", workspace = "Workspace"
}

struct SlackAttachmentHint: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var url: URL
}

struct SlackMessageHint: Codable, Equatable, Sendable, Identifiable {
    var id: String { conversationID + ":" + timestamp }
    var conversationID: String
    var timestamp: String
    var permalink: URL
    var author: String?
    var text: String
    var timeLabel: String
    var links: [URL] = []
    var attachments: [SlackAttachmentHint] = []
    var isInThread = false
}

struct SlackContext: Codable, Equatable, Sendable {
    var workspaceID: String?
    var workspaceName: String?
    var conversationID: String?
    var conversationName: String?
    var participantNames: [String] = []
    var conversationURL: URL?
    var view: SlackViewKind = .workspace
    var threadTimestamp: String?
    var topic: String?
    var searchQuery: String?
    var selectedText: String?
    var targetMessageID: String?
    var messages: [SlackMessageHint] = []
    var links: [URL] = []
    var attachments: [SlackAttachmentHint] = []
    var isPartial = false
    var needsAccessibility = false
    var diagnostic = ""

    var targetMessage: SlackMessageHint? { messages.first { $0.id == targetMessageID } }
    var signature: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    func appHint(windowTitle: String = "Slack") -> AppHint {
        AppHint(bundleIdentifier: SlackContextExtractor.bundleIdentifier, applicationName: "Slack", kind: .conversation,
                title: conversationName ?? workspaceName ?? windowTitle,
                subtitle: [workspaceName, view.rawValue].compactMap { $0 }.joined(separator: " / "),
                value: targetMessage?.permalink.absoluteString ?? conversationURL?.absoluteString ?? "",
                url: conversationURL, email: nil, fileURL: nil, contactIdentifier: nil, mailContext: nil,
                confidence: conversationID == nil ? 0.35 : 0.85, slackContext: self)
    }
}

/// Parses identities only from Slack-owned hosts. Message timestamps stay strings, not floating-point numbers.
struct SlackURLIdentity: Equatable {
    var workspaceID: String?
    var conversationID: String?
    var messageTimestamp: String?
    var threadTimestamp: String?
    var fileID: String?

    static func webURL(_ value: String) -> URL? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualified = raw.contains("://") ? raw : "https://" + raw
        guard let parts = URLComponents(string: qualified),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, host.contains("."), parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    static func parse(_ url: URL) -> SlackURLIdentity? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com"),
              parts.user == nil, parts.password == nil else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        var identity = SlackURLIdentity()
        if host == "app.slack.com", path.first == "client", path.count >= 2 {
            identity.workspaceID = validID(path[1], prefixes: ["T", "E"])
            if path.count >= 3 { identity.conversationID = validID(path[2], prefixes: ["C", "D", "G"]) }
        } else if path.first == "archives", path.count >= 2 {
            identity.conversationID = validID(path[1], prefixes: ["C", "D", "G"])
            if path.count >= 3, path[2].hasPrefix("p") {
                let digits = String(path[2].dropFirst())
                if digits.count == 16, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    identity.messageTimestamp = String(digits.prefix(10)) + "." + String(digits.suffix(6))
                }
            }
        } else if host == "files.slack.com", path.first == "files-pri", path.count >= 2 {
            let ids = path[1].split(separator: "-").map(String.init)
            if ids.count == 2 {
                identity.workspaceID = validID(ids[0], prefixes: ["T"])
                identity.fileID = validID(ids[1], prefixes: ["F"])
            }
        }
        if let thread = parts.queryItems?.first(where: { $0.name == "thread_ts" })?.value,
           thread.range(of: #"^[0-9]{10}\.[0-9]{6}$"#, options: .regularExpression) != nil {
            identity.threadTimestamp = thread
        }
        return identity
    }

    private static func validID(_ value: String, prefixes: Set<Character>) -> String? {
        guard value.count >= 3, value.count <= 32, let first = value.first, prefixes.contains(first),
              value.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return value
    }
}

/// Immutable, bounded Accessibility data. Editable values are excluded by the reader, not just the parser.
struct SlackAXNode: Equatable, Sendable {
    var id: Int
    var parent: Int?
    var role: String
    var title = ""
    var label = ""
    var value = ""
    var identifier = ""
    var url: String?
    var focused = false
    var selected = false
    var selectedText: String?

    var name: String { label.isEmpty ? title : label }
    var isPrivateInput: Bool {
        ["AXTextArea", "AXTextField", "AXComboBox", "AXSecureTextField"].contains(role)
            || (name + " " + identifier).lowercased().contains("composer")
    }
}

struct SlackAXSnapshot: Sendable {
    var windowTitle: String
    var nodes: [SlackAXNode]
    var truncated = false
    var unavailable = false
}

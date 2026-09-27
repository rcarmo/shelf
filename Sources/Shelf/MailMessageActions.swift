import Foundation

enum MailDraftKind: String, CaseIterable, Sendable {
    case reply, replyAll, forward

    var title: String {
        switch self {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }

    var symbol: String {
        switch self {
        case .reply: return "arrowshape.turn.up.left"
        case .replyAll: return "arrowshape.turn.up.left.2"
        case .forward: return "arrowshape.turn.up.right"
        }
    }

    func script(selection: [MailMessageIdentity]) -> String? {
        guard selection.count == 1, let identity = selection.first,
              identity.libraryID > 0, !identity.accountID.isEmpty else { return nil }
        let command: String
        switch self {
        case .reply: command = "reply selectedMessage with opening window without reply to all"
        case .replyAll: command = "reply selectedMessage with opening window and reply to all"
        case .forward: command = "forward selectedMessage with opening window"
        }
        // Validate inside the same Apple Event script that creates the draft. Never send it.
        return """
        with timeout of 5 seconds
            tell application id "com.apple.mail"
                set selectedMessages to selection
                if (count of selectedMessages) is not 1 then error "Mail selection changed. Refresh before creating a draft."
                set selectedMessage to item 1 of selectedMessages
                if (id of selectedMessage) is not \(identity.libraryID) then error "Mail selection changed. Refresh before creating a draft."
                set selectedAccount to "local"
                try
                    set messageAccount to account of mailbox of selectedMessage
                    if messageAccount is not missing value then set selectedAccount to id of messageAccount as text
                on error
                    error "Cannot verify the selected Mail account."
                end try
                if selectedAccount is not \(AppleScriptRunner.quoted(identity.accountID)) then error "Mail account changed. Refresh before creating a draft."
                \(command)
                activate
            end tell
        end timeout
        return "Draft opened in Mail; nothing sent."
        """
    }
}

struct MailMessageActionHint {
    enum Operation {
        case draft(MailDraftKind, [MailMessageIdentity])
        case copy(String)
        case open(URL)
    }
    let title: String
    let detail: String
    let symbol: String
    let operation: Operation
}

enum MailMessageActions {
    static func hints(for context: MailMessageContext) -> [MailMessageActionHint] {
        var hints: [MailMessageActionHint] = []
        if context.selection.count == 1, context.selection[0].libraryID > 0, !context.selection[0].accountID.isEmpty {
            hints += MailDraftKind.allCases.map {
                .init(title: $0.title, detail: "Open a draft in Mail. Nothing is sent.", symbol: $0.symbol,
                      operation: .draft($0, context.selection))
            }
        }
        if let email = EmailAddress.first(in: context.senderEmail ?? context.sender) {
            hints.append(.init(title: "Copy Sender Address", detail: email, symbol: "person.crop.circle",
                               operation: .copy(email)))
        }
        hints.append(.init(title: "Copy Message Details", detail: "Subject, sender, recipients, and mailbox.", symbol: "doc.on.doc",
                           operation: .copy([context.subject, context.sender, context.recipients.joined(separator: ", "),
                                             context.currentMailbox].filter { !$0.isEmpty }.joined(separator: "\n"))))
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let text = String(context.bodyPreview.prefix(4_000))
            var seen = Set<URL>()
            let urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
                .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
                    && $0.user == nil && $0.password == nil && seen.insert($0).inserted }
            hints += urls.prefix(3).map {
                .init(title: "Open \($0.host ?? "Link")", detail: $0.absoluteString, symbol: "link", operation: .open($0))
            }
        }
        return hints
    }
}

actor MailDraftService {
    func open(_ kind: MailDraftKind, selection: [MailMessageIdentity]) -> ScriptResult {
        guard !Task.isCancelled, let script = kind.script(selection: selection) else {
            return .init(output: "", error: "Select one message and refresh before creating a draft.")
        }
        return AppleScriptRunner().run(script)
    }
}

import Foundation

struct SlackActionHint: Equatable {
    enum Operation: Equatable { case open(URL), copy(String) }
    var title: String
    var detail: String
    var symbol: String
    var operation: Operation
}

enum SlackActions {
    static func hints(for context: SlackContext) -> [SlackActionHint] {
        var actions: [SlackActionHint] = []
        if let url = context.conversationURL, SlackURLIdentity.parse(url) != nil {
            actions.append(.init(title: "Open Conversation", detail: context.conversationName ?? "Slack",
                                 symbol: "bubble.left.and.bubble.right", operation: .open(url)))
        }
        if let message = context.targetMessage, SlackURLIdentity.parse(message.permalink)?.messageTimestamp != nil {
            actions.append(.init(title: "Open Focused Message", detail: message.author ?? message.timeLabel,
                                 symbol: "arrow.up.right.square", operation: .open(message.permalink)))
            actions.append(.init(title: "Copy Message Link", detail: message.permalink.absoluteString,
                                 symbol: "link", operation: .copy(message.permalink.absoluteString)))
        }
        let summary = [context.workspaceName, context.conversationName, context.conversationURL?.absoluteString,
                       context.targetMessage?.permalink.absoluteString].compactMap { $0 }.joined(separator: "\n")
        if !summary.isEmpty {
            actions.append(.init(title: "Copy Slack Context", detail: "Workspace, conversation and target links",
                                 symbol: "doc.on.doc", operation: .copy(summary)))
        }
        for url in (context.targetMessage?.links ?? context.links).prefix(3) {
            guard SlackURLIdentity.webURL(url.absoluteString) != nil else { continue }
            actions.append(.init(title: "Open \(url.host ?? "Link")", detail: url.absoluteString,
                                 symbol: "safari", operation: .open(url)))
        }
        return actions
    }
}

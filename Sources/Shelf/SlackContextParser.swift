import Foundation

enum SlackContextParser {
    static func parse(_ snapshot: SlackAXSnapshot) -> SlackContext {
        let all = Array(snapshot.nodes.prefix(600))
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func ancestors(_ node: SlackAXNode) -> [SlackAXNode] {
            var result: [SlackAXNode] = []
            var parent = node.parent
            var seen: Set<Int> = [node.id]
            while let id = parent, let item = byID[id], seen.insert(id).inserted, result.count < 32 {
                result.append(item)
                parent = item.parent
            }
            return result
        }
        let nodes = all.filter { node in
            !([node] + ancestors(node)).contains { $0.isPrivateInput || $0.role == "AXOutline" }
        }
        let ancestry = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set(ancestors($0).map(\.id))) })
        func descendants(of root: SlackAXNode) -> [SlackAXNode] {
            nodes.filter { $0.id == root.id || ancestry[$0.id, default: []].contains(root.id) }
        }
        func url(_ node: SlackAXNode) -> URL? {
            if let value = node.url { return SlackURLIdentity.webURL(value) }
            return node.role == "AXLink" ? SlackURLIdentity.webURL(node.value) : nil
        }
        var context = SlackContext()
        context.isPartial = snapshot.truncated || snapshot.nodes.count > 600 || snapshot.unavailable
        parseTitle(snapshot.windowTitle, into: &context)
        if context.view == .drafts {
            context.isPartial = true
            context.diagnostic = "Draft content is excluded"
            return context
        }

        // Only the document URL supplies active conversation identity. Sidebar/message links do not.
        if let documentURL = nodes.filter({ ["AXWebArea", "AXWindow"].contains($0.role) })
            .compactMap(url).first(where: { SlackURLIdentity.parse($0)?.workspaceID != nil }),
           let identity = SlackURLIdentity.parse(documentURL) {
            context.workspaceID = identity.workspaceID
            context.conversationID = identity.conversationID
            context.threadTimestamp = identity.threadTimestamp
            context.conversationURL = documentURL
            if documentURL.pathComponents.contains("search") { context.view = .search }
        }
        if context.conversationID?.hasPrefix("D") == true, context.view != .groupMessage { context.view = .directMessage }
        if context.view == .directMessage || context.view == .groupMessage, let name = context.conversationName {
            context.participantNames = name.split(separator: ",").prefix(12).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if nodes.contains(where: isThreadRegion) || context.threadTimestamp != nil { context.view = .thread }
        if context.view == .search {
            context.searchQuery = nodes.first { $0.role == "AXSearchField" && !$0.value.isEmpty }
                .map { String($0.value.prefix(512)) }
        }
        context.selectedText = nodes.first { $0.focused && $0.selectedText?.isEmpty == false }
            .flatMap(\.selectedText).map { String($0.prefix(1_500)) }
        context.topic = nodes.first { $0.name.hasPrefix("Channel topic:") || $0.name.hasPrefix("Topic:") }
            .map { String($0.name.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces).prefixString(512) }

        let timestampLinks = nodes.compactMap { node -> (SlackAXNode, URL, SlackURLIdentity)? in
            guard node.role == "AXLink", let link = url(node), let identity = SlackURLIdentity.parse(link),
                  identity.conversationID != nil, identity.messageTimestamp != nil,
                  node.name.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
            return (node, link, identity)
        }
        let timestampIDs = Set(timestampLinks.map { $0.0.id })
        var targetIDs = Set<String>()
        var messageIndices: [String: Int] = [:]
        for (anchor, permalink, identity) in timestampLinks.prefix(40) {
            var owner = anchor
            for parent in ancestors(anchor).prefix(5) {
                guard !["AXWebArea", "AXWindow", "AXList", "AXOutline"].contains(parent.role), !isThreadRegion(parent) else { break }
                let children = descendants(of: parent)
                guard children.filter({ timestampIDs.contains($0.id) }).count == 1 else { break }
                owner = parent
                if children.contains(where: { $0.role == "AXStaticText" && !$0.value.isEmpty }) { break }
            }
            let children = descendants(of: owner)
            let text = unique(children.filter { $0.role == "AXStaticText" }.map {
                String(($0.value.isEmpty ? $0.name : $0.value).prefix(2_000))
            }.filter { !$0.isEmpty }).joined(separator: "\n").prefixString(4_000)
            let preceding = children.prefix { $0.id != anchor.id }
            let author = preceding.first { node in
                node.role == "AXButton" && !node.name.isEmpty && !isMessageControl(node.name)
            }?.name.prefixString(160)
            let references = children.compactMap(url)
            let thread = ([owner] + ancestors(owner)).contains(where: isThreadRegion)
            let message = SlackMessageHint(conversationID: identity.conversationID!, timestamp: identity.messageTimestamp!,
                                           permalink: permalink, author: author, text: text, timeLabel: anchor.name.prefixString(160),
                                           links: externalLinks(references), attachments: attachments(references), isInThread: thread)
            if children.contains(where: { $0.focused || ($0.selected && ["AXRow", "AXGroup"].contains($0.role)) }) {
                targetIDs.insert(message.id)
            }
            if let index = messageIndices[message.id] {
                if context.messages[index].text.count < message.text.count { context.messages[index] = message }
                context.messages[index].isInThread = context.messages[index].isInThread || thread
            } else if context.messages.count < 30 {
                messageIndices[message.id] = context.messages.count
                context.messages.append(message)
            } else {
                context.isPartial = true
            }
        }
        if targetIDs.count == 1, let target = targetIDs.first, messageIndices[target] != nil {
            context.targetMessageID = target
        }
        if timestampLinks.count > 40 { context.isPartial = true }
        let references = nodes.filter { $0.role == "AXLink" }.compactMap(url)
        context.links = externalLinks(references)
        context.attachments = attachments(references)
        if snapshot.unavailable {
            context.diagnostic = "Slack content is unavailable."
        } else if context.isPartial {
            context.diagnostic = "Partial Slack context"
        } else if context.targetMessage != nil {
            context.diagnostic = "Focused message"
        } else {
            context.diagnostic = "Conversation context; no explicit message target"
        }
        return context
    }

    private static func isThreadRegion(_ node: SlackAXNode) -> Bool {
        let name = node.name.lowercased()
        return !["AXButton", "AXLink", "AXStaticText"].contains(node.role)
            && (name == "thread" || name.hasPrefix("thread in ") || node.identifier.contains("thread_view"))
    }

    private static func isMessageControl(_ label: String) -> Bool {
        let value = label.lowercased()
        return ["toggle", "more", "delete", "download", "reply", "replies", "add ", "save ", "remove ", "share ", "open ", "view ", "show ", "react", "edit "]
            .contains { value.hasPrefix($0) }
            || value.range(of: #"^\d+ (replies|reply|reaction)"#, options: .regularExpression) != nil
    }

    private static func parseTitle(_ title: String, into context: inout SlackContext) {
        var parts = title.components(separatedBy: " - ")
        if parts.last == "Slack" { parts.removeLast() }
        guard !parts.isEmpty else { return }
        if parts.count >= 2 { context.workspaceName = parts.removeLast().prefixString(160) }
        var name = parts.joined(separator: " - ")
        let views: [(String, SlackViewKind)] = [("Channel", .channel), ("DM", .directMessage), ("Direct Message", .directMessage),
                                                ("Group DM", .groupMessage), ("Thread", .thread), ("Search", .search)]
        for (label, kind) in views where name.hasSuffix(" (\(label))") {
            name = String(name.dropLast(label.count + 3))
            context.view = kind
            break
        }
        if context.view == .directMessage, name.contains(",") { context.view = .groupMessage }
        if context.view == .workspace {
            let known: [String: SlackViewKind] = ["threads": .thread, "activity": .activity, "files": .files,
                                                "later": .later, "canvas": .canvas, "huddles": .huddle, "search": .search,
                                                "drafts": .drafts, "drafts & sent": .drafts, "drafts and sent": .drafts]
            context.view = known[name.lowercased()] ?? (name.lowercased().hasPrefix("search:") ? .search : .workspace)
        }
        if context.view == .workspace, context.workspaceName == nil { context.workspaceName = name.prefixString(160) }
        else { context.conversationName = name.prefixString(160) }
    }

    private static func externalLinks(_ urls: [URL]) -> [URL] {
        Array(unique(urls.filter { SlackURLIdentity.parse($0) == nil }).prefix(20))
    }

    private static func attachments(_ urls: [URL]) -> [SlackAttachmentHint] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let id = SlackURLIdentity.parse(url)?.fileID, seen.insert(id).inserted else { return nil }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.query = nil
            parts?.fragment = nil
            guard let canonical = parts?.url else { return nil }
            return SlackAttachmentHint(id: id, name: url.lastPathComponent.prefixString(160), url: canonical)
        }.prefix(20).map { $0 }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension String {
    func prefixString(_ count: Int) -> String { String(prefix(count)) }
}

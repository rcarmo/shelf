import SwiftUI

struct SlackContextView: View {
    var context: SlackContext
    var baseFontSize: Double
    var requestAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if context.needsAccessibility {
                Label("Accessibility access required", systemImage: "lock")
                Button(action: requestAccess) { Label("Allow Accessibility", systemImage: "figure.stand") }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Label(context.targetMessage == nil ? "Conversation" : "Focused Message", systemImage: "bubble.left.and.bubble.right")
                    Spacer(minLength: 4)
                    if context.isPartial {
                        Image(systemName: "exclamationmark.triangle").help(context.diagnostic)
                    }
                }
                .foregroundStyle(.secondary)
                if !context.participantNames.isEmpty {
                    Label(context.participantNames.joined(separator: ", "), systemImage: "person.2")
                        .textSelection(.enabled)
                }
                if let topic = context.topic { Text(topic).textSelection(.enabled) }
                if let query = context.searchQuery { Label(query, systemImage: "magnifyingglass").textSelection(.enabled) }
                if let text = context.selectedText {
                    DisclosureGroup("Selected Text") { Text(text).textSelection(.enabled) }
                }
                if context.messages.isEmpty {
                    Text(context.diagnostic).foregroundStyle(.secondary)
                } else {
                    Text("Observed Messages").fontWeight(.semibold)
                    ForEach(context.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 6) {
                                if message.id == context.targetMessageID {
                                    Image(systemName: "scope").help("Focused message")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if let author = message.author { Text(author).fontWeight(.semibold) }
                                    Text(message.timeLabel).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Link(destination: message.permalink) { Image(systemName: "arrow.up.right.square") }
                                    .help("Open message in Slack")
                            }
                            if message.isInThread { Label("Thread", systemImage: "text.bubble").foregroundStyle(.secondary) }
                            if !message.text.isEmpty {
                                DisclosureGroup {
                                    Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                } label: {
                                    Text(message.text).lineLimit(2)
                                }
                            }
                            ForEach(message.attachments) { attachment in
                                Link(destination: attachment.url) { Label(attachment.name, systemImage: "paperclip") }
                                    .help("Open attachment in Slack")
                            }
                        }
                        Divider()
                    }
                }
                if !context.links.isEmpty {
                    DisclosureGroup("Links (\(context.links.count))") {
                        ForEach(context.links, id: \.absoluteString) { url in
                            Link(url.absoluteString, destination: url).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !context.attachments.isEmpty {
                    DisclosureGroup("Attachments (\(context.attachments.count))") {
                        ForEach(context.attachments) { attachment in
                            Link(destination: attachment.url) { Label(attachment.name, systemImage: "paperclip") }
                        }
                    }
                }
            }
        }
        .font(.system(size: ShelfSettings.clampedContentBaseFontSize(baseFontSize - 1)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

private struct ContentBaseFontSizeKey: EnvironmentKey {
    static let defaultValue = ShelfSettings.defaultContentBaseFontSize
}

private extension EnvironmentValues {
    var contentBaseFontSize: Double {
        get { self[ContentBaseFontSizeKey.self] }
        set { self[ContentBaseFontSizeKey.self] = newValue }
    }
}

private struct ContentFontScale {
    var baseSize: Double

    private func size(_ offset: Double = 0) -> CGFloat {
        CGFloat(ShelfSettings.clampedContentBaseFontSize(baseSize + offset))
    }

    var headline: Font { .system(size: size(1), weight: .semibold) }
    var subheadline: Font { .system(size: size()) }
    var subheadlineSemibold: Font { .system(size: size(), weight: .semibold) }
    var caption: Font { .system(size: size(-1)) }
    var captionMedium: Font { .system(size: size(-1), weight: .medium) }
    var captionSemibold: Font { .system(size: size(-1), weight: .semibold) }
    var captionBold: Font { .system(size: size(-1), weight: .bold) }
    var caption2: Font { .system(size: size(-2)) }
    var caption2Medium: Font { .system(size: size(-2), weight: .medium) }
    var actionIcon: Font { .system(size: size(1), weight: .medium) }
    var chevron: Font { .system(size: max(8, CGFloat(baseSize - 3)), weight: .semibold) }
    var emptyIcon: Font { .system(size: CGFloat(ShelfSettings.clampedContentBaseFontSize(baseSize) + 22)) }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: ContextMonitor
    @AppStorage(ShelfSettings.contentBaseFontSizeKey) private var contentBaseFontSize = ShelfSettings.defaultContentBaseFontSize

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                contextPane
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                Divider()
                actionsPane
                    .frame(minWidth: 360)
            }
            Divider()
            statusBar
        }
        .environment(\.contentBaseFontSize, contentBaseFontSize)
        .background(FloatingWindowAccessor(title: windowTitle))
    }

    private var contextPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(fonts.headline)

            if let hint = monitor.currentHint {
                VStack(spacing: 4) {
                    detailRow("App", hint.applicationName, systemImage: "app", lines: 1)
                    detailRow("Hint", hint.kind.rawValue, systemImage: "scope", lines: 1)
                    detailRow("Title", hint.title, systemImage: "text.alignleft", lines: 2)
                    if !hint.subtitle.isEmpty {
                        detailRow("Detail", hint.subtitle, systemImage: "info.circle", lines: 1)
                    }
                    if !hint.value.isEmpty {
                        detailRow("Value", hint.value, systemImage: "link", lines: 1)
                    }
                }
                .frame(height: 118, alignment: .top)
                .clipped()

                if !monitor.similarMessages.isEmpty || !monitor.messageLocations.isEmpty {
                    ScrollView {
                        mailIntelligenceSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .layoutPriority(1)
                } else if let hint = monitor.currentHint, hint.bundleIdentifier == "com.apple.mail", !monitor.mailSuggestionStatus.isEmpty {
                    Text(monitor.mailSuggestionStatus)
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                EmptyStateView(
                    title: "No Context Yet",
                    systemImage: "eye",
                    message: "Switch to Safari, Chrome, Mail, Finder, or Contacts to let Shelf infer what you are working with."
                )
            }

            if monitor.similarMessages.isEmpty && monitor.messageLocations.isEmpty {
                Spacer()
            }
        }
        .padding(12)
    }

    private var actionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if monitor.isSearchingMessages {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                Text("Actions")
                    .font(fonts.headline)
                Spacer()
            }

            if let contact = monitor.selectedContact {
                ContactPreview(contact: contact, matchCount: monitor.contacts.count)
            }

            if monitor.actions.isEmpty {
                EmptyStateView(
                    title: "No Actions",
                    systemImage: "wand.and.stars",
                    message: "Automation actions appear when Shelf has a contact or a supported app context."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(monitor.actions) { action in
                            Button {
                                Task {
                                    await monitor.run(action)
                                }
                            } label: {
                                AutomationActionRow(action: action)
                            }
                            .buttonStyle(.plain)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if let result = monitor.lastResult {
                ResultView(result: result)
            }
        }
        .padding(14)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if monitor.isSearchingMessages {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
            }
            Text(statusText)
                .font(fonts.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let hint = monitor.currentHint {
                Text(hint.applicationName)
                    .font(fonts.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusText: String {
        if monitor.isSearchingMessages {
            return "Searching similar messages"
        }
        if !monitor.statusText.isEmpty {
            return monitor.statusText
        }
        if let hint = monitor.currentHint, hint.bundleIdentifier == "com.apple.mail", !monitor.mailSuggestionStatus.isEmpty {
            return monitor.mailSuggestionStatus
        }
        return monitor.statusText
    }

    private var windowTitle: String {
        guard let hint = monitor.currentHint else {
            return "Shelf"
        }
        return "Shelf - \(hint.applicationName)"
    }

    private func detailRow(_ label: String, _ value: String, systemImage: String, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(fonts.caption)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(label)
                .font(fonts.caption2Medium)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(fonts.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(lines)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 18, alignment: .top)
    }

    private var mailIntelligenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.isSummarizingSimilarMessages || !monitor.similarMessagesSummary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                        Text("Apple Intelligence")
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                        if monitor.isSummarizingSimilarMessages {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        }
                    }
                    if !monitor.similarMessagesSummary.isEmpty {
                        Text(monitor.similarMessagesSummary)
                            .font(fonts.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !monitor.similarMessages.isEmpty {
                Text("Similar Messages")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                ForEach(monitor.similarMessages.prefix(10)) { message in
                    Button {
                        openSimilarMessage(message)
                    } label: {
                        SimilarMessageRow(message: message)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Mail")
                }
            }

            if !monitor.messageLocations.isEmpty {
                Text("Suggested Filing")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, monitor.similarMessages.isEmpty ? 0 : 4)
                ForEach(monitor.messageLocations.prefix(5)) { location in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.displayPath)
                                .font(fonts.captionMedium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(location.hitCount) hit\(location.hitCount == 1 ? "" : "s")")
                                .font(fonts.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSimilarMessage(_ message: SimilarMessage) {
        if let url = URL(string: message.path),
           url.scheme == "shelf-mail-message",
           let libraryID = Int(url.host ?? ""),
           MailApplicationBridge().openMessage(libraryID: libraryID) {
            return
        }

        let messageURL = URL(fileURLWithPath: message.path)
        let mailURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let configuration = NSWorkspace.OpenConfiguration()

        NSWorkspace.shared.open([messageURL], withApplicationAt: mailURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(messageURL)
            }
        }
    }
}

private struct AutomationActionRow: View {
    @Environment(\.contentBaseFontSize) private var contentBaseFontSize
    var action: AppAutomationAction

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.systemImage)
                .font(fonts.actionIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(fonts.captionSemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(action.detail)
                    .font(fonts.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(fonts.chevron)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SimilarMessageRow: View {
    @Environment(\.contentBaseFontSize) private var contentBaseFontSize
    var message: SimilarMessage

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "envelope")
                .font(fonts.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject)
                    .font(fonts.captionMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(message.sender)
                    .font(fonts.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(message.mailboxName)
                    if let date = message.date {
                        Text("-")
                        Text(date, style: .date)
                    }
                }
                .font(fonts.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContactPreview: View {
    @Environment(\.contentBaseFontSize) private var contentBaseFontSize
    var contact: ContactClue
    var matchCount: Int

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                Text("Contact Preview")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                Text(contact.displayName)
                    .font(fonts.headline)
                    .lineLimit(2)
                if !contact.organization.isEmpty {
                    Text(contact.organization)
                        .font(fonts.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let email = contact.emails.first {
                    Label(email, systemImage: "envelope")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let url = contact.urls.first {
                    Label(url.absoluteString, systemImage: "link")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if matchCount > 1 {
                    Text("\(matchCount) contact matches; using the first match for actions.")
                        .font(fonts.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
            if let imageData = contact.imageData,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(contact.initials)
                    .font(fonts.captionBold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

private struct ResultView: View {
    @Environment(\.contentBaseFontSize) private var contentBaseFontSize
    var result: AutomationResult

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.title, systemImage: result.isError ? "xmark.circle" : "checkmark.circle")
                .font(fonts.subheadlineSemibold)
                .foregroundStyle(result.isError ? .red : .green)
            Text(result.message)
                .font(fonts.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(result.shouldAutoClear ? 3 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyStateView: View {
    @Environment(\.contentBaseFontSize) private var contentBaseFontSize
    var title: String
    var systemImage: String
    var message: String

    private var fonts: ContentFontScale {
        ContentFontScale(baseSize: contentBaseFontSize)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(fonts.emptyIcon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(fonts.headline)
            Text(message)
                .font(fonts.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct FloatingWindowAccessor: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        window.title = title
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}

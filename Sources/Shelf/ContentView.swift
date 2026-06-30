import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: ContextMonitor

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
        .background(FloatingWindowAccessor(title: windowTitle))
    }

    private var contextPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(.headline)

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
                    }
                    .frame(maxWidth: .infinity)
                } else if let hint = monitor.currentHint, hint.bundleIdentifier == "com.apple.mail", !monitor.mailSuggestionStatus.isEmpty {
                    Text(monitor.mailSuggestionStatus)
                        .font(.caption)
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

            Spacer()
        }
        .padding(12)
    }

    private var actionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Automation")
                    .font(.headline)
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
                    LazyVStack(spacing: 10) {
                        ForEach(monitor.actions) { action in
                            Button {
                                Task {
                                    await monitor.run(action)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: action.systemImage)
                                        .font(.system(size: 18))
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(action.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(action.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let hint = monitor.currentHint {
                Text(hint.applicationName)
                    .font(.caption)
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
                .font(.caption)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(.caption)
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
            if !monitor.similarMessages.isEmpty {
                Text("Similar Messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(monitor.similarMessages.prefix(10)) { message in
                    SimilarMessageRow(message: message)
                }
            }

            if !monitor.messageLocations.isEmpty {
                Text("Suggested Filing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, monitor.similarMessages.isEmpty ? 0 : 4)
                ForEach(monitor.messageLocations.prefix(5)) { location in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.displayPath)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(location.hitCount) hit\(location.hitCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct SimilarMessageRow: View {
    var message: SimilarMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "envelope")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(message.sender)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(message.mailboxName)
                    if let date = message.date {
                        Text("-")
                        Text(date, style: .date)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ContactPreview: View {
    var contact: ContactClue
    var matchCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                Text("Contact Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(contact.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if !contact.organization.isEmpty {
                    Text(contact.organization)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let email = contact.emails.first {
                    Label(email, systemImage: "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let url = contact.urls.first {
                    Label(url.absoluteString, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if matchCount > 1 {
                    Text("\(matchCount) contact matches; using the first match for actions.")
                        .font(.caption)
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
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

private struct ResultView: View {
    var result: AutomationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.title, systemImage: result.isError ? "xmark.circle" : "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(result.isError ? .red : .green)
            Text(result.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
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

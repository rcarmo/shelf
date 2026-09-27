import AppKit
import Foundation

@MainActor
final class AutomationRunner {
    private let appleScript = AppleScriptRunner()
    private let mailActions: any MailActionServicing
    private let mailDrafts = MailDraftService()
    private var bindingSelection: String?
    private var destinationTasks: [MailDestinationKey: Task<MailDestinationIdentity?, Never>] = [:]

    init(mailActions: any MailActionServicing = MailActionService.shared) {
        self.mailActions = mailActions
    }

    func invalidateMailBindings() {
        for task in destinationTasks.values { task.cancel() }
        destinationTasks.removeAll()
        bindingSelection = nil
    }

    func actions(
        for contact: ContactClue?,
        hint: AppHint?,
        messageLocations: [RankedMessageLocation] = [],
        mailContext: MailMessageContext? = nil
    ) -> [AppAutomationAction] {
        var actions: [AppAutomationAction] = []

        if bindingSelection != mailContext?.selectionSignature {
            invalidateMailBindings()
            bindingSelection = mailContext?.selectionSignature
        }

        if let hint, hint.bundleIdentifier == "com.apple.mail" {
            actions.append(contentsOf: messageLocations.map { moveSelectedMailAction(to: $0, mailContext: mailContext) })
            if let context = mailContext ?? hint.mailContext {
                actions.append(contentsOf: MailMessageActions.hints(for: context).map { descriptor in
                    AppAutomationAction(title: descriptor.title, detail: descriptor.detail, systemImage: descriptor.symbol) {
                        switch descriptor.operation {
                        case .draft(let kind, let selection):
                            return self.result(title: descriptor.title, scriptResult: await self.mailDrafts.open(kind, selection: selection))
                        case .copy(let text):
                            NSPasteboard.general.clearContents()
                            let copied = NSPasteboard.general.setString(text, forType: .string)
                            return AutomationResult(title: descriptor.title, message: copied ? "Copied" : "Could not copy", isError: !copied)
                        case .open(let url):
                            let opened = NSWorkspace.shared.open(url)
                            return AutomationResult(title: descriptor.title, message: opened ? "Opened" : "Could not open link", isError: !opened)
                        }
                    }
                })
            }
        }

        if let context = hint?.slackContext {
            actions.append(contentsOf: SlackActions.hints(for: context).map { descriptor in
                AppAutomationAction(title: descriptor.title, detail: descriptor.detail, systemImage: descriptor.symbol) {
                    switch descriptor.operation {
                    case .open(let url):
                        let opened = NSWorkspace.shared.open(url)
                        return AutomationResult(title: descriptor.title, message: opened ? "Opened" : "Could not open link", isError: !opened)
                    case .copy(let text):
                        NSPasteboard.general.clearContents()
                        let copied = NSPasteboard.general.setString(text, forType: .string)
                        return AutomationResult(title: descriptor.title, message: copied ? "Copied" : "Could not copy", isError: !copied)
                    }
                }
            })
        }

        if let contact {
            actions.append(openContactAction(contact))
            actions.append(copySummaryAction(contact))

            if let email = contact.emails.first {
                actions.append(composeMailAction(contact: contact, email: email))
                actions.append(messageAction(contact: contact, address: email))
            }

            if let url = contact.urls.first {
                actions.append(openURLAction(contact: contact, url: url))
                if let hint, isBrowser(bundleIdentifier: hint.bundleIdentifier) {
                    actions.append(openURLInCurrentBrowserAction(url: url, bundleIdentifier: hint.bundleIdentifier))
                }
            }
        }

        if let hint {
            if let fileURL = hint.fileURL {
                actions.append(revealFileAction(fileURL))
            }

            actions.append(activateFrontAppAction(hint))
        }

        return actions
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    var accessibilityPermissionState: PermissionState {
        AXIsProcessTrusted() ? .allowed : .notDetermined
    }

    private func openContactAction(_ contact: ContactClue) -> AppAutomationAction {
        AppAutomationAction(
            title: "Open Contact",
            detail: "Show this contact in Contacts.",
            systemImage: "person.crop.circle"
        ) {
            if let url = URL(string: "addressbook://\(contact.id)") {
                NSWorkspace.shared.open(url)
                return AutomationResult(title: "Opened Contact", message: contact.displayName, isError: false)
            }
            return AutomationResult(title: "Could Not Open Contact", message: contact.displayName, isError: true)
        }
    }

    private func copySummaryAction(_ contact: ContactClue) -> AppAutomationAction {
        AppAutomationAction(
            title: "Copy Contact Summary",
            detail: "Put the name, organization, email, and URL on the clipboard.",
            systemImage: "doc.on.doc"
        ) {
            var lines = [contact.displayName]
            if !contact.organization.isEmpty {
                lines.append(contact.organization)
            }
            lines.append(contentsOf: contact.emails)
            lines.append(contentsOf: contact.urls.map(\.absoluteString))

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            return AutomationResult(title: "Copied", message: contact.displayName, isError: false)
        }
    }

    private func composeMailAction(contact: ContactClue, email: String) -> AppAutomationAction {
        AppAutomationAction(
            title: "Compose Email",
            detail: "Create a new Mail message addressed to this contact.",
            systemImage: "envelope"
        ) {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = email
            guard let url = components.url, NSWorkspace.shared.open(url) else {
                return AutomationResult(title: "Compose Email", message: email, isError: true)
            }
            return AutomationResult(title: "Compose Email", message: email, isError: false)
        }
    }

    private func messageAction(contact: ContactClue, address: String) -> AppAutomationAction {
        AppAutomationAction(
            title: "Message",
            detail: "Open Messages for this contact.",
            systemImage: "message"
        ) {
            let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
            if let url = URL(string: "imessage://\(encoded)") {
                NSWorkspace.shared.open(url)
                return AutomationResult(title: "Opened Messages", message: contact.displayName, isError: false)
            }
            return AutomationResult(title: "Could Not Open Messages", message: address, isError: true)
        }
    }

    private func openURLAction(contact: ContactClue, url: URL) -> AppAutomationAction {
        AppAutomationAction(
            title: "Open Profile URL",
            detail: "Open the first URL stored on this contact.",
            systemImage: "safari"
        ) {
            NSWorkspace.shared.open(url)
            return AutomationResult(title: "Opened URL", message: url.absoluteString, isError: false)
        }
    }

    private func openURLInCurrentBrowserAction(url: URL, bundleIdentifier: String) -> AppAutomationAction {
        let appName = bundleIdentifier == "com.apple.Safari" ? "Safari" : "browser"
        return AppAutomationAction(
            title: "Load URL in Current \(appName)",
            detail: "Navigate the active tab to this contact URL.",
            systemImage: "arrow.turn.down.right"
        ) {
            let quotedURL = AppleScriptRunner.quoted(url.absoluteString)
            let source: String
            if bundleIdentifier == "com.apple.Safari" {
                source = """
                tell application id "com.apple.Safari"
                    if (count of windows) is 0 then make new document
                    set URL of current tab of front window to \(quotedURL)
                    activate
                end tell
                """
            } else {
                source = """
                tell application id \(AppleScriptRunner.quoted(bundleIdentifier))
                    if (count of windows) is 0 then make new window
                    set URL of active tab of front window to \(quotedURL)
                    activate
                end tell
                """
            }
            return self.result(title: "Loaded URL", scriptResult: self.appleScript.run(source))
        }
    }

    private func moveSelectedMailAction(to location: RankedMessageLocation, mailContext: MailMessageContext?) -> AppAutomationAction {
        let selection = mailContext?.selection ?? []
        let key = MailDestinationKey(location)
        let destination: Task<MailDestinationIdentity?, Never>
        if let existing = destinationTasks[key] {
            destination = existing
        } else {
            destination = Task { [mailActions] in
                guard !Task.isCancelled else { return nil }
                let identity = await mailActions.destinationIdentity(for: location)
                return Task.isCancelled ? nil : identity
            }
            destinationTasks[key] = destination
        }
        let semanticDetail = location.semanticScore > 0
            ? ", semantic \(String(format: "%.2f", location.semanticScore))"
            : ""
        return AppAutomationAction(
            title: "Move to \(location.mailboxName)",
            detail: "\(location.qualifiedDisplayPath)\n\(location.evidenceSummary)\(semanticDetail)",
            systemImage: "tray.and.arrow.down"
        ) {
            let identity = await destination.value
            let result = self.result(title: "Move to \(location.mailboxName)", bridgeResult: await self.mailActions.move(
                to: location, selection: selection, destination: identity
            ))
            if !result.isError, let mailContext {
                await MailMoveLearningStore.shared.record(context: mailContext, destination: location)
            }
            return result
        }
    }

    private func revealFileAction(_ fileURL: URL) -> AppAutomationAction {
        AppAutomationAction(
            title: "Reveal Finder Selection",
            detail: "Show the selected item in Finder.",
            systemImage: "folder"
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return AutomationResult(title: "Revealed File", message: fileURL.path, isError: false)
        }
    }

    private func activateFrontAppAction(_ hint: AppHint) -> AppAutomationAction {
        AppAutomationAction(
            title: "Return to \(hint.applicationName)",
            detail: "Bring the hinted app back to the front.",
            systemImage: "macwindow"
        ) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: hint.bundleIdentifier).first else {
                return AutomationResult(title: "Activated App", message: "App is not running.", isError: true)
            }
            let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return AutomationResult(title: "Activated App", message: activated ? "Done" : "Could not activate app.", isError: !activated)
        }
    }

    private func isBrowser(bundleIdentifier: String) -> Bool {
        [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ].contains(bundleIdentifier)
    }

    private func result(title: String, scriptResult: ScriptResult) -> AutomationResult {
        if let error = scriptResult.error {
            return AutomationResult(title: title, message: error, isError: true)
        }
        return AutomationResult(title: title, message: scriptResult.output.isEmpty ? "Done" : scriptResult.output, isError: false)
    }

    private func result(title: String, bridgeResult: MailBridgeResult) -> AutomationResult {
        if let error = bridgeResult.error {
            return AutomationResult(title: title, message: error, isError: true)
        }
        return AutomationResult(title: title, message: bridgeResult.output.isEmpty ? "Done" : bridgeResult.output, isError: false)
    }

}

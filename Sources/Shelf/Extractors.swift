import AppKit
import ApplicationServices
import Foundation

protocol ContextExtracting {
    func extract(from application: NSRunningApplication) -> AppHint?
}

final class ContextExtractorRegistry {
    private let appleScript = AppleScriptRunner()
    private let mailBridge = MailApplicationBridge()

    func extract(from application: NSRunningApplication) -> AppHint? {
        let bundleIdentifier = application.bundleIdentifier ?? ""
        let name = application.localizedName ?? bundleIdentifier

        switch bundleIdentifier {
        case "com.apple.Safari":
            return browserHint(
                appName: name,
                bundleIdentifier: bundleIdentifier,
                script: """
                tell application id "com.apple.Safari"
                    if (count of windows) is 0 then return ""
                    set theTab to current tab of front window
                    return (URL of theTab) & linefeed & (name of theTab)
                end tell
                """
            )
        case "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.brave.Browser":
            return browserHint(
                appName: name,
                bundleIdentifier: bundleIdentifier,
                script: """
                tell application id \(AppleScriptRunner.quoted(bundleIdentifier))
                    if (count of windows) is 0 then return ""
                    set theTab to active tab of front window
                    return (URL of theTab) & linefeed & (title of theTab)
                end tell
                """
            )
        case "com.apple.mail":
            return mailHint(appName: name, bundleIdentifier: bundleIdentifier)
        case "com.apple.finder":
            return finderHint(appName: name, bundleIdentifier: bundleIdentifier)
        case "com.apple.AddressBook":
            return contactsHint(appName: name, bundleIdentifier: bundleIdentifier)
        default:
            return accessibilityWindowHint(from: application)
        }
    }

    private func browserHint(appName: String, bundleIdentifier: String, script: String) -> AppHint? {
        let result = appleScript.run(script)
        guard result.succeeded, !result.output.isEmpty else {
            return nil
        }
        let lines = result.output.components(separatedBy: .newlines)
        guard let rawURL = lines.first, let url = URL(string: rawURL), !rawURL.isEmpty else {
            return nil
        }
        let title = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return AppHint(
            bundleIdentifier: bundleIdentifier,
            applicationName: appName,
            kind: .url,
            title: title.isEmpty ? rawURL : title,
            subtitle: rawURL,
            value: rawURL,
            url: url,
            email: nil,
            fileURL: nil,
            contactIdentifier: nil,
            mailContext: nil,
            confidence: 0.85
        )
    }

    private func mailHint(appName: String, bundleIdentifier: String) -> AppHint? {
        guard let snapshot = mailBridge.selectedMessage(),
              !snapshot.sender.isEmpty || !snapshot.subject.isEmpty else {
            return nil
        }
        let context = MailMessageContext(
            sender: snapshot.sender,
            senderEmail: snapshot.senderEmail,
            recipients: snapshot.recipients,
            subject: snapshot.subject,
            sentDate: snapshot.sentDate,
            currentMailbox: snapshot.mailboxName,
            currentAccount: snapshot.accountName,
            bodyPreview: snapshot.bodyPreview
        )
        guard let email = snapshot.senderEmail else {
            return AppHint(
                bundleIdentifier: bundleIdentifier,
                applicationName: appName,
                kind: .name,
                title: snapshot.sender,
                subtitle: snapshot.subject,
                value: snapshot.sender,
                url: nil,
                email: nil,
                fileURL: nil,
                contactIdentifier: nil,
                mailContext: context,
                confidence: 0.55
            )
        }
        return AppHint(
            bundleIdentifier: bundleIdentifier,
            applicationName: appName,
            kind: .email,
            title: snapshot.sender,
            subtitle: snapshot.subject,
            value: email,
            url: nil,
            email: email,
            fileURL: nil,
            contactIdentifier: nil,
            mailContext: context,
            confidence: 0.95
        )
    }

    private func finderHint(appName: String, bundleIdentifier: String) -> AppHint? {
        let result = appleScript.run("""
        tell application id "com.apple.finder"
            set selectedItems to selection
            if (count of selectedItems) is 0 then return ""
            set selectedItem to item 1 of selectedItems
            return POSIX path of (selectedItem as alias)
        end tell
        """)
        guard result.succeeded, !result.output.isEmpty else {
            return nil
        }
        let fileURL = URL(fileURLWithPath: result.output)
        return AppHint(
            bundleIdentifier: bundleIdentifier,
            applicationName: appName,
            kind: .file,
            title: fileURL.lastPathComponent,
            subtitle: fileURL.deletingLastPathComponent().path,
            value: fileURL.path,
            url: nil,
            email: nil,
            fileURL: fileURL,
            contactIdentifier: nil,
            mailContext: nil,
            confidence: 0.6
        )
    }

    private func contactsHint(appName: String, bundleIdentifier: String) -> AppHint? {
        let result = appleScript.run("""
        tell application id "com.apple.AddressBook"
            set selectedPeople to selection
            if (count of selectedPeople) is 0 then return ""
            set selectedPerson to item 1 of selectedPeople
            return (id of selectedPerson) & linefeed & (name of selectedPerson)
        end tell
        """)
        guard result.succeeded, !result.output.isEmpty else {
            return nil
        }
        let lines = result.output.components(separatedBy: .newlines)
        guard let identifier = lines.first, !identifier.isEmpty else {
            return nil
        }
        let title = lines.dropFirst().joined(separator: " ")
        return AppHint(
            bundleIdentifier: bundleIdentifier,
            applicationName: appName,
            kind: .contact,
            title: title.isEmpty ? "Selected Contact" : title,
            subtitle: identifier,
            value: identifier,
            url: nil,
            email: nil,
            fileURL: nil,
            contactIdentifier: identifier,
            mailContext: nil,
            confidence: 1
        )
    }

    private func accessibilityWindowHint(from application: NSRunningApplication) -> AppHint? {
        guard AXIsProcessTrusted(),
              let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard windowResult == .success, let focusedWindow else {
            return nil
        }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success,
              let title = titleValue as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return AppHint(
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? bundleIdentifier,
            kind: .window,
            title: title,
            subtitle: "Focused window title",
            value: title,
            url: nil,
            email: EmailAddress.first(in: title),
            fileURL: nil,
            contactIdentifier: nil,
            mailContext: nil,
            confidence: 0.35
        )
    }
}

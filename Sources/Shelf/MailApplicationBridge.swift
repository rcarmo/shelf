import Foundation
import ScriptingBridge

struct MailSelectionSnapshot {
    var sender: String
    var senderEmail: String?
    var recipients: [String]
    var subject: String
    var sentDate: Date?
    var mailboxName: String
    var accountName: String?
    var bodyPreview: String
}

struct MailBridgeResult {
    var output: String
    var error: String?

    var succeeded: Bool { error == nil }
}

struct MailLogicalMessageRecord {
    var libraryID: Int
    var subject: String
    var sender: String
    var date: Date?
    var mailboxPath: [String]
    var accountName: String?
}

actor MailLogicalMessageSearch {
    static let shared = MailLogicalMessageSearch()

    private let bridge = MailApplicationBridge()

    func messages(for context: MailMessageContext, limit: Int) -> [MailLogicalMessageRecord] {
        bridge.logicalMessages(for: context, limit: limit)
    }
}

final class MailApplicationBridge {
    private let application: SBApplication?

    init() {
        application = SBApplication(bundleIdentifier: "com.apple.mail")
    }

    func selectedMessage() -> MailSelectionSnapshot? {
        guard let message = selectedMessages().first else {
            return nil
        }

        let sender = stringValue(message, key: "sender")
        let subject = stringValue(message, key: "subject")
        let body = stringValue(message, key: "content")
        let date = dateValue(message, key: "dateReceived")
            ?? dateValue(message, key: "dateSent")
        let mailbox = objectValue(message, key: "mailbox")
        let mailboxName = mailbox.flatMap { stringValue($0, key: "name") } ?? ""
        let accountName = mailbox
            .flatMap { objectValue($0, key: "account") }
            .flatMap { stringValue($0, key: "name") }

        return MailSelectionSnapshot(
            sender: sender,
            senderEmail: EmailAddress.first(in: sender),
            recipients: recipientAddresses(from: message),
            subject: subject,
            sentDate: date,
            mailboxName: mailboxName,
            accountName: accountName?.isEmpty == false ? accountName : nil,
            bodyPreview: compactPreview(body, limit: 4_000)
        )
    }

    func moveSelectedMessages(to location: RankedMessageLocation) -> MailBridgeResult {
        let messages = selectedMessages()
        guard !messages.isEmpty else {
            return MailBridgeResult(output: "", error: "No selected message.")
        }
        guard let mailbox = findMailbox(path: location.mailboxPath, accountHint: location.accountHint) else {
            return MailBridgeResult(output: "", error: "Mailbox path not found: \(location.displayPath)")
        }

        let selector = NSSelectorFromString("moveTo:")
        var moved = 0
        for message in messages {
            guard message.responds(to: selector) else {
                return MailBridgeResult(output: "", error: "Mail message does not support moveTo:.")
            }
            _ = message.perform(selector, with: mailbox)
            moved += 1
        }

        let error = messages
            .compactMap { ($0 as? SBObject)?.lastError()?.localizedDescription }
            .first
        if let error {
            return MailBridgeResult(output: "", error: error)
        }
        return MailBridgeResult(output: "Moved \(moved) message\(moved == 1 ? "" : "s") to \(location.displayPath).", error: nil)
    }

    func openMessage(libraryID: Int) -> Bool {
        guard let message = messageObject(libraryID: libraryID) else {
            return false
        }
        let selector = NSSelectorFromString("open")
        guard message.responds(to: selector) else {
            return false
        }
        _ = message.perform(selector)
        application?.activate()
        return (message as? SBObject)?.lastError() == nil
    }

    func logicalMessages(for context: MailMessageContext, limit: Int) -> [MailLogicalMessageRecord] {
        guard limit > 0 else {
            return []
        }

        let queryTerms = Set(
            SubjectTokenizer.terms(from: context.subject, limit: 12)
                + SubjectTokenizer.terms(from: context.bodyPreview, limit: 12)
        )
        let matchingMailboxes = logicalMailboxCandidates(terms: queryTerms).prefix(3)
        var records: [MailLogicalMessageRecord] = []

        for candidate in matchingMailboxes {
            guard let messages = candidate.mailbox.value(forKey: "messages") as? SBElementArray,
                  messages.count > 0,
                  messages.count <= 5_000,
                  let subjects = messages.value(forKey: "subject") as? [String],
                  let senders = messages.value(forKey: "sender") as? [String],
                  let identifiers = messages.value(forKey: "id") as? [Any],
                  let dates = messages.value(forKey: "dateReceived") as? [Any] else {
                continue
            }

            let count = min(subjects.count, senders.count, identifiers.count, dates.count)
            for index in 0..<count {
                guard let libraryID = integerValue(identifiers[index]) else {
                    continue
                }
                records.append(MailLogicalMessageRecord(
                    libraryID: libraryID,
                    subject: subjects[index],
                    sender: senders[index],
                    date: dates[index] as? Date,
                    mailboxPath: candidate.path,
                    accountName: candidate.accountName
                ))
            }
        }

        return records
            .map { ($0, logicalMessageScore($0, context: context, terms: queryTerms)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
                }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private func selectedMessages() -> [NSObject] {
        guard let selection = application?.value(forKey: "selection") else {
            return []
        }
        if let array = selection as? [NSObject] {
            return array
        }
        if let array = selection as? NSArray {
            return array.compactMap { $0 as? NSObject }
        }
        return []
    }

    private func logicalMailboxCandidates(terms: Set<String>) -> [LogicalMailboxCandidate] {
        var candidates: [LogicalMailboxCandidate] = []
        for account in objectCollection(application, key: "accounts") {
            let accountName = stringValue(account, key: "name")
            guard let mailboxes = account.value(forKey: "mailboxes") as? SBElementArray,
                  let names = mailboxes.value(forKey: "name") as? [String],
                  let containers = mailboxes.value(forKey: "container") as? [Any] else {
                continue
            }
            let count = min(mailboxes.count, names.count, containers.count)
            for index in 0..<count {
                let name = names[index]
                let normalizedName = name.lowercased()
                let score = terms.reduce(0) { total, term in
                    let normalizedTerm = term.lowercased()
                    guard normalizedTerm.count >= 4 else {
                        return total
                    }
                    if normalizedName == normalizedTerm {
                        return total + 80
                    }
                    if normalizedName.contains(normalizedTerm) || normalizedTerm.contains(normalizedName) {
                        return total + 50
                    }
                    return total
                }
                guard score > 0 else {
                    continue
                }
                guard let mailbox = mailboxes.object(at: index) as? NSObject else {
                    continue
                }
                candidates.append(LogicalMailboxCandidate(
                    mailbox: mailbox,
                    path: logicalMailboxPath(
                        at: index,
                        names: names,
                        containers: containers,
                        accountName: accountName
                    ),
                    accountName: accountName.isEmpty ? nil : accountName,
                    score: score
                ))
            }
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.path.joined(separator: " / ") < rhs.path.joined(separator: " / ")
            }
            return lhs.score > rhs.score
        }
    }

    private func logicalMailboxPath(
        at index: Int,
        names: [String],
        containers: [Any],
        accountName: String
    ) -> [String] {
        var path = [names[index]]
        var currentIndex = index
        var seen = Set(path)

        while containers.indices.contains(currentIndex),
              let container = containers[currentIndex] as? NSObject {
            let parentName = stringValue(container, key: "name")
            guard !parentName.isEmpty,
                  parentName != accountName,
                  seen.insert(parentName).inserted else {
                break
            }
            path.insert(parentName, at: 0)
            guard let parentIndex = names.firstIndex(of: parentName) else {
                break
            }
            currentIndex = parentIndex
        }
        return path
    }

    private func logicalMessageScore(
        _ record: MailLogicalMessageRecord,
        context: MailMessageContext,
        terms: Set<String>
    ) -> Int {
        let contextSender = normalizedEmail(context.senderEmail ?? context.sender)
        let recordSender = normalizedEmail(record.sender)
        let subject = record.subject.lowercased()
        var score = contextSender.isEmpty || contextSender != recordSender ? 0 : 320

        let contextSubjectTerms = Set(SubjectTokenizer.terms(from: context.subject, limit: 12))
        let recordSubjectTerms = Set(SubjectTokenizer.terms(from: record.subject, limit: 12))
        score += contextSubjectTerms.intersection(recordSubjectTerms).count * 24
        for term in terms where term.count >= 4 && subject.contains(term.lowercased()) {
            score += 12
        }
        if let date = record.date {
            let ageInDays = max(0, Date().timeIntervalSince(date) / (24 * 60 * 60))
            score += max(0, 90 - min(90, Int(ageInDays)))
        }
        return score
    }

    private func messageObject(libraryID: Int) -> NSObject? {
        for account in objectCollection(application, key: "accounts") {
            guard let mailbox = objectCollection(account, key: "mailboxes").first,
                  let messages = mailbox.value(forKey: "messages") as? SBElementArray else {
                continue
            }
            return messages.object(withID: libraryID) as? NSObject
        }
        return nil
    }

    private func integerValue(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private func normalizedEmail(_ value: String) -> String {
        (EmailAddress.first(in: value) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func findMailbox(path: [String], accountHint: String?) -> NSObject? {
        guard !path.isEmpty else {
            return nil
        }
        let accountHint = appleScriptAccountHint(accountHint)
        for account in objectCollection(application, key: "accounts") {
            if let accountHint, !accountHint.isEmpty,
               stringValue(account, key: "name") != accountHint {
                continue
            }
            if let mailbox = findMailbox(path: path, in: objectCollection(account, key: "mailboxes")) {
                return mailbox
            }
        }
        return findMailbox(path: path, in: objectCollection(application, key: "mailboxes"))
    }

    private func findMailbox(path: [String], in mailboxes: [NSObject]) -> NSObject? {
        guard let first = path.first else {
            return nil
        }
        for mailbox in mailboxes {
            guard stringValue(mailbox, key: "name") == first else {
                continue
            }
            if path.count == 1 {
                return mailbox
            }
            return findMailbox(path: Array(path.dropFirst()), in: objectCollection(mailbox, key: "mailboxes"))
        }
        return nil
    }

    private func recipientAddresses(from message: NSObject) -> [String] {
        let recipientCollections = [
            objectCollection(message, key: "toRecipients"),
            objectCollection(message, key: "ccRecipients"),
            objectCollection(message, key: "bccRecipients")
        ]
        let addresses = recipientCollections
            .flatMap { $0 }
            .compactMap { recipient -> String? in
                let address = stringValue(recipient, key: "address")
                return address.isEmpty ? nil : address
            }
        return Array(NSOrderedSet(array: addresses.map { $0.lowercased() })) as? [String] ?? addresses
    }

    private func objectCollection(_ object: NSObject?, key: String) -> [NSObject] {
        guard let value = object?.value(forKey: key) else {
            return []
        }
        if let array = value as? [NSObject] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? NSObject }
        }
        return []
    }

    private func objectValue(_ object: NSObject, key: String) -> NSObject? {
        object.value(forKey: key) as? NSObject
    }

    private func stringValue(_ object: NSObject, key: String) -> String {
        if let value = object.value(forKey: key) as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func dateValue(_ object: NSObject, key: String) -> Date? {
        object.value(forKey: key) as? Date
    }

    private func compactPreview(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(normalized.prefix(limit))
    }

    private func appleScriptAccountHint(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        return value
    }
}

private struct LogicalMailboxCandidate {
    var mailbox: NSObject
    var path: [String]
    var accountName: String?
    var score: Int
}

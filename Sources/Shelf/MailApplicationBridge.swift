import Foundation
import ScriptingBridge

struct MailSelectionSnapshot {
    var selection: [MailMessageIdentity]
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

    func messages(for context: MailMessageContext, limit: Int) -> (records: [MailLogicalMessageRecord], diagnostic: String) {
        let records = bridge.logicalMessages(for: context, limit: limit)
        return (records, bridge.logicalDiagnostic)
    }
}

final class MailApplicationBridge {
    private let application: SBApplication?
    private var logicalCatalog: (date: Date, mailboxes: [LogicalMailboxCandidate])?
    private var logicalHeaders = MailLogicalHeaderCache()
    private(set) var logicalDiagnostic = ""

    init() {
        application = SBApplication(bundleIdentifier: "com.apple.mail")
        application?.timeout = 120 // Apple Event ticks: bound an unresponsive Mail request to two seconds.
    }

    func accountDirectory() -> MailAccountDirectory? {
        guard !Task.isCancelled,
              let accounts = application?.value(forKey: "accounts") as? SBElementArray,
              accounts.count <= 32,
              let ids = accounts.value(forKey: "id") as? [String],
              !Task.isCancelled,
              let names = accounts.value(forKey: "name") as? [String],
              ids.count == names.count, ids.count <= 32 else { return nil }
        return MailAccountDirectory(accounts: zip(ids, names).compactMap { id, name in
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return .init(id: id, name: name)
        })
    }

    func selectedMessage() -> MailSelectionSnapshot? {
        let selected = selectedMessages()
        guard let message = selected.first else {
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
            selection: selectionIdentity(selected) ?? [],
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

    func moveSelectedMessages(to location: RankedMessageLocation, expectedSelection: [MailMessageIdentity],
                              destination: MailDestinationIdentity?) -> MailBridgeResult {
        let messages = selectedMessages()
        guard !expectedSelection.isEmpty, selectionIdentity(messages) == expectedSelection else {
            return MailBridgeResult(output: "", error: "Mail selection changed. Refresh suggestions before moving.")
        }
        let binding = MailActionBinding(selection: expectedSelection, destination: destination)
        guard let resolved = resolvedDestination(location),
              binding.matches(selection: selectionIdentity(messages), destination: resolved.identity) else {
            return MailBridgeResult(output: "", error: "Destination changed or is ambiguous. Refresh suggestions before moving.")
        }
        let mailbox = resolved.mailbox

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
        let deadline = Date().addingTimeInterval(8)
        let matchingMailboxes = logicalMailboxCandidates(terms: queryTerms, context: context)
        var mailboxesByKey: [String: LogicalMailboxCandidate] = [:]
        var keys: [String] = []
        for candidate in matchingMailboxes {
            let key = ([candidate.accountName ?? ""] + candidate.path).joined(separator: "\u{1F}")
            if mailboxesByKey[key] == nil { keys.append(key) }
            mailboxesByKey[key] = candidate
        }
        logicalHeaders.retain(keys: Set(keys))
        let pool = keys.compactMap { key -> MailDestinationCandidate? in
            guard let candidate = mailboxesByKey[key] else { return nil }
            return .make(path: candidate.path, account: candidate.accountName,
                         records: logicalHeaders.records[key] ?? [], context: context)
        }
        var random = SystemRandomNumberGenerator()
        let sampled = MailDestinationCandidate.sample(pool, oldestFirst: logicalHeaders.pending(keys, now: Date()),
                                                      limit: 24, using: &random)
        var pagesRead = 0
        var failures = 0
        var errorCodes = Set<Int>()
        for key in sampled {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard let candidate = mailboxesByKey[key] else { continue }
            let page = logicalHeaders.begin(key, now: Date())
            guard let source = MailLogicalHeaderCache.script(path: candidate.path, account: candidate.accountName, page: page),
                  let script = NSAppleScript(source: source) else { continue }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil,
                  let decoded = MailLogicalHeaderCache.decode(result, path: candidate.path, account: candidate.accountName) else {
                failures += 1
                if let code = error?[NSAppleScript.errorNumber] as? Int { errorCodes.insert(code) }
                continue
            }
            logicalHeaders.store(decoded.records, total: decoded.total, key: key, now: Date())
            pagesRead += 1
        }
        logicalDiagnostic = "Mail destination pool: \(pool.filter(\.isDestination).count) folders; \(pagesRead) header pages read; \(logicalHeaders.records.count) folders cached."
        if failures > 0 { logicalDiagnostic += " \(failures) Mail page read(s) unavailable." }
        if !errorCodes.isEmpty { logicalDiagnostic += " Mail errors: \(errorCodes.sorted().map(String.init).joined(separator: ", "))." }

        let ranked = logicalHeaders.records.values.flatMap { $0 }
            .map { ($0, logicalMessageScore($0, context: context, terms: queryTerms)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
        return MailFilingRetrieval.select(ranked, limit: limit) {
            MailFilingRetrieval.folderKey(path: $0.mailboxPath, account: $0.accountName,
                                         subject: $0.subject, sender: $0.sender, context: context)
        }
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

    private func selectionIdentity(_ messages: [NSObject]) -> [MailMessageIdentity]? {
        var identities: [MailMessageIdentity] = []
        for message in messages {
            guard let rawID = message.value(forKey: "id"), let id = integerValue(rawID), id > 0 else { return nil }
            let account = objectValue(message, key: "mailbox").flatMap { objectValue($0, key: "account") }
            let accountID = account.map { stringValue($0, key: "id") } ?? "local"
            guard !accountID.isEmpty else { return nil }
            identities.append(.init(libraryID: id, accountID: accountID))
        }
        return identities.sorted { ($0.accountID, $0.libraryID) < ($1.accountID, $1.libraryID) }
    }

    func destinationIdentity(for location: RankedMessageLocation) -> MailDestinationIdentity? {
        resolvedDestination(location)?.identity
    }

    private func resolvedDestination(_ location: RankedMessageLocation) -> (identity: MailDestinationIdentity, mailbox: NSObject)? {
        let accounts = objectCollection(application, key: "accounts")
        guard !location.mailboxPath.isEmpty, location.mailboxPath.count <= 32, accounts.count <= 32 else { return nil }
        var matches: [(MailDestinationIdentity, NSObject)] = []
        for account in accounts {
            guard !Task.isCancelled else { return nil }
            let id = stringValue(account, key: "id")
            guard !id.isEmpty else { continue }
            if let hint = location.accountHint,
               !MailAccountDirectory.sameID(hint, id) && hint != stringValue(account, key: "name") { continue }
            if let mailbox = namedMailbox(path: location.mailboxPath, container: account) {
                matches.append((.init(accountID: id, path: location.mailboxPath), mailbox))
            }
        }
        if location.accountHint == nil || location.accountHint == "local",
           let mailbox = namedMailbox(path: location.mailboxPath, container: application) {
            matches.append((.init(accountID: "local", path: location.mailboxPath), mailbox))
        }
        guard matches.count == 1 else { return nil }
        return (matches[0].0, matches[0].1)
    }

    private func namedMailbox(path: [String], container: NSObject?) -> NSObject? {
        var current = container
        for name in path {
            guard !Task.isCancelled,
                  let mailboxes = current?.value(forKey: "mailboxes") as? SBElementArray,
                  let mailbox = mailboxes.object(withName: name) as? NSObject,
                  stringValue(mailbox, key: "name") == name else { return nil }
            current = mailbox
        }
        return current
    }

    private func logicalMailboxCandidates(terms: Set<String>, context: MailMessageContext) -> [LogicalMailboxCandidate] {
        if let cached = logicalCatalog, Date().timeIntervalSince(cached.date) < 60 {
            return prioritizeLogicalMailboxes(cached.mailboxes, terms: terms, context: context)
        }
        var candidates: [LogicalMailboxCandidate] = []
        let accounts = objectCollection(application, key: "accounts").prefix(32)
            .map { ($0, stringValue($0, key: "name")) }
            .sorted { ($0.1 == context.currentAccount ? 1 : 0) > ($1.1 == context.currentAccount ? 1 : 0) }
        let deadline = Date().addingTimeInterval(2)
        let containers: [(NSObject, String)] = accounts + (application.map { [($0 as NSObject, "")] } ?? [])
        for (account, accountName) in containers {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard let mailboxes = account.value(forKey: "mailboxes") as? SBElementArray,
                  let names = mailboxes.value(forKey: "name") as? [String],
                  let containers = mailboxes.value(forKey: "container") as? [Any] else {
                continue
            }
            let count = min(mailboxes.count, names.count, containers.count, 512)
            for index in 0..<count {
                let name = names[index]
                guard !Task.isCancelled, Date() < deadline else { break }
                guard !["trash", "junk", "spam", "deleted messages", "deleted items"].contains(name.lowercased()) else { continue }
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
                    score: 0
                ))
            }
        }
        logicalCatalog = (Date(), candidates)
        return prioritizeLogicalMailboxes(candidates, terms: terms, context: context)
    }

    private func prioritizeLogicalMailboxes(_ mailboxes: [LogicalMailboxCandidate], terms: Set<String>,
                                           context: MailMessageContext) -> [LogicalMailboxCandidate] {
        let candidates = mailboxes.map { mailbox in
            var mailbox = mailbox
            mailbox.score = Self.logicalMailboxPriority(path: mailbox.path, account: mailbox.accountName,
                                                        context: context, terms: terms)
            return mailbox
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.path.joined(separator: " / ") < rhs.path.joined(separator: " / ")
            }
            return lhs.score > rhs.score
        }
    }

    static func logicalMailboxPriority(path: [String], account: String?, context: MailMessageContext, terms: Set<String>) -> Int {
        let name = path.joined(separator: " ").lowercased()
        let topic = min(200, terms.filter { $0.count >= 4 && name.contains($0.lowercased()) }.count * 50)
        return topic + (account != nil && account == context.currentAccount ? 500 : 0)
            + (MailFilingRetrieval.folderKey(path: path, account: account, subject: context.subject,
                                            sender: context.sender, context: context) != nil ? 250 : 0)
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

    func logicalMessageScore(
        _ record: MailLogicalMessageRecord,
        context: MailMessageContext,
        terms: Set<String>
    ) -> Int {
        let contextSender = normalizedEmail(context.senderEmail ?? context.sender)
        let recordSender = normalizedEmail(record.sender)
        let subject = record.subject.lowercased()
        let subjectMatch = MailSubjectMatch(context.subject, record.subject)
        let sameSender = !contextSender.isEmpty && contextSender == recordSender
        guard sameSender || subjectMatch.sharedTerms > 0 else { return 0 }
        var score = (sameSender ? 140 : 0) + subjectMatch.retrievalBoost

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

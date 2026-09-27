import Foundation

struct MailDestinationCandidate {
    var key: String
    var path: [String]
    var account: String?
    var senderHits: Int
    var threadHits: Int
    var subjectHits: Int
    var topicMatch: Bool
    var sameAccount: Bool
    var isDestination: Bool

    var weight: Double {
        guard isDestination else { return 0.25 }
        // Logarithmic history prevents a bulk newsletter folder from monopolizing scans.
        return 1 + (sameAccount ? 2 : 0) + (topicMatch ? 3 : 0)
            + 6 * log2(1 + Double(senderHits))
            + 18 * log2(1 + Double(threadHits))
            + 10 * log2(1 + Double(subjectHits))
    }

    static func make(path: [String], account: String?, records: [MailLogicalMessageRecord],
                     context: MailMessageContext) -> Self {
        let sender = EmailAddress.first(in: context.senderEmail ?? context.sender)?.lowercased()
        var senderHits = 0, threadHits = 0, subjectHits = 0
        var seen = Set<Int>()
        for record in records where seen.insert(record.libraryID).inserted {
            if sender != nil && sender == EmailAddress.first(in: record.sender)?.lowercased() { senderHits += 1 }
            let match = MailSubjectMatch(context.subject, record.subject)
            if match.exact { threadHits += 1 } else if match.strong { subjectHits += 1 }
        }
        return .init(key: ([account ?? ""] + path).joined(separator: "\u{1F}"), path: path, account: account,
                     senderHits: senderHits, threadHits: threadHits, subjectHits: subjectHits,
                     topicMatch: SpotlightMessageRanker.mailboxNameMatchesTopic(path, subject: context.subject),
                     sameAccount: account != nil && account == context.currentAccount,
                     isDestination: MailFilingRetrieval.folderKey(path: path, account: account, subject: context.subject,
                                                                 sender: context.sender, context: context) != nil)
    }

    // Weighted sampling without replacement. One in four slots explores the oldest
    // pending folder, so cold destinations can acquire evidence and are never locked out.
    static func sample<R: RandomNumberGenerator>(_ pool: [Self], oldestFirst: [String], limit: Int, using rng: inout R) -> [String] {
        guard limit > 0 else { return [] }
        let pending = Set(oldestFirst)
        let weighted = pool.filter { pending.contains($0.key) }.map {
            (key: $0.key, priority: -log(Double.random(in: Double.leastNormalMagnitude..<1, using: &rng)) / $0.weight)
        }.sorted { $0.priority < $1.priority }.map(\.key)
        let available = Set(weighted)
        let oldest = oldestFirst.filter { available.contains($0) }
        var result: [String] = [], seen = Set<String>()
        var weightedIndex = 0, oldestIndex = 0
        while result.count < min(limit, available.count) {
            let explore = result.count % 4 == 0
            let source = explore ? oldest : weighted
            var index = explore ? oldestIndex : weightedIndex
            while index < source.count && seen.contains(source[index]) { index += 1 }
            guard index < source.count else { break }
            let key = source[index]
            if explore { oldestIndex = index + 1 } else { weightedIndex = index + 1 }
            seen.insert(key)
            result.append(key)
        }
        return result
    }
}

enum MailFilingRetrieval {
    // Keep the best message matches, then reserve room for evidence from other folders.
    // Input and output remain relevance-ordered; this changes admission, not similarity scores.
    static func select<T>(_ ranked: [T], limit: Int, folder: (T) -> String?) -> [T] {
        guard limit > 0 else { return [] }
        guard ranked.count > limit else { return ranked }
        let headCount = max(1, limit / 2)
        var selected = Set(0..<headCount)
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for index in ranked.indices {
            guard let key = folder(ranked[index]) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        // Several examples per folder preserve sender filing patterns, not just one hit.
        for round in 0..<8 {
            for key in order where selected.count < limit {
                guard let indices = groups[key], indices.indices.contains(round) else { continue }
                selected.insert(indices[round])
            }
        }
        for index in ranked.indices where selected.count < limit { selected.insert(index) }
        return selected.sorted().map { ranked[$0] }
    }

    static func isDestination(_ path: [String], currentMailbox: String) -> Bool {
        let normalized = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let excluded: Set<String> = ["trash", "bin", "junk", "junk email", "junk e-mail", "spam", "deleted items", "deleted messages"]
        guard let leaf = normalized.last, !leaf.isEmpty, path != ["Mail"], normalized.allSatisfy({ !excluded.contains($0) }) else { return false }
        return leaf != currentMailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && !["inbox", "draft", "drafts", "outbox", "sent", "sent mail", "sent messages", "sent items"].contains(leaf)
    }

    static func folderKey(path: [String], account: String?, subject: String?, sender: String?,
                          context: MailMessageContext) -> String? {
        guard isDestination(path, currentMailbox: context.currentMailbox) else { return nil }
        let selectedSender = EmailAddress.first(in: context.senderEmail ?? context.sender)?.lowercased()
        let sameSender = selectedSender != nil && selectedSender == EmailAddress.first(in: sender ?? "")?.lowercased()
        let match = MailSubjectMatch(context.subject, subject ?? "")
        guard sameSender || match.exact || match.strong else { return nil }
        return ([account ?? ""] + path).joined(separator: "\u{1F}")
    }

    static func candidates(_ ranked: [MessageCandidate], context: MailMessageContext, limit: Int) -> [MessageCandidate] {
        select(ranked, limit: limit) { candidate in
            guard candidate.supportsMailFiling, candidate.contributesSimilarMessage else { return nil }
            return folderKey(path: candidate.mailboxInfo.mailboxPath, account: candidate.mailboxInfo.accountHint,
                             subject: candidate.header.subject, sender: candidate.header.sender, context: context)
        }
    }
}

// Actor-owned by MailLogicalMessageSearch. Progress survives page eviction, so large
// folders and folders outside the first batch eventually get a turn without a full walk.
struct MailLogicalHeaderCache {
    struct Progress {
        var attemptedAt: Date
        var nextPage: Int
        var complete: Bool
    }
    private(set) var progress: [String: Progress] = [:]
    private(set) var records: [String: [MailLogicalMessageRecord]] = [:]
    static let pageSize = 256
    static let maximumMailboxes = 64
    static let maximumRecordsPerMailbox = 1_024

    mutating func retain(keys: Set<String>) {
        progress = progress.filter { keys.contains($0.key) }
        records = records.filter { keys.contains($0.key) }
    }

    func pending(_ keys: [String], now: Date) -> [String] {
        keys.enumerated().filter { _, key in
            guard let state = progress[key] else { return true }
            return now.timeIntervalSince(state.attemptedAt) >= (state.complete ? 60 : 2)
        }.sorted { lhs, rhs in
            let left = progress[lhs.element]?.attemptedAt ?? .distantPast
            let right = progress[rhs.element]?.attemptedAt ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    mutating func begin(_ key: String, now: Date) -> Int {
        let page = progress[key]?.nextPage ?? 0
        progress[key] = .init(attemptedAt: now, nextPage: page, complete: false)
        return page
    }

    mutating func store(_ page: [MailLogicalMessageRecord], total: Int, key: String, now: Date) {
        let pages = max(1, (total + Self.pageSize - 1) / Self.pageSize)
        let next = (progress[key]?.nextPage ?? 0) + 1
        progress[key] = .init(attemptedAt: now, nextPage: next % pages, complete: next >= pages)
        let pageIDs = Set(page.map(\.libraryID))
        let previous = (records[key] ?? []).filter { !pageIDs.contains($0.libraryID) }
        records[key] = Array((page + (total <= Self.pageSize ? [] : previous)).prefix(Self.maximumRecordsPerMailbox))
        if records.count > Self.maximumMailboxes,
           let oldest = records.keys.filter({ $0 != key }).min(by: {
               (progress[$0]?.attemptedAt ?? .distantPast) < (progress[$1]?.attemptedAt ?? .distantPast)
           }) {
            records[oldest] = nil
        }
    }

    // Alternate the beginning and end of Mail's ordering; neither ordering direction
    // nor a small mailbox is assumed. Each pass transfers at most 256 headers.
    static func script(path: [String], account: String?, page: Int) -> String? {
        guard !path.isEmpty, path.count <= 32, page >= 0 else { return nil }
        let root = account.map { "account \(AppleScriptRunner.quoted($0))" } ?? "application id \"com.apple.mail\""
        let mailbox = path.reversed().map { "mailbox \(AppleScriptRunner.quoted($0)) of " }.joined() + root
        return """
        with timeout of 2 seconds
            tell application id "com.apple.mail"
                set targetMailbox to \(mailbox)
                set total to count of messages of targetMailbox
                if total is 0 then return {0, {}, {}, {}, {}}
                set pageCount to (total + \(pageSize - 1)) div \(pageSize)
                set pageNumber to \(page) mod pageCount
                if pageNumber mod 2 is 0 then
                    set pageIndex to pageNumber div 2
                else
                    set pageIndex to pageCount - 1 - (pageNumber div 2)
                end if
                set firstIndex to pageIndex * \(pageSize) + 1
                set lastIndex to firstIndex + \(pageSize - 1)
                if lastIndex > total then set lastIndex to total
                set pageIDs to id of messages firstIndex thru lastIndex of targetMailbox
                set pageSubjects to subject of messages firstIndex thru lastIndex of targetMailbox
                set pageSenders to sender of messages firstIndex thru lastIndex of targetMailbox
                set pageDates to date received of messages firstIndex thru lastIndex of targetMailbox
                return {total, pageIDs, pageSubjects, pageSenders, pageDates}
            end tell
        end timeout
        """
    }

    static func decode(_ result: NSAppleEventDescriptor, path: [String], account: String?)
        -> (total: Int, records: [MailLogicalMessageRecord])? {
        guard result.numberOfItems == 5, let count = result.atIndex(1),
              let ids = result.atIndex(2), let subjects = result.atIndex(3),
              let senders = result.atIndex(4), let dates = result.atIndex(5),
              ids.numberOfItems <= pageSize, ids.numberOfItems == subjects.numberOfItems,
              ids.numberOfItems == senders.numberOfItems, ids.numberOfItems == dates.numberOfItems else { return nil }
        var records: [MailLogicalMessageRecord] = []
        for index in 0..<ids.numberOfItems {
            guard let id = ids.atIndex(index + 1)?.int32Value, id > 0,
                  let subject = subjects.atIndex(index + 1)?.stringValue,
                  let sender = senders.atIndex(index + 1)?.stringValue else { continue }
            records.append(.init(libraryID: Int(id), subject: subject, sender: sender,
                                 date: dates.atIndex(index + 1)?.dateValue, mailboxPath: path, accountName: account))
        }
        return (max(0, Int(count.int32Value)), records)
    }
}

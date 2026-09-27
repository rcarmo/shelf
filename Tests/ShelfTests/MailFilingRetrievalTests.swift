import XCTest
@testable import Shelf

final class MailFilingRetrievalTests: XCTestCase {
    private let context = MailMessageContext(sender: "Alice <alice@example.org>", senderEmail: "alice@example.org",
                                             subject: "Atlas deployment review", currentMailbox: "Inbox", currentAccount: "Work",
                                             bodyPreview: "")

    private func candidate(_ id: Int, folder: String, subject: String = "Other newsletter", account: String = "Work") -> MessageCandidate {
        .init(path: "fixture\(id)", rank: id + 1, supportsMailFiling: true, contributesSimilarMessage: true,
              mailboxInfo: .init(mailboxPath: [folder], accountHint: account),
              header: .init(subject: subject, sender: context.sender, date: Date(timeIntervalSince1970: Double(id) * 3_600)), bodyPreview: "")
    }

    func testInboxFloodCannotHideSenderHistoryInOtherFolders() {
        let inbox = (0..<200).map { candidate($0, folder: "Inbox", subject: context.subject) }
        let filed = (200..<224).map { candidate($0, folder: "Filed\(($0 - 200) / 8)") }
        let selected = MailFilingRetrieval.candidates(inbox + filed, context: context, limit: 40)
        XCTAssertEqual(selected.count, 40)
        XCTAssertEqual(Array(selected.prefix(20).map(\.path)), Array(inbox.prefix(20).map(\.path)))
        for folder in ["Filed0", "Filed1", "Filed2"] {
            XCTAssertGreaterThanOrEqual(selected.filter { $0.mailboxInfo.mailboxPath == [folder] }.count, 6)
        }
        let locations = SpotlightMessageRanker().groupedLocations(from: selected, currentMailbox: "Inbox", context: context)
        XCTAssertEqual(locations.count, 3)
        XCTAssertTrue(locations.allSatisfy { $0.senderHitCount >= 6 && $0.evidenceSummary.contains("from this sender") })
        XCTAssertEqual(MailFilingRetrieval.candidates(inbox, context: context, limit: 0).count, 0)
    }

    func testDuplicateSourcesDoNotInflateHistoryAndThreadsBeatBulkSenders() {
        let thread = candidate(1, folder: "Project", subject: "Re: \(context.subject)")
        var duplicate = thread
        duplicate.path = "shelf-mail-message://1"
        let bulk = (10..<90).map { candidate($0, folder: "Newsletters") }
        let locations = SpotlightMessageRanker().groupedLocations(from: bulk + [thread, duplicate], currentMailbox: "Inbox", context: context)
        XCTAssertEqual(locations.first?.mailboxName, "Project")
        XCTAssertEqual(locations.first?.hitCount, 1)
        XCTAssertEqual(locations.first?.threadHitCount, 1)
    }

    func testSameNamedDestinationsRemainAccountScoped() {
        let messages = [candidate(1, folder: "Reviews", account: "Work"), candidate(2, folder: "Reviews", account: "Personal")]
        let ranker = SpotlightMessageRanker()
        let locations = ranker.groupedLocations(from: messages, currentMailbox: "Inbox", context: context)
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(Set(locations.map(\.id)).count, 2)
        XCTAssertTrue(locations.allSatisfy { $0.hitCount == 1 })
        XCTAssertEqual(ranker.folderOrders(rankedLocations: locations, messages: ranker.similarMessages(from: messages, context: context),
                                           candidates: messages).displayed.count, 2)
    }

    func testEveryVisibleRelatedFolderEntersDestinationShortlistEvenWithoutStrongSubjectOrSender() async {
        let candidates = (0..<7).map { index -> MessageCandidate in
            var message = candidate(index, folder: "Destination\(index)", subject: "Atlas newsletter")
            message.header.sender = "someone-else@other.example"
            return message
        }
        XCTAssertFalse(MailSubjectMatch(context.subject, "Atlas newsletter").strong)
        let suggestions = await SpotlightMessageRanker().mailSuggestions(from: candidates, context: context,
                                                                        diagnostic: "", requiresFullDiskAccess: false)
        XCTAssertEqual(suggestions.messages.count, 7)
        XCTAssertEqual(suggestions.locations.count, 5)
        let considered = Set(suggestions.decisionEvidence.map { $0.location.mailboxPath })
        for message in suggestions.messages {
            XCTAssertTrue(considered.contains(message.mailboxPath), "Visible match folder missing: \(message.mailboxPath)")
        }
        XCTAssertEqual(considered.count, 7, "The display limit must not truncate the actual shortlist.")
    }

    func testVisibleMatchesDoNotCreateUnsafeOrExternalMoveTargets() async {
        let candidates = ["Drafts", "Sent", "Outbox", "Trash", "Inbox"].enumerated().map {
            candidate($0.offset, folder: $0.element, subject: context.subject)
        }
        var external = candidate(99, folder: "External", subject: context.subject)
        external.supportsMailFiling = false
        let suggestions = await SpotlightMessageRanker().mailSuggestions(from: candidates + [external], context: context,
                                                                        diagnostic: "", requiresFullDiskAccess: false)
        XCTAssertFalse(suggestions.messages.isEmpty)
        XCTAssertTrue(suggestions.locations.isEmpty)
        XCTAssertTrue(suggestions.decisionEvidence.isEmpty)
    }

    func testDestinationWeightsReflectThreadSenderTopicAndAccountWithoutSizeBias() {
        let plain = MailDestinationCandidate.make(path: ["Reference"], account: "Other", records: [], context: context)
        let work = MailDestinationCandidate.make(path: ["Reference"], account: "Work", records: [], context: context)
        let topic = MailDestinationCandidate.make(path: ["Atlas"], account: "Work", records: [], context: context)
        let senderRecord = MailLogicalMessageRecord(libraryID: 1, subject: "Unrelated", sender: context.sender,
                                                    mailboxPath: ["Reviews"], accountName: "Work")
        var threadRecord = senderRecord
        threadRecord.subject = context.subject
        let sender = MailDestinationCandidate.make(path: ["Reviews"], account: "Work", records: [senderRecord], context: context)
        let thread = MailDestinationCandidate.make(path: ["Reviews"], account: "Work", records: [threadRecord], context: context)
        XCTAssertLessThan(plain.weight, work.weight)
        XCTAssertLessThan(work.weight, topic.weight)
        XCTAssertLessThan(topic.weight, sender.weight)
        XCTAssertLessThan(sender.weight, thread.weight)
        XCTAssertEqual(thread.weight, MailDestinationCandidate.make(path: ["Reviews"], account: "Work",
                                                                     records: [threadRecord, threadRecord], context: context).weight)
    }

    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64 = 17
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testWeightedSamplingFavorsEvidenceButExploresAndNeverRepeats() {
        var pool = (0..<32).map { MailDestinationCandidate.make(path: ["Folder\($0)"], account: "Work", records: [], context: context) }
        pool[1].threadHits = 20
        let oldest = pool.map(\.key)
        var random = SeededRandom()
        var strongSelections = 0, coldSelections = 0
        for _ in 0..<500 {
            let sampled = MailDestinationCandidate.sample(pool, oldestFirst: oldest, limit: 8, using: &random)
            XCTAssertEqual(sampled.count, 8)
            XCTAssertEqual(Set(sampled).count, 8)
            XCTAssertEqual(sampled.first, oldest.first)
            if sampled.contains(pool[1].key) { strongSelections += 1 }
            if sampled.contains(pool[20].key) { coldSelections += 1 }
        }
        XCTAssertGreaterThan(strongSelections, coldSelections * 3)
        XCTAssertEqual(MailDestinationCandidate.sample(pool, oldestFirst: oldest, limit: 100, using: &random).count, 32)
        XCTAssertTrue(MailDestinationCandidate.sample(pool, oldestFirst: [], limit: 8, using: &random).isEmpty)
    }

    func testCacheProgressesPastFirst24FoldersAndDoesNotSkipLargeMailboxes() {
        var cache = MailLogicalHeaderCache()
        let now = Date(timeIntervalSince1970: 10_000)
        let keys = (0..<80).map { "folder\($0)" }
        for key in keys.prefix(24) {
            XCTAssertEqual(cache.begin(key, now: now), 0)
            cache.store([], total: 50_000, key: key, now: now)
        }
        XCTAssertEqual(cache.pending(keys, now: now), Array(keys.dropFirst(24)))
        XCTAssertEqual(cache.pending(keys, now: now.addingTimeInterval(3)).first, keys[24])
        XCTAssertEqual(cache.begin(keys[0], now: now.addingTimeInterval(3)), 1)
        cache.store([], total: 10, key: keys[0], now: now.addingTimeInterval(3))
        XCTAssertFalse(cache.pending(keys, now: now.addingTimeInterval(60)).contains(keys[0]))
        XCTAssertTrue(cache.pending(keys, now: now.addingTimeInterval(64)).contains(keys[0]))
        cache.retain(keys: [keys[0]])
        XCTAssertEqual(cache.progress.count, 1)
    }

    func testCacheHasHardMemoryBoundsAndPageDeduplication() {
        var cache = MailLogicalHeaderCache()
        let now = Date(timeIntervalSince1970: 10_000)
        for folder in 0..<70 {
            let key = "folder\(folder)"
            for page in 0..<6 {
                _ = cache.begin(key, now: now.addingTimeInterval(Double(folder)))
                let records = (0..<256).map {
                    MailLogicalMessageRecord(libraryID: page * 256 + $0 + 1, subject: "Fixture", sender: context.sender,
                                             mailboxPath: [key], accountName: "Work")
                }
                cache.store(records, total: 50_000, key: key, now: now.addingTimeInterval(Double(folder)))
            }
        }
        XCTAssertEqual(cache.records.count, MailLogicalHeaderCache.maximumMailboxes)
        XCTAssertTrue(cache.records.values.allSatisfy { $0.count == MailLogicalHeaderCache.maximumRecordsPerMailbox })
        XCTAssertEqual(cache.progress["folder0"]?.nextPage, 6, "Eviction must not restart a large folder.")
    }

    func testNativePageScriptsCompileReadOnlyWithEscapedNestedFolders() throws {
        for account: String? in [nil, "Work \"Account\""] {
            let source = try XCTUnwrap(MailLogicalHeaderCache.script(path: ["Projects", "Atlas \\ Review"], account: account, page: 42))
            XCTAssertTrue(source.contains("messages firstIndex thru lastIndex"))
            XCTAssertFalse(source.contains("content of"))
            XCTAssertFalse(source.contains("move "))
            var error: NSDictionary?
            XCTAssertTrue(try XCTUnwrap(NSAppleScript(source: source)).compileAndReturnError(&error), "\(error?.description ?? "")")
        }
        XCTAssertNil(MailLogicalHeaderCache.script(path: [], account: nil, page: 0))
    }

    func testNativePageDecoderRejectsMisalignedBatches() throws {
        func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let result = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
            return result
        }
        let date = Date(timeIntervalSince1970: 100)
        let batch = list([.init(int32: 50_001), list([.init(int32: 42)]), list([.init(string: "Atlas")]),
                          list([.init(string: context.sender)]), list([.init(date: date)])])
        let decoded = try XCTUnwrap(MailLogicalHeaderCache.decode(batch, path: ["Reviews"], account: "Work"))
        XCTAssertEqual(decoded.total, 50_001)
        XCTAssertEqual(decoded.records.first?.libraryID, 42)
        XCTAssertEqual(decoded.records.first?.date, date)
        batch.remove(at: 5)
        batch.insert(list([]), at: 5)
        XCTAssertNil(MailLogicalHeaderCache.decode(batch, path: ["Reviews"], account: "Work"))
    }
}

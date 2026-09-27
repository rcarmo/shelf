import XCTest
@testable import Shelf

final class MailBaselineRankingTests: XCTestCase {
    func testTopicFolderFallbackFillsSlotsWithoutPretendingToBeFiledMessages() {
        let context = MailMessageContext(sender: "alice@example.org", subject: "Atlas deployment review", currentMailbox: "Inbox", bodyPreview: "")
        let backed = MessageCandidate(path: "filed", rank: 1, supportsMailFiling: true, contributesSimilarMessage: true,
                                      mailboxInfo: .init(mailboxPath: ["Engineering"], accountHint: "Work"),
                                      header: .init(subject: context.subject, sender: context.sender, date: nil), bodyPreview: "")
        let catalogs = ["Reviews", "Atlas", "Unrelated", "Projects"].enumerated().map { index, name in
            MessageCandidate(path: "catalog\(index)", rank: index + 2, supportsMailFiling: true, contributesSimilarMessage: false,
                             mailboxInfo: .init(mailboxPath: [name], accountHint: "Work"),
                             header: .init(subject: name, sender: nil, date: nil), bodyPreview: "")
        }
        let ranker = SpotlightMessageRanker()
        let folders = ranker.groupedLocations(from: [backed] + catalogs, currentMailbox: "Inbox", context: context)
        XCTAssertEqual(folders.first?.mailboxName, "Engineering")
        XCTAssertEqual(Set(folders.dropFirst().map(\.mailboxName)), ["Reviews", "Atlas"])
        XCTAssertTrue(folders.dropFirst().allSatisfy { $0.hitCount == 0 && $0.evidenceSummary.contains("Folder name") })
        let weakMessage = SimilarMessage(subject: "Review", sender: "someone@example.net", date: nil,
                                         mailboxPath: ["Reviews"], path: "weak", rank: 1)
        XCTAssertEqual(ranker.folderOrders(rankedLocations: folders, messages: [weakMessage], candidates: []).displayed.first?.mailboxName,
                       "Engineering")
        let fallbackOnly = ranker.groupedLocations(from: catalogs, currentMailbox: "Inbox", context: context)
        XCTAssertEqual(Set(fallbackOnly.map(\.mailboxName)), ["Reviews", "Atlas"])
        XCTAssertFalse(SpotlightMessageRanker.mailboxNameMatchesTopic(["Projects", "Unrelated"], subject: "Projects Atlas"))
        XCTAssertFalse(SpotlightMessageRanker.mailboxNameMatchesTopic(["Art"], subject: "Quarterly report"))
    }

    func testSingleMatchingMessagePromotesItsFolderBeforeTopFiveCut() {
        let ranker = SpotlightMessageRanker()
        let folders = (0..<10).map { index in
            RankedMessageLocation(mailboxPath: ["Folder\(index)"], accountHint: "Work", score: Double(100 - index),
                                  semanticScore: 0.5, hitCount: 1, samplePath: "fixture\(index)")
        }
        // A single high-relevance match must beat folders with only aggregate scores.
        let messages = [7, 9, 9].enumerated().map { index, folder in
            SimilarMessage(subject: "Related", sender: "example@example.org", date: Date(timeIntervalSince1970: Double(100 - folder)),
                           mailboxPath: ["Folder\(folder)"], path: "message\(index)", rank: index + 1)
        }
        let sorted = ranker.rankedLocations(folders, preferHitCount: true)
        let orders = ranker.folderOrders(rankedLocations: sorted, messages: messages, candidates: [])
        let full = orders.shortlist
        XCTAssertEqual(full.count, 10)
        XCTAssertEqual(Array(full.prefix(5)), orders.displayed)
        XCTAssertEqual(full.prefix(5).map(\.displayPath), ["Folder7", "Folder9", "Folder0", "Folder1", "Folder2"])
        XCTAssertEqual(full.first?.score, folders[7].score)
        XCTAssertEqual(full.first?.samplePath, folders[7].samplePath)
    }

    func testVisibleWeakMatchesKeepDestinationsBelowStrongEvidenceAndExcludeTransientMailboxes() {
        let context = MailMessageContext(sender: "alice@example.com", senderEmail: "alice@example.com",
                                         subject: "Follow-up Atlas Helios appliance", currentMailbox: "Inbox", bodyPreview: "Standard footer")
        func candidate(_ path: String, folder: String, subject: String, sender: String) -> MessageCandidate {
            .init(path: path, rank: 1, supportsMailFiling: true, contributesSimilarMessage: true,
                  mailboxInfo: .init(mailboxPath: [folder], accountHint: "Work"),
                  header: .init(subject: subject, sender: sender, date: Date()), bodyPreview: "Standard footer")
        }
        let good = candidate("good", folder: "Reviews", subject: context.subject, sender: context.sender)
        let drafts = ["Drafts", "Outbox", "Sent", "Inbox"].map {
            candidate($0, folder: $0, subject: context.subject, sender: context.sender)
        }
        let unrelated = (0..<80).map { candidate("noise\($0)", folder: "Unrelated", subject: "Follow up", sender: "other@example.org") }
        let ranker = SpotlightMessageRanker()
        let candidates = unrelated + drafts + [good]
        let folders = ranker.groupedLocations(from: candidates, currentMailbox: context.currentMailbox, context: context)
        // A weaker hit accepted by the visible message list must not lose its folder.
        XCTAssertEqual(folders.map(\.displayPath), ["Reviews", "Unrelated"])
        let orders = ranker.folderOrders(rankedLocations: folders, messages: ranker.similarMessages(from: candidates, context: context), candidates: candidates)
        XCTAssertEqual(orders.displayed.map(\.displayPath), ["Reviews", "Unrelated"])
        XCTAssertEqual(orders.displayed.first?.hitCount, 1)
    }

    func testStrongEvidenceStillPrecedesHigherCompositeScore() {
        let ranker = SpotlightMessageRanker()
        let ordinary = RankedMessageLocation(mailboxPath: ["High score"], accountHint: nil, score: 999, semanticScore: 1,
                                             hitCount: 1, samplePath: "a")
        let established = RankedMessageLocation(mailboxPath: ["Established"], accountHint: nil, score: 50, semanticScore: 0.1,
                                                hitCount: 5, samplePath: "b")
        XCTAssertEqual(ranker.rankedLocations([ordinary, established], preferHitCount: true).first?.displayPath, "Established")
    }
}

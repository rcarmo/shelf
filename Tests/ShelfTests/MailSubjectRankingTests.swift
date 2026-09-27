import XCTest
@testable import Shelf

final class MailSubjectRankingTests: XCTestCase {
    private let context = MailMessageContext(
        sender: "alice@client.example", senderEmail: "alice@client.example",
        subject: "Atlas deployment migration schedule", currentMailbox: "Inbox", currentAccount: "Work",
        bodyPreview: "Standard footer contact support office address telephone disclaimer"
    )

    private func candidate(_ path: String, subject: String, sender: String = "bob@partner.example", rank: Int = 500,
                           body: String = "") -> MessageCandidate {
        .init(path: path, rank: rank, supportsMailFiling: true, contributesSimilarMessage: true,
              mailboxInfo: .init(mailboxPath: ["Projects"], accountHint: "Work"),
              header: .init(subject: subject, sender: sender, date: Date(timeIntervalSince1970: 100)), bodyPreview: body)
    }

    func testCrossSenderThreadBeatsRecentSameSenderWithMatchingBoilerplate() {
        let thread = candidate("thread", subject: "Re: Fwd: \(context.subject)")
        let sender = candidate("shelf-mail-message://1", subject: "Holiday accommodation", sender: context.sender,
                               rank: 1, body: context.bodyPreview)
        XCTAssertEqual(SpotlightMessageRanker().similarMessages(from: [sender, thread], context: context).first?.path, "thread")
        XCTAssertGreaterThan(SpotlightMailQuery.relevanceScore(for: thread, context: context, terms: context.searchTerms),
                             SpotlightMailQuery.relevanceScore(for: sender, context: context, terms: context.searchTerms))
        XCTAssertGreaterThan(SpotlightMessageRanker().filingSimilarityScore(thread, context: context),
                             SpotlightMessageRanker().filingSimilarityScore(sender, context: context))
    }

    func testSubstantialSubjectOverlapBeatsSenderAndBodyButExactThreadStillWins() {
        let exact = candidate("exact", subject: "Re: \(context.subject)")
        let topic = candidate("topic", subject: "Atlas deployment migration followup")
        let sender = candidate("shelf-mail-message://1", subject: "Holiday accommodation", sender: context.sender,
                               rank: 1, body: context.bodyPreview)
        XCTAssertEqual(SpotlightMessageRanker().similarMessages(from: [sender, topic, exact], context: context).map(\.path),
                       ["exact", "topic", "shelf-mail-message://1"])
        XCTAssertGreaterThan(SpotlightMailQuery.relevanceScore(for: topic, context: context, terms: context.searchTerms),
                             SpotlightMailQuery.relevanceScore(for: sender, context: context, terms: context.searchTerms))
        XCTAssertGreaterThan(SpotlightMessageRanker().filingSimilarityScore(topic, context: context),
                             SpotlightMessageRanker().filingSimilarityScore(sender, context: context))
    }

    func testSingleSharedWordDoesNotGetStrongSubjectBonus() {
        let match = MailSubjectMatch("Atlas deployment migration schedule", "Schedule annual holiday travel")
        XCTAssertFalse(match.exact)
        XCTAssertFalse(match.strong)
        XCTAssertEqual(match.sharedTerms, 1)
        XCTAssertLessThan(match.relatedBoost, 45)
    }

    func testGenericFollowUpDoesNotHideSameSenderConversation() {
        var selected = context
        selected.subject = "Re: Follow-up: Atlas and Helios appliance"
        selected.bodyPreview = ""
        let generic = candidate("shelf-mail-message://2", subject: "Re: Follow up", body: "Follow up")
        let reply = candidate("reply", subject: "Follow-up: Atlas and Helios appliance", sender: selected.sender)
        let similar = candidate("similar", subject: "Atlas Helios appliance delivery", sender: selected.sender)
        let matches = SpotlightMessageRanker().similarMessages(from: [generic, similar, reply], context: selected)
        XCTAssertEqual(matches.map(\.path), ["reply", "similar"])
        XCTAssertEqual(MailSubjectMatch(selected.subject, "Re: Follow up").sharedTerms, 0)
        XCTAssertFalse(SpotlightMailQuery.matchingPredicate(context: selected, terms: [], mode: .threadSubject)
            .evaluate(with: ["kMDItemContentType": "com.apple.mail.emlx", "kMDItemContentTypeTree": ["public.email-message"],
                             "kMDItemPath": "/fixture.emlx", "kMDItemSubject": "Follow up",
                             "kMDItemTitle": "Follow up", "kMDItemDisplayName": "Follow up"]))
    }

    func testNativeRetrievalPrioritizesCurrentAccountWithoutFolderNameOverlap() {
        let reviews = MailApplicationBridge.logicalMailboxPriority(path: ["Reviews"], account: "Work", context: context, terms: ["Atlas"])
        let otherAccount = MailApplicationBridge.logicalMailboxPriority(path: ["Atlas"], account: "Other", context: context, terms: ["Atlas"])
        XCTAssertGreaterThan(reviews, otherAccount)
        let bridge = MailApplicationBridge()
        let related = MailLogicalMessageRecord(libraryID: 1, subject: "Re: \(context.subject)", sender: context.sender,
                                              mailboxPath: ["Reviews"], accountName: "Work")
        let generic = MailLogicalMessageRecord(libraryID: 2, subject: "Follow up", sender: "other@example.com", date: Date(),
                                              mailboxPath: ["Atlas"], accountName: "Work")
        XCTAssertGreaterThan(bridge.logicalMessageScore(related, context: context, terms: []), 0)
        XCTAssertEqual(bridge.logicalMessageScore(generic, context: context, terms: []), 0)
    }

    func testNormalizationHandlesReplyCountersButPreservesTicketAndProjectIdentity() {
        XCTAssertTrue(MailSubjectMatch("Re[2]: Fwd: [Atlas-42] Deployment review", "[Atlas-42] Deployment review").exact)
        XCTAssertFalse(MailSubjectMatch("[Atlas-42] Deployment review", "[Atlas-43] Deployment review").exact)
        XCTAssertFalse(MailSubjectMatch("Project 1", "Project 2").exact)
        XCTAssertFalse(MailSubjectMatch("Re:", "Fwd:").exact)
    }
}

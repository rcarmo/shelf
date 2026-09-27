import XCTest
@testable import Shelf

final class SpotlightMailMatchingTests: XCTestCase {
    func testOnlyManagedMailboxesAreAccepted() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        XCTAssertTrue(SpotlightMailQuery.isManagedMailPath("/Users/fixture/Library/Mail/V10/account/Inbox.mbox/Messages/42.emlx", home: home))
        for path in ["/Users/fixture/Downloads/saved.eml", "/Users/fixture/Documents/Archive.mbox/42.emlx",
                     "/Users/fixture/Library/Mail-backup/Inbox.mbox/42.emlx", "/Users/other/Library/Mail/Inbox.mbox/42.emlx",
                     "/Users/fixture/Library/Mail/Downloads/saved.eml",
                     "/Users/fixture/Library/Mail/../../../Downloads/Archive.mbox/42.eml"] {
            XCTAssertFalse(SpotlightMailQuery.isManagedMailPath(path, home: home), path)
        }
    }
    private func context(subject: String = "Atlas design migration rollout schedule budget planning review decision notes") -> MailMessageContext {
        .init(sender: "alice@client.example", senderEmail: "alice@client.example", subject: subject,
              currentMailbox: "Inbox", currentAccount: "Work", bodyPreview: "Helios telemetry performance")
    }

    private func metadata(subject: String, body: String = "") -> [String: Any] {
        ["kMDItemContentType": "com.apple.mail.emlx", "kMDItemContentTypeTree": ["public.email-message"],
         "kMDItemPath": "/fixture/message.emlx", "kMDItemSubject": subject, "kMDItemTitle": subject,
         "kMDItemDisplayName": subject, "kMDItemTextContent": body,
         "NSMetadataQueryString": "", "kMDItemEmailAddresses": [], "kMDItemAuthorAddresses": [],
         "kMDItemRecipientAddresses": [], "kMDItemAuthors": [], "kMDItemRecipients": [],
         "kMDItemAuthorEmailAddresses": [], "kMDItemRecipientEmailAddresses": []]
    }

    private func candidate(_ path: String, subject: String, sender: String = "bob@partner.example",
                           body: String = "", folder: String = "Projects", rank: Int = 1) -> MessageCandidate {
        .init(path: path, rank: rank, supportsMailFiling: true, contributesSimilarMessage: true,
              mailboxInfo: .init(mailboxPath: [folder], accountHint: "Work"),
              header: .init(subject: subject, sender: sender, date: Date(timeIntervalSince1970: 100)), bodyPreview: body)
    }

    func testSubjectQueryMatchesPartialConversationTitlesButNotBodyOnlyOrSingleCommonWord() {
        let context = context()
        let predicate = SpotlightMailQuery.matchingPredicate(context: context, terms: context.searchTerms, mode: .threadSubject)
        XCTAssertTrue(predicate.evaluate(with: metadata(subject: "Re: Atlas design follow-up")))
        XCTAssertFalse(predicate.evaluate(with: metadata(subject: "Design newsletter")))
        XCTAssertFalse(predicate.evaluate(with: metadata(subject: "Unrelated", body: context.subject)))
    }

    func testSingleSubjectTermWorksAndEmptySubjectDoesNotScanAllMail() {
        let single = context(subject: "Atlas")
        XCTAssertTrue(SpotlightMailQuery.matchingPredicate(context: single, terms: [], mode: .threadSubject)
            .evaluate(with: metadata(subject: "Re: Atlas")))
        let empty = context(subject: "Re: the")
        XCTAssertFalse(SpotlightMailQuery.matchingPredicate(context: empty, terms: [], mode: .threadSubject)
            .evaluate(with: metadata(subject: "Anything")))
    }

    func testSemanticSearchKeepsShortAcronyms() {
        var context = context(subject: "API")
        context.bodyPreview = ""
        XCTAssertTrue(SpotlightMailQuery.matchingPredicate(context: context, terms: context.searchTerms, mode: .semantic)
            .evaluate(with: metadata(subject: "API integration")))
    }

    func testWeakerTopicMatchesFillSlotsAfterStrongMatches() {
        let strong = candidate("strong", subject: "Other discussion", sender: "alice@client.example")
        let weaker = candidate("weaker", subject: "Atlas amber bronze cobalt delta ebony fossil granite hazel indigo")
        let unrelated = candidate("unrelated", subject: "Vacation")
        let matches = SpotlightMessageRanker().similarMessages(from: [weaker, unrelated, strong], context: context())
        XCTAssertEqual(matches.map(\.path), ["strong", "weaker"])
    }

    func testBestDuplicateWinsInsteadOfFirstHeaderOnlyHit() {
        let subject = "Atlas amber bronze cobalt delta ebony fossil granite hazel indigo"
        let poor = candidate("header-only", subject: subject)
        let rich = candidate("with-body", subject: subject, body: "Helios telemetry performance")
        XCTAssertEqual(SpotlightMessageRanker().similarMessages(from: [poor, rich], context: context()).map(\.path), ["with-body"])
    }

    func testRelaxationKeepsLimitAndExcludesJunkAndDomainOnlyMatches() {
        let strong = (0..<12).map { candidate("strong-\($0)", subject: "Design \($0)", sender: "alice@client.example") }
        let junk = candidate("junk", subject: context().subject, sender: "alice@client.example", folder: "Junk")
        let domainOnly = candidate("domain-only", subject: "Vacation", sender: "other@client.example")
        let matches = SpotlightMessageRanker().similarMessages(from: [junk, domainOnly] + strong, context: context())
        XCTAssertEqual(matches.count, 10)
        XCTAssertTrue(matches.allSatisfy { $0.path.hasPrefix("strong-") })
    }
}

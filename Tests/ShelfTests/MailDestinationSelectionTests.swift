import XCTest
@testable import Shelf

final class MailDestinationSelectionTests: XCTestCase {
    private let context = MailMessageContext(sender: "notifications@example.org", subject: "Project update", currentMailbox: "Inbox", bodyPreview: "")
    private let accounts = MailAccountDirectory(accounts: [.init(id: "cloud-id", name: "Cloud")])

    func testAccountlessLearnedGitHubAnd64FiledMessagesProduceOneActualDestination() async {
        let messages = (0..<64).map { index in
            MessageCandidate(path: "fixture\(index)", rank: index + 1, supportsMailFiling: true, contributesSimilarMessage: true,
                             mailboxInfo: .init(mailboxPath: ["Services", "GitHub"], accountHint: "cloud-id"),
                             header: .init(subject: "Prior message \(index)", sender: context.sender,
                                           date: Date(timeIntervalSince1970: Double(index) * 86_400)), bodyPreview: "")
        }
        var learned = messages[0]
        learned.path = "shelf-learning://Services/GitHub"
        learned.mailboxInfo.accountHint = nil
        learned.contributesSimilarMessage = false
        learned.filingMemoryScore = 0.8
        let raw = await SpotlightMessageRanker().mailSuggestions(from: messages + [learned], context: context,
                                                                diagnostic: "", requiresFullDiskAccess: false, accounts: accounts)
        XCTAssertEqual(raw.locations.count, 2, "Reproduce the observed accountless learning record.")
        let actual = MailDestinationIdentity(accountID: "cloud-id", path: ["Services", "GitHub"])
        let identities = Dictionary(uniqueKeysWithValues: raw.locations.map { (MailDestinationKey($0), actual) })
        let result = MailDestinationSelection.resolved(raw, identities: identities, accounts: accounts, context: context)
        XCTAssertEqual(result.locations.count, 1)
        XCTAssertEqual(result.locations.first?.qualifiedDisplayPath, "Cloud / Services / GitHub")
        XCTAssertEqual(result.locations.first?.hitCount, 64)
        XCTAssertEqual(result.locations.first?.senderHitCount, 64)
        XCTAssertEqual(result.decisionEvidence.count, 1)
        XCTAssertEqual(result.decisionEvidence.first?.records.filter(\.isLearnedMove).count, 1)
    }

    func testUnresolvedDestinationsAreNotOfferedAndDuplicateAliasesDoNotTakeDisplaySlots() {
        let evidence = (0..<8).map { index in
            MailFolderEvidence(location: .init(mailboxPath: ["Folder\(index)"], accountHint: "alias\(index)",
                                                score: 10, semanticScore: 0, hitCount: 0, samplePath: "fixture\(index)"),
                               records: [], visibleRelatedCount: 0, ambiguousAccount: false)
        }
        let identities = Dictionary(uniqueKeysWithValues: evidence.dropLast().enumerated().map { index, item in
            (MailDestinationKey(item.location), MailDestinationIdentity(accountID: "cloud-id", path: ["Folder\(max(0, index - 1))"]))
        })
        let raw = MailSuggestions(locations: Array(evidence.prefix(5).map(\.location)), messages: [], diagnostic: "",
                                  requiresFullDiskAccess: false, decisionEvidence: evidence)
        let result = MailDestinationSelection.resolved(raw, identities: identities, accounts: accounts, context: context)
        XCTAssertEqual(result.locations.count, 5)
        XCTAssertEqual(result.decisionEvidence.count, 6)
        XCTAssertEqual(result.locations.map(\.mailboxName), ["Folder0", "Folder1", "Folder2", "Folder3", "Folder4"])
        XCTAssertTrue(result.diagnostic.contains("1 unresolved"))
    }

    func testActualDifferentAccountsRemainDistinctAndResolvedInboxIsExcluded() {
        let evidence = ["a", "b", "inbox"].map { hint in
            MailFolderEvidence(location: .init(mailboxPath: ["GitHub"], accountHint: hint, score: 1,
                                                semanticScore: 0, hitCount: 0, samplePath: hint),
                               records: [], visibleRelatedCount: 0, ambiguousAccount: false)
        }
        let identities = Dictionary(uniqueKeysWithValues: evidence.map {
            (MailDestinationKey($0.location), MailDestinationIdentity(accountID: $0.location.accountHint!,
                                                                      path: [$0.location.accountHint == "inbox" ? "INBOX" : "GitHub"]))
        })
        let raw = MailSuggestions(locations: evidence.map(\.location), messages: [], diagnostic: "", requiresFullDiskAccess: false,
                                  decisionEvidence: evidence)
        let result = MailDestinationSelection.resolved(raw, identities: identities, accounts: accounts, context: context)
        XCTAssertEqual(Set(result.locations.compactMap(\.accountHint)), ["a", "b"])
    }
}

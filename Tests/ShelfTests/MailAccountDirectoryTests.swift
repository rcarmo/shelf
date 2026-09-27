import XCTest
@testable import Shelf

final class MailAccountDirectoryTests: XCTestCase {
    private let workID = "AAAAAAAA-1111-2222-3333-444444444444"
    private let personalID = "BBBBBBBB-1111-2222-3333-444444444444"
    private let selectedID = "CCCCCCCC-1111-2222-3333-444444444444"

    private var directory: MailAccountDirectory {
        .init(accounts: [.init(id: workID, name: "Work"), .init(id: personalID, name: "Personal")])
    }

    private var context: MailMessageContext {
        .init(sender: "alice@example.org", senderEmail: "alice@example.org", subject: "Atlas deployment",
              currentMailbox: "Inbox", currentAccount: "Other", bodyPreview: "",
              selection: [.init(libraryID: 99, accountID: selectedID)])
    }

    private func message(path: String, account: String?, folder: [String] = ["Projects", "Atlas"], day: Int = 1) -> MessageCandidate {
        .init(path: path, rank: 1, supportsMailFiling: true, contributesSimilarMessage: true,
              mailboxInfo: .init(mailboxPath: folder, accountHint: account),
              header: .init(subject: context.subject, sender: context.sender,
                            date: Date(timeIntervalSince1970: Double(day) * 86_400)), bodyPreview: "")
    }

    func testAllAccountAliasesResolveToStableIDsNotJustSelectedAccount() {
        XCTAssertEqual(directory.canonicalHint("Work"), workID)
        XCTAssertEqual(directory.canonicalHint(workID.lowercased()), workID)
        XCTAssertEqual(directory.canonicalHint("Personal"), personalID)
        XCTAssertEqual(directory.including(context).canonicalHint("Other"), selectedID)
        XCTAssertEqual(directory.displayName(for: workID), "Work")
        XCTAssertTrue(MailAccountDirectory.sameID(workID, workID.lowercased()))
        XCTAssertFalse(MailAccountDirectory.sameID(workID, personalID))
    }

    func testNativeSpotlightAndLearnedAliasesProduceOneDestination() async throws {
        let spotlight = message(path: "/fixture/message.emlx", account: workID.lowercased())
        let native = message(path: "shelf-mail-message://1", account: "Work")
        var learned = message(path: "shelf-learning://Atlas", account: "Work")
        learned.contributesSimilarMessage = false
        learned.filingMemoryScore = 0.8
        let suggestions = await SpotlightMessageRanker().mailSuggestions(from: [spotlight, native, learned], context: context,
                                                                        diagnostic: "", requiresFullDiskAccess: false,
                                                                        accounts: directory)
        XCTAssertEqual(suggestions.locations.count, 1)
        let destination = try XCTUnwrap(suggestions.locations.first)
        XCTAssertEqual(destination.accountHint, workID)
        XCTAssertEqual(destination.qualifiedDisplayPath, "Work / Projects / Atlas")
        XCTAssertEqual(destination.hitCount, 1, "The same message found twice is one example.")
        XCTAssertEqual(suggestions.decisionEvidence.count, 1)
        XCTAssertFalse(try XCTUnwrap(suggestions.decisionEvidence.first).ambiguousAccount)
        XCTAssertEqual(Set(suggestions.messages.compactMap(\.accountHint)), [workID])
    }

    func testDistinctAccountsAndParentPathsNeverMerge() async {
        let candidates = [
            message(path: "a", account: "Work"),
            message(path: "b", account: workID, day: 2),
            message(path: "c", account: "Personal"),
            message(path: "d", account: personalID, day: 2),
            message(path: "e", account: "Work", folder: ["Archive", "Atlas"])
        ]
        let result = await SpotlightMessageRanker().mailSuggestions(from: candidates, context: context, diagnostic: "",
                                                                   requiresFullDiskAccess: false, accounts: directory)
        XCTAssertEqual(result.locations.count, 3)
        XCTAssertEqual(Set(result.locations.map(\.id)).count, 3)
        XCTAssertEqual(result.locations.filter { $0.mailboxPath == ["Projects", "Atlas"] }.count, 2)
    }

    func testAmbiguousNamesAndUnknownAccountsAreNotGuessed() {
        let ambiguous = MailAccountDirectory(accounts: [.init(id: workID, name: "Work"), .init(id: personalID, name: "Work")])
        XCTAssertEqual(ambiguous.canonicalHint("Work"), "Work")
        XCTAssertEqual(ambiguous.canonicalHint(workID), workID)
        XCTAssertEqual(ambiguous.canonicalHint(personalID), personalID)
        XCTAssertNotEqual(ambiguous.displayName(for: workID), ambiguous.displayName(for: personalID))
        XCTAssertEqual(directory.canonicalHint("Unrecognized"), "Unrecognized")
        XCTAssertNil(directory.canonicalHint(nil))
        XCTAssertNil(directory.canonicalHint(""))
        var mixed = context
        mixed.selection = [.init(libraryID: 1, accountID: workID), .init(libraryID: 2, accountID: selectedID)]
        XCTAssertEqual(MailAccountDirectory().including(mixed).canonicalHint("Other"), "Other")
    }

    func testLocalMailboxAliasesMergeWithoutGuessingUnknownAccount() async {
        let result = await SpotlightMessageRanker().mailSuggestions(
            from: [message(path: "disk", account: "Mailboxes"), message(path: "native", account: "local")],
            context: context, diagnostic: "", requiresFullDiskAccess: false, accounts: directory)
        XCTAssertEqual(result.locations.count, 1)
        XCTAssertEqual(result.locations.first?.accountHint, "local")
        XCTAssertEqual(result.locations.first?.qualifiedDisplayPath, "On My Mac / Projects / Atlas")
    }

    func testInboxIsNeverAFilingDestinationEvenWhenItIsNotTheSelectedMailbox() async {
        var selected = context
        selected.currentMailbox = "Sent"
        let paths = [["INBOX"], ["Inbox"], ["inbox"], ["Trash", "GitHub"], ["INBOX", "GitHub"]]
        let candidates = paths.enumerated().map { message(path: "fixture\($0.offset)", account: "Work", folder: $0.element) }
        let suggestions = await SpotlightMessageRanker().mailSuggestions(from: candidates, context: selected, diagnostic: "",
                                                                        requiresFullDiskAccess: false, accounts: directory)
        XCTAssertEqual(suggestions.locations.map(\.mailboxPath), [["INBOX", "GitHub"]])
        for path in paths.dropLast() {
            XCTAssertFalse(MailFilingRetrieval.isDestination(path, currentMailbox: "Sent"))
            XCTAssertNil(MailFilingRetrieval.folderKey(path: path, account: "Work", subject: selected.subject,
                                                      sender: selected.sender, context: selected))
        }
    }
}

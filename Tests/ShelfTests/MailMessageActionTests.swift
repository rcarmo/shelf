import XCTest
@testable import Shelf

final class MailMessageActionTests: XCTestCase {
    private func context(selection: [MailMessageIdentity] = [.init(libraryID: 42, accountID: "work")]) -> MailMessageContext {
        .init(sender: "Alice <alice@example.org>", senderEmail: "alice@example.org", recipients: ["bob@example.org"],
              subject: "Atlas deployment", currentMailbox: "Inbox", bodyPreview: "", selection: selection)
    }

    @MainActor
    func testMessageActionsDoNotRequireContactOrFilingMatches() {
        let message = context()
        let hint = AppHint(bundleIdentifier: "com.apple.mail", applicationName: "Mail", kind: .email,
                           title: message.subject, subtitle: "", value: message.sender, mailContext: message, confidence: 1)
        let titles = AutomationRunner().actions(for: nil, hint: hint).map(\.title)
        for title in ["Reply", "Reply All", "Forward", "Copy Sender Address", "Copy Message Details", "Return to Mail"] {
            XCTAssertTrue(titles.contains(title), title)
        }
        XCTAssertFalse(titles.contains { $0.hasPrefix("Move to") })
    }

    func testNoDraftForUnboundOrMultipleMessages() {
        for identities: [MailMessageIdentity] in [[], [.init(libraryID: 0, accountID: "work")],
                                                 [.init(libraryID: 42, accountID: "")],
                                                 [.init(libraryID: 42, accountID: "work"), .init(libraryID: 43, accountID: "work")]] {
            XCTAssertFalse(MailMessageActions.hints(for: context(selection: identities)).contains {
                if case .draft = $0.operation { return true }; return false
            })
            XCTAssertNil(MailDraftKind.reply.script(selection: identities))
        }
    }

    func testDraftScriptsBindMessageAndAccountAndNeverSend() throws {
        for kind in MailDraftKind.allCases {
            let script = try XCTUnwrap(kind.script(selection: context().selection))
            XCTAssertTrue(script.contains("(id of selectedMessage) is not 42"))
            XCTAssertTrue(script.contains("selectedAccount is not \"work\""))
            XCTAssertTrue(script.contains("(count of selectedMessages) is not 1"))
            XCTAssertTrue(script.contains("with timeout of 5 seconds"))
            XCTAssertFalse(script.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("send ") })
            var error: NSDictionary?
            XCTAssertTrue(try XCTUnwrap(NSAppleScript(source: script)).compileAndReturnError(&error), "\(error?.description ?? "")")
        }
    }

    func testLinksAreBoundedDeduplicatedAndDetailsExcludeBody() {
        var message = context()
        message.bodyPreview = "PRIVATE BODY https://example.org/a https://example.org/a https://example.org/b https://example.org/c https://example.org/d file:///tmp/private javascript:alert(1)"
        let hints = MailMessageActions.hints(for: message)
        let urls = hints.compactMap { hint -> URL? in
            if case .open(let url) = hint.operation { return url }; return nil
        }
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(Set(urls).count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "https" })
        for hint in hints {
            if case .copy(let text) = hint.operation { XCTAssertFalse(text.contains("PRIVATE BODY")) }
        }
    }
}

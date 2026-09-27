import XCTest
@testable import Shelf

private actor TestMailActions: MailActionServicing {
    let started: XCTestExpectation
    private var resolutions = 0
    init(started: XCTestExpectation) { self.started = started }
    func destinationIdentity(for location: RankedMessageLocation) async -> MailDestinationIdentity? {
        resolutions += 1
        started.fulfill()
        try? await Task.sleep(for: .milliseconds(100))
        return .init(accountID: "account", path: location.mailboxPath)
    }
    func move(to location: RankedMessageLocation, selection: [MailMessageIdentity], destination: MailDestinationIdentity?) -> MailBridgeResult {
        .init(output: "", error: "Test does not move messages")
    }
    func count() -> Int { resolutions }
}

final class MailActionPerformanceTests: XCTestCase {
    private func location(_ name: String = "Projects", account: String = "Work") -> RankedMessageLocation {
        .init(mailboxPath: [name], accountHint: account, score: 1, semanticScore: 0, hitCount: 1, samplePath: "fixture")
    }

    func testDestinationCacheExpiresBoundsAndSeparatesAccounts() {
        var cache = MailDestinationCache(capacity: 2)
        let start = Date(timeIntervalSince1970: 100)
        let first = MailDestinationKey(location())
        let second = MailDestinationKey(location(account: "Personal"))
        let identity = MailDestinationIdentity(accountID: "account", path: ["Projects"])
        cache.insert(identity, for: first, now: start)
        cache.insert(nil, for: second, now: start.addingTimeInterval(1))
        XCTAssertEqual(cache.lookup(first, now: start.addingTimeInterval(59))?.identity, identity)
        XCTAssertNotNil(cache.lookup(second, now: start.addingTimeInterval(5)))
        XCTAssertNil(cache.lookup(second, now: start.addingTimeInterval(11)))
        XCTAssertNil(cache.lookup(first, now: start.addingTimeInterval(60)))
        for index in 0..<5 {
            cache.insert(identity, for: MailDestinationKey(location("Folder\(index)")), now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(cache.entries.count, 2)
        let newest = MailDestinationKey(location("Folder4"))
        cache.invalidate(newest)
        XCTAssertNil(cache.lookup(newest, now: start.addingTimeInterval(5)))
    }

    @MainActor
    func testBuildingActionsDoesNotWaitForMailAndReusesInFlightBinding() async {
        let started = expectation(description: "one asynchronous binding")
        started.assertForOverFulfill = true
        let service = TestMailActions(started: started)
        let runner = AutomationRunner(mailActions: service)
        let context = MailMessageContext(sender: "fixture", subject: "Subject", currentMailbox: "Inbox", bodyPreview: "",
                                          selection: [.init(libraryID: 1, accountID: "account")])
        let hint = AppHint(bundleIdentifier: "com.apple.mail", applicationName: "Mail", kind: .email,
                           title: "Subject", subtitle: "", value: "fixture", mailContext: context, confidence: 1)
        for _ in 0..<20 {
            XCTAssertFalse(runner.actions(for: nil, hint: hint, messageLocations: [location()], mailContext: context).isEmpty)
        }
        await fulfillment(of: [started], timeout: 2)
        let count = await service.count()
        XCTAssertEqual(count, 1)
        runner.invalidateMailBindings()
    }
}

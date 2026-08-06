import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor SafariContextResolver {
    private struct ReadingListItem {
        var title: String
        var url: URL
        var preview: String
        var dateAdded: Date?
    }

    private struct HistoryVisit {
        var databasePath: String
        var url: URL
        var title: String
        var date: Date
    }

    private struct HistoryStoreResult {
        var visits: [HistoryVisit]
        var accessDenied: Bool
        var diagnostic: String?
    }

    private struct ReadingListResult {
        var items: [ReadingListItem]
        var available: Bool
        var accessDenied: Bool
        var diagnostic: String?
    }

    private var readingListCache: (modificationDate: Date?, items: [ReadingListItem])?

    nonisolated func updates(
        for url: URL,
        title: String,
        observedAt: Date
    ) -> AsyncStream<SafariContextUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await self.resolve(
                    url: url,
                    title: title,
                    observedAt: observedAt,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func resolve(
        url: URL,
        title: String,
        observedAt: Date,
        continuation: AsyncStream<SafariContextUpdate>.Continuation
    ) {
        var snapshot = SafariContextSnapshot()
        let readingList = loadReadingList()
        let targetIdentity = SafariURLIdentity(url: url)

        if !readingList.available {
            snapshot.readingListState = .unavailable
            snapshot.requiresFullDiskAccess = readingList.accessDenied
        } else {
            snapshot.readingListState = readingList.items.contains {
                SafariURLIdentity(url: $0.url).canonical == targetIdentity.canonical
            } ? .included : .notIncluded
        }
        snapshot.diagnostic = readingList.diagnostic ?? "Checking Safari history"
        snapshot.relatedPages = rankRelatedPages(
            targetURL: url,
            targetTitle: title,
            readingListItems: readingList.items,
            historyVisits: []
        )
        continuation.yield(SafariContextUpdate(snapshot: snapshot, isFinal: false))

        guard !Task.isCancelled else {
            continuation.finish()
            return
        }

        let stores = historyDatabaseURLs()
        var allVisits: [HistoryVisit] = []
        var diagnostics: [String] = []
        var anyHistoryStoreOpened = false

        for store in stores.urls {
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }

            let result = loadHistory(from: store, targetURL: url, targetTitle: title)
            if result.accessDenied {
                snapshot.requiresFullDiskAccess = true
            } else if result.diagnostic == nil {
                anyHistoryStoreOpened = true
            }
            if let diagnostic = result.diagnostic {
                diagnostics.append(diagnostic)
            }
            allVisits.append(contentsOf: result.visits)

            updateHistory(
                snapshot: &snapshot,
                targetURL: url,
                targetTitle: title,
                observedAt: observedAt,
                readingListItems: readingList.items,
                visits: deduplicated(allVisits)
            )
            snapshot.historyAvailable = anyHistoryStoreOpened
            snapshot.diagnostic = statusText(for: snapshot, isFinal: false)
            continuation.yield(SafariContextUpdate(snapshot: snapshot, isFinal: false))
        }

        if stores.accessDenied {
            snapshot.requiresFullDiskAccess = true
        }
        snapshot.historyAvailable = anyHistoryStoreOpened
        updateHistory(
            snapshot: &snapshot,
            targetURL: url,
            targetTitle: title,
            observedAt: observedAt,
            readingListItems: readingList.items,
            visits: deduplicated(allVisits)
        )

        if !anyHistoryStoreOpened, !diagnostics.isEmpty, !snapshot.requiresFullDiskAccess {
            snapshot.diagnostic = diagnostics[0]
        } else {
            snapshot.diagnostic = statusText(for: snapshot, isFinal: true)
        }
        continuation.yield(SafariContextUpdate(snapshot: snapshot, isFinal: true))
        continuation.finish()
    }

    private func updateHistory(
        snapshot: inout SafariContextSnapshot,
        targetURL: URL,
        targetTitle: String,
        observedAt: Date,
        readingListItems: [ReadingListItem],
        visits: [HistoryVisit]
    ) {
        let canonical = SafariURLIdentity(url: targetURL).canonical
        var exactDates = visits
            .filter { SafariURLIdentity(url: $0.url).canonical == canonical }
            .map(\.date)
            .sorted(by: >)

        if let newest = exactDates.first,
           newest >= observedAt.addingTimeInterval(-30 * 60),
           newest <= observedAt.addingTimeInterval(5 * 60) {
            exactDates.removeFirst()
        }

        snapshot.previousVisit = exactDates.first
        snapshot.previousVisitCount = exactDates.count
        snapshot.relatedPages = rankRelatedPages(
            targetURL: targetURL,
            targetTitle: targetTitle,
            readingListItems: readingListItems,
            historyVisits: visits
        )
    }

    private func loadReadingList() -> ReadingListResult {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
        let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        if let cache = readingListCache, cache.modificationDate == modificationDate {
            return ReadingListResult(items: cache.items, available: true, accessDenied: false, diagnostic: nil)
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let children = readingListChildren(in: propertyList) else {
                return ReadingListResult(
                    items: [],
                    available: false,
                    accessDenied: false,
                    diagnostic: "Safari Reading List format is not supported"
                )
            }
            let items = children.compactMap(readingListItem(from:))
            readingListCache = (modificationDate, items)
            return ReadingListResult(items: items, available: true, accessDenied: false, diagnostic: nil)
        } catch {
            return ReadingListResult(
                items: [],
                available: false,
                accessDenied: isPermissionError(error),
                diagnostic: "Safari Reading List is unavailable"
            )
        }
    }

    private func readingListChildren(in value: Any) -> [[String: Any]]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["Title"] as? String == "com.apple.ReadingList" {
                return dictionary["Children"] as? [[String: Any]] ?? []
            }
            for child in dictionary.values {
                if let matches = readingListChildren(in: child) {
                    return matches
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let matches = readingListChildren(in: child) {
                    return matches
                }
            }
        }
        return nil
    }

    private func readingListItem(from dictionary: [String: Any]) -> ReadingListItem? {
        guard let rawURL = dictionary["URLString"] as? String,
              let url = URL(string: rawURL) else {
            return nil
        }

        let uriDictionary = dictionary["URIDictionary"] as? [String: Any]
        let nonSync = dictionary["ReadingListNonSync"] as? [String: Any]
        let readingList = dictionary["ReadingList"] as? [String: Any]
        let title = (uriDictionary?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (nonSync?["PreviewText"] as? String)
            ?? (readingList?["PreviewText"] as? String)
            ?? ""

        return ReadingListItem(
            title: title?.isEmpty == false ? title! : (url.host ?? rawURL),
            url: url,
            preview: preview,
            dateAdded: dateValue(nonSync?["DateAdded"] ?? readingList?["DateAdded"])
        )
    }

    private func historyDatabaseURLs() -> (urls: [URL], accessDenied: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        var accessDenied = false
        let defaultHistory = home.appendingPathComponent("Library/Safari/History.db")
        if FileManager.default.fileExists(atPath: defaultHistory.path) {
            urls.append(defaultHistory)
        }

        let profileRoots = [
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles"),
            home.appendingPathComponent("Library/Safari/Profiles")
        ]

        for root in profileRoots where FileManager.default.fileExists(atPath: root.path) {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    let history = child.appendingPathComponent("History.db")
                    if FileManager.default.fileExists(atPath: history.path) {
                        urls.append(history)
                    }
                }
            } catch {
                accessDenied = accessDenied || isPermissionError(error)
            }
        }

        var seen = Set<String>()
        return (urls.filter { seen.insert($0.path).inserted }, accessDenied)
    }

    private func loadHistory(from databaseURL: URL, targetURL: URL, targetTitle: String) -> HistoryStoreResult {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return HistoryStoreResult(
                visits: [],
                accessDenied: result == SQLITE_AUTH || result == SQLITE_CANTOPEN || result == SQLITE_PERM,
                diagnostic: "Could not read Safari history"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let exactResult = queryHistory(
            database: database,
            databasePath: databaseURL.path,
            whereClause: "i.url = ? COLLATE NOCASE",
            bindings: [targetURL.absoluteString],
            limit: 250
        )
        guard exactResult.succeeded else {
            return HistoryStoreResult(
                visits: [],
                accessDenied: false,
                diagnostic: "Safari history format is not supported"
            )
        }
        var visits = exactResult.visits

        let identity = SafariURLIdentity(url: targetURL)
        if !identity.host.isEmpty {
            visits.append(contentsOf: queryHistory(
                database: database,
                databasePath: databaseURL.path,
                whereClause: "i.url LIKE ? COLLATE NOCASE",
                bindings: ["%://%\(identity.registrableDomain)%"],
                limit: 2_000
            ).visits)
        }

        let titleTerms = Array(SafariURLIdentity.terms(from: targetTitle).prefix(4))
        if !titleTerms.isEmpty {
            visits.append(contentsOf: queryHistory(
                database: database,
                databasePath: databaseURL.path,
                whereClause: Array(repeating: "v.title LIKE ? COLLATE NOCASE", count: titleTerms.count)
                    .joined(separator: " OR "),
                bindings: titleTerms.map { "%\($0)%" },
                limit: 1_500
            ).visits)
        }

        return HistoryStoreResult(visits: deduplicated(visits), accessDenied: false, diagnostic: nil)
    }

    private func queryHistory(
        database: OpaquePointer,
        databasePath: String,
        whereClause: String,
        bindings: [String],
        limit: Int
    ) -> (visits: [HistoryVisit], succeeded: Bool) {
        let sql = """
        SELECT i.url, COALESCE(v.title, ''), v.visit_time
        FROM history_visits v
        JOIN history_items i ON i.id = v.history_item
        WHERE \(whereClause)
        ORDER BY v.visit_time DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return ([], false)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), binding, -1, sqliteTransient)
        }

        var visits: [HistoryVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: urlText)) else {
                continue
            }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            visits.append(HistoryVisit(
                databasePath: databasePath,
                url: url,
                title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                date: date
            ))
        }
        return (visits, true)
    }

    private func rankRelatedPages(
        targetURL: URL,
        targetTitle: String,
        readingListItems: [ReadingListItem],
        historyVisits: [HistoryVisit]
    ) -> [SafariRelatedPage] {
        struct Aggregate {
            var title: String
            var url: URL
            var lastVisited: Date?
            var visitCount: Int
            var isInReadingList: Bool
            var searchableText: String
        }

        let targetIdentity = SafariURLIdentity(url: targetURL)
        var aggregates: [String: Aggregate] = [:]

        for item in readingListItems {
            let identity = SafariURLIdentity(url: item.url)
            guard identity.canonical != targetIdentity.canonical else {
                continue
            }
            aggregates[identity.canonical] = Aggregate(
                title: item.title,
                url: item.url,
                lastVisited: nil,
                visitCount: 0,
                isInReadingList: true,
                searchableText: item.title + " " + item.preview
            )
        }

        for visit in historyVisits {
            let identity = SafariURLIdentity(url: visit.url)
            guard identity.canonical != targetIdentity.canonical else {
                continue
            }
            if var aggregate = aggregates[identity.canonical] {
                aggregate.visitCount += 1
                if aggregate.lastVisited == nil || visit.date > aggregate.lastVisited! {
                    aggregate.lastVisited = visit.date
                    if !visit.title.isEmpty {
                        aggregate.title = visit.title
                    }
                    aggregate.url = visit.url
                }
                aggregate.searchableText += " " + visit.title
                aggregates[identity.canonical] = aggregate
            } else {
                aggregates[identity.canonical] = Aggregate(
                    title: visit.title,
                    url: visit.url,
                    lastVisited: visit.date,
                    visitCount: 1,
                    isInReadingList: false,
                    searchableText: visit.title
                )
            }
        }

        return aggregates.map { canonical, aggregate in
            let identity = SafariURLIdentity(url: aggregate.url)
            let score = similarityScore(
                target: targetIdentity,
                targetTitle: targetTitle,
                candidate: identity,
                candidateText: aggregate.searchableText,
                lastVisited: aggregate.lastVisited,
                isInReadingList: aggregate.isInReadingList
            )
            return SafariRelatedPage(
                id: canonical,
                title: aggregate.title,
                url: aggregate.url,
                lastVisited: aggregate.lastVisited,
                visitCount: aggregate.visitCount,
                isInReadingList: aggregate.isInReadingList,
                score: score
            )
        }
        .filter { $0.score >= 0.16 }
        .sorted {
            if abs($0.score - $1.score) > 0.0001 {
                return $0.score > $1.score
            }
            return ($0.lastVisited ?? .distantPast) > ($1.lastVisited ?? .distantPast)
        }
        .prefix(20)
        .map { $0 }
    }

    private func similarityScore(
        target: SafariURLIdentity,
        targetTitle: String,
        candidate: SafariURLIdentity,
        candidateText: String,
        lastVisited: Date?,
        isInReadingList: Bool
    ) -> Double {
        var score = 0.0
        if !target.host.isEmpty, target.host == candidate.host {
            score += 0.42
        } else if !target.registrableDomain.isEmpty,
                  target.registrableDomain == candidate.registrableDomain {
            score += 0.28
        }

        score += 0.28 * jaccard(target.pathTerms, candidate.pathTerms)
        score += 0.28 * jaccard(
            SafariURLIdentity.terms(from: targetTitle),
            SafariURLIdentity.terms(from: candidateText)
        )
        if isInReadingList {
            score += 0.05
        }
        if let lastVisited {
            let age = max(0, Date().timeIntervalSince(lastVisited))
            score += 0.10 * exp(-age / (60 * 60 * 24 * 45))
        }
        return min(1, score)
    }

    private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private func deduplicated(_ visits: [HistoryVisit]) -> [HistoryVisit] {
        var seen = Set<String>()
        return visits.filter { visit in
            let key = [
                visit.databasePath,
                visit.url.absoluteString,
                String(Int(visit.date.timeIntervalSinceReferenceDate * 1_000))
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private func statusText(for snapshot: SafariContextSnapshot, isFinal: Bool) -> String {
        if snapshot.requiresFullDiskAccess, !snapshot.historyAvailable,
           snapshot.readingListState == .unavailable {
            return "Safari context needs Full Disk Access"
        }
        if !snapshot.relatedPages.isEmpty {
            return "Found \(snapshot.relatedPages.count) related Safari page\(snapshot.relatedPages.count == 1 ? "" : "s")\(isFinal ? "" : " so far")"
        }
        if snapshot.previousVisitCount > 0 {
            return "Previously visited \(snapshot.previousVisitCount) time\(snapshot.previousVisitCount == 1 ? "" : "s")"
        }
        return isFinal ? "No related Safari pages" : "Searching Safari history"
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == NSFileReadNoPermissionError
    }
}

struct SafariURLIdentity {
    private static let trackingKeys: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"
    ]
    private static let multipartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.jp", "co.nz", "com.br", "com.pt"
    ]
    private static let stopWords: Set<String> = [
        "www", "com", "html", "htm", "index", "the", "and", "for", "with", "from", "this", "that"
    ]

    var canonical: String
    var host: String
    var registrableDomain: String
    var pathTerms: Set<String>

    init(url: URL) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var normalizedHost = (components?.host ?? url.host ?? "").lowercased()
        if normalizedHost.hasPrefix("www.") {
            normalizedHost.removeFirst(4)
        }
        components?.scheme = nil
        components?.host = normalizedHost
        components?.port = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil

        if var queryItems = components?.queryItems {
            queryItems.removeAll { item in
                let key = item.name.lowercased()
                return key.hasPrefix("utm_") || Self.trackingKeys.contains(key)
            }
            components?.queryItems = queryItems.isEmpty
                ? nil
                : queryItems.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        var path = components?.percentEncodedPath ?? url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""

        host = normalizedHost
        registrableDomain = Self.registrableDomain(for: normalizedHost)
        canonical = normalizedHost + path + query
        pathTerms = Self.terms(from: path.removingPercentEncoding ?? path)
    }

    static func terms(from value: String) -> Set<String> {
        Set(value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    private static func registrableDomain(for host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else {
            return host
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multipartSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }
}

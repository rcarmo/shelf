import AppKit
import Combine
import Foundation

@MainActor
final class ContextMonitor: ObservableObject {
    @Published var currentHint: AppHint?
    @Published var contacts: [ContactClue] = []
    @Published var selectedContact: ContactClue?
    @Published var messageLocations: [RankedMessageLocation] = []
    @Published var similarMessages: [SimilarMessage] = []
    @Published var similarMessagesSummary = ""
    @Published var mailSuggestionStatus = ""
    @Published var actions: [AppAutomationAction] = []
    @Published var lastResult: AutomationResult?
    @Published var isSearchingMessages = false
    @Published var isSummarizingSimilarMessages = false
    @Published var mailNeedsFullDiskAccess = false
    @Published var contactsPermission: PermissionState = .unknown
    @Published var accessibilityPermission: PermissionState = .unknown
    @Published var statusText = "Starting"

    private let resolver = ContactResolver()
    private let extractors = ContextExtractorRegistry()
    private let messageRanker = SpotlightMessageRanker()
    private let intelligenceAssistant = IntelligenceAssistant()
    let automation = AutomationRunner()
    private var timer: Timer?
    private var locationSearchTask: Task<Void, Never>?
    private var similarMessagesSummaryTask: Task<Void, Never>?
    private var resultClearTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private var hintSuggestionCache: [String: HintSuggestionSnapshot] = [:]
    private let hintSuggestionCacheLifetime: TimeInterval = 10 * 60
    private let maximumHintSuggestionCacheEntries = 64

    func start() async {
        contactsPermission = resolver.permissionState
        accessibilityPermission = automation.accessibilityPermissionState

        observeApplicationActivation()
        poll(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func requestContactsAccess() async {
        contactsPermission = await resolver.requestAccessIfNeeded()
        poll(force: true)
    }

    func requestAccessibilityAccess() {
        automation.requestAccessibilityPermission()
        accessibilityPermission = automation.accessibilityPermissionState
    }

    func refresh() {
        poll(force: true)
    }

    func poll(force: Bool = false) {
        contactsPermission = resolver.permissionState
        accessibilityPermission = automation.accessibilityPermissionState

        guard var app = NSWorkspace.shared.frontmostApplication else {
            statusText = "No frontmost application"
            return
        }

        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            guard let previousApp = lastExternalApplication else {
                statusText = "Switch to Mail, then click Refresh"
                return
            }
            app = previousApp
        } else {
            lastExternalApplication = app
        }

        guard let hint = extractors.extract(from: app) else {
            currentHint = AppHint(
                bundleIdentifier: app.bundleIdentifier ?? "",
                applicationName: app.localizedName ?? "Unknown App",
                kind: .unknown,
                title: app.localizedName ?? "Unknown App",
                subtitle: "No app-specific hint available",
                value: "",
                url: nil,
                email: nil,
                fileURL: nil,
                contactIdentifier: nil,
                mailContext: nil,
                confidence: 0
            )
            contacts = []
            selectedContact = nil
            messageLocations = []
            similarMessages = []
            resetSimilarMessagesSummary()
            mailSuggestionStatus = ""
            mailNeedsFullDiskAccess = false
            isSearchingMessages = false
            locationSearchTask?.cancel()
            refreshActions()
            statusText = "Watching \(app.localizedName ?? "frontmost app")"
            return
        }

        if force || currentHint?.signature != hint.signature {
            currentHint = hint
            contacts = resolver.contacts(for: hint)
            selectedContact = contacts.first
            resetSimilarMessagesSummary()
            restoreCachedSuggestions(for: hint)
            isSearchingMessages = false
            statusText = contacts.isEmpty
                ? "No matching contact"
                : "Found \(contacts.count) matching contact\(contacts.count == 1 ? "" : "s")"
            if !messageLocations.isEmpty {
                statusText = "Using cached move suggestions"
            }
            refreshActions()
            refreshMessageLocations(for: hint)
        }
    }

    func select(_ contact: ContactClue) {
        selectedContact = contact
        refreshActions()
    }

    func run(_ action: AppAutomationAction) async {
        let result = await action.run()
        lastResult = result
        scheduleResultClear(for: result)
    }

    private func refreshActions() {
        actions = automation.actions(
            for: selectedContact,
            hint: currentHint,
            messageLocations: messageLocations,
            mailContext: currentHint?.mailContext,
            needsFullDiskAccess: mailNeedsFullDiskAccess
        )
    }

    private func observeApplicationActivation() {
        guard cancellables.isEmpty else {
            return
        }
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .receive(on: RunLoop.main)
            .sink { [weak self] app in
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }
                self?.lastExternalApplication = app
                self?.poll()
            }
            .store(in: &cancellables)
    }

    private func scheduleResultClear(for result: AutomationResult) {
        resultClearTask?.cancel()
        guard !result.isError, result.shouldAutoClear else {
            return
        }

        let resultID = result.id
        resultClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self?.lastResult?.id == resultID else {
                    return
                }
                self?.lastResult = nil
            }
        }
    }

    private func refreshMessageLocations(for hint: AppHint) {
        locationSearchTask?.cancel()
        guard hint.bundleIdentifier == "com.apple.mail",
              let mailContext = hint.mailContext else {
            isSearchingMessages = false
            mailNeedsFullDiskAccess = false
            resetSimilarMessagesSummary()
            return
        }

        let signature = hint.signature
        isSearchingMessages = true
        statusText = "Searching similar messages"
        locationSearchTask = Task { [weak self] in
            guard let self else {
                return
            }
            let quickMessages = await messageRanker.quickSimilarMessages(for: mailContext)
            guard !Task.isCancelled else {
                return
            }
            if !quickMessages.isEmpty {
                await MainActor.run {
                    guard self.currentHint?.signature == signature else {
                        return
                    }
                    self.similarMessages = quickMessages
                    self.statusText = "Refining similar messages"
                }
            }

            for await update in messageRanker.suggestionUpdates(for: mailContext) {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentHint?.signature == signature else {
                        return
                    }
                    self.applySuggestionUpdate(update, hint: hint, mailContext: mailContext, signature: signature)
                }
            }
        }
    }

    private func applySuggestionUpdate(
        _ update: MailSuggestionUpdate,
        hint: AppHint,
        mailContext: MailMessageContext,
        signature: String
    ) {
        let suggestions = update.suggestions
        messageLocations = suggestions.locations
        if !suggestions.messages.isEmpty || update.isFinal {
            similarMessages = suggestions.messages
        }
        mailSuggestionStatus = suggestions.diagnostic
        mailNeedsFullDiskAccess = suggestions.requiresFullDiskAccess
        isSearchingMessages = !update.isFinal
        if update.isFinal {
            cacheSuggestions(suggestions, for: hint)
        }
        actions = automation.actions(
            for: selectedContact,
            hint: currentHint,
            messageLocations: suggestions.locations,
            mailContext: mailContext,
            needsFullDiskAccess: suggestions.requiresFullDiskAccess
        )
        statusText = suggestionStatusText(for: suggestions, isFinal: update.isFinal)

        if update.isFinal {
            summarizeSimilarMessagesIfNeeded(
                suggestions.messages,
                mailContext: mailContext,
                signature: signature
            )
        }
    }

    private func suggestionStatusText(for suggestions: MailSuggestions, isFinal: Bool) -> String {
        if suggestions.messages.isEmpty && suggestions.locations.isEmpty {
            return isFinal ? "No similar messages" : "Searching similar messages"
        }
        let suffix = isFinal ? "" : " so far"
        if suggestions.locations.isEmpty {
            return "\(suggestions.messages.count) similar message\(suggestions.messages.count == 1 ? "" : "s")\(suffix)"
        }
        if suggestions.messages.isEmpty {
            return "\(suggestions.locations.count) move suggestion\(suggestions.locations.count == 1 ? "" : "s")\(suffix)"
        }
        return "\(suggestions.messages.count) similar message\(suggestions.messages.count == 1 ? "" : "s"), \(suggestions.locations.count) move suggestion\(suggestions.locations.count == 1 ? "" : "s")\(suffix)"
    }

    private func restoreCachedSuggestions(for hint: AppHint) {
        messageLocations = []
        similarMessages = []
        resetSimilarMessagesSummary()
        mailSuggestionStatus = ""
        mailNeedsFullDiskAccess = false

        guard let cacheKey = suggestionCacheKey(for: hint),
              let snapshot = hintSuggestionCache[cacheKey],
              Date().timeIntervalSince(snapshot.createdAt) < hintSuggestionCacheLifetime else {
            return
        }

        messageLocations = snapshot.locations
        mailSuggestionStatus = snapshot.diagnostic
        mailNeedsFullDiskAccess = snapshot.requiresFullDiskAccess
    }

    private func cacheSuggestions(_ suggestions: MailSuggestions, for hint: AppHint) {
        guard let cacheKey = suggestionCacheKey(for: hint),
              !suggestions.locations.isEmpty else {
            return
        }

        hintSuggestionCache[cacheKey] = HintSuggestionSnapshot(
            locations: suggestions.locations,
            diagnostic: suggestions.diagnostic,
            requiresFullDiskAccess: suggestions.requiresFullDiskAccess,
            createdAt: Date()
        )
        trimHintSuggestionCacheIfNeeded()
    }

    private func trimHintSuggestionCacheIfNeeded() {
        guard hintSuggestionCache.count > maximumHintSuggestionCacheEntries else {
            return
        }

        for key in hintSuggestionCache
            .sorted(by: { $0.value.createdAt < $1.value.createdAt })
            .prefix(hintSuggestionCache.count - maximumHintSuggestionCacheEntries)
            .map(\.key) {
            hintSuggestionCache.removeValue(forKey: key)
        }
    }

    private func suggestionCacheKey(for hint: AppHint) -> String? {
        let normalizedValue = hint.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedValue.isEmpty else {
            return nil
        }

        return [
            hint.bundleIdentifier,
            hint.kind.rawValue,
            normalizedValue
        ].joined(separator: "\u{1F}")
    }

    private func summarizeSimilarMessagesIfNeeded(
        _ messages: [SimilarMessage],
        mailContext: MailMessageContext,
        signature: String
    ) {
        similarMessagesSummaryTask?.cancel()
        similarMessagesSummary = ""

        guard UserDefaults.standard.bool(forKey: ShelfSettings.useAppleIntelligenceKey),
              !messages.isEmpty else {
            isSummarizingSimilarMessages = false
            return
        }

        isSummarizingSimilarMessages = true
        statusText = "Summarizing similar messages"
        similarMessagesSummaryTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let summary = try await intelligenceAssistant.summarizeSearchHits(
                    mailContext: mailContext,
                    similarMessages: messages
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentHint?.signature == signature else {
                        return
                    }
                    self.similarMessagesSummary = summary
                    self.isSummarizingSimilarMessages = false
                    if !summary.isEmpty {
                        self.statusText = "Summarized \(messages.count) similar message\(messages.count == 1 ? "" : "s")"
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentHint?.signature == signature else {
                        return
                    }
                    self.similarMessagesSummary = ""
                    self.isSummarizingSimilarMessages = false
                    self.statusText = "Apple Intelligence summary unavailable"
                }
            }
        }
    }

    private func resetSimilarMessagesSummary() {
        similarMessagesSummaryTask?.cancel()
        similarMessagesSummary = ""
        isSummarizingSimilarMessages = false
    }
}

private struct HintSuggestionSnapshot {
    var locations: [RankedMessageLocation]
    var diagnostic: String
    var requiresFullDiskAccess: Bool
    var createdAt: Date
}

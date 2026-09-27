import AppKit
import Combine
import Foundation
import DecisionCore
import DecisionFoundationModels
import UniformTypeIdentifiers

@MainActor
final class ContextMonitor: ObservableObject {
    @Published var currentHint: AppHint?
    @Published var contacts: [ContactClue] = []
    @Published var selectedContact: ContactClue?
    @Published var messageLocations: [RankedMessageLocation] = []
    @Published var similarMessages: [SimilarMessage] = []
    @Published var similarMessagesSummary = ""
    @Published var mailSuggestionStatus = ""
    @Published var safariContext: SafariContextSnapshot?
    @Published var actions: [AppAutomationAction] = []
    @Published var lastResult: AutomationResult?
    @Published var isSearchingMessages = false
    @Published var isSummarizingSimilarMessages = false
    @Published var isResolvingSafariContext = false
    @Published var mailNeedsFullDiskAccess = false
    @Published var safariNeedsFullDiskAccess = false
    @Published var contactsPermission: PermissionState = .unknown
    @Published var accessibilityPermission: PermissionState = .unknown
    @Published var statusText = "Starting"
    @Published private(set) var mailDecisionStatus = "Off"
    @Published private(set) var mailDecisionRecords: [MailDecisionRecord] = []

    private let resolver = ContactResolver()
    private let extractors = ContextExtractorRegistry()
    private let slackExtractor = SlackContextExtractor()
    private var slackExtractionTask: Task<Void, Never>?
    private var slackGeneration = UUID()
    private let messageRanker = SpotlightMessageRanker()
    private let safariResolver = SafariContextResolver()
    private let intelligenceAssistant = IntelligenceAssistant()
    private let decisionEngine = DecisionEngine(model: AppleDecisionModel())
    private var mailDecisionTask: Task<Void, Never>?
    private var mailDecisionGeneration = UUID()
    private var actionInteractionStarted = false
    let automation = AutomationRunner()
    private var timer: Timer?
    private var locationSearchTask: Task<Void, Never>?
    private var safariResolutionTask: Task<Void, Never>?
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

        if app.bundleIdentifier == SlackContextExtractor.bundleIdentifier {
            refreshSlackContext(from: app, force: force)
            return
        }
        slackGeneration = UUID()
        slackExtractionTask?.cancel()
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
            resetSafariContext()
            isSearchingMessages = false
            locationSearchTask?.cancel()
            resetMailDecision()
            refreshActions()
            statusText = "Watching \(app.localizedName ?? "frontmost app")"
            return
        }

        applyHint(hint, force: force)
    }

    private func applyHint(_ hint: AppHint, force: Bool) {
        if force || currentHint?.signature != hint.signature {
            automation.invalidateMailBindings()
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
            refreshSafariContext(for: hint)
            if let slack = hint.slackContext { statusText = slack.diagnostic }
        }
    }

    private func refreshSlackContext(from app: NSRunningApplication, force: Bool) {
        if currentHint?.bundleIdentifier != SlackContextExtractor.bundleIdentifier {
            applyHint(SlackContext(isPartial: true, diagnostic: "Reading Slack context").appHint(), force: true)
        }
        // At most one read is admitted, including while a canceled AX call is finishing.
        guard slackExtractionTask == nil else { return }
        let generation = slackGeneration
        let pid = app.processIdentifier
        slackExtractionTask = Task { [weak self, slackExtractor] in
            let hint = await slackExtractor.extract(processID: pid, force: force)
            guard let self else { return }
            self.slackExtractionTask = nil
            guard !Task.isCancelled, self.slackGeneration == generation,
                  self.lastExternalApplication?.processIdentifier == pid, let hint else { return }
            let front = NSWorkspace.shared.frontmostApplication
            guard front?.processIdentifier == pid || front?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self.applyHint(hint, force: force)
        }
    }

    func select(_ contact: ContactClue) {
        selectedContact = contact
        refreshActions()
    }

    func run(_ action: AppAutomationAction) async {
        beginActionInteraction()
        let result = await action.run()
        lastResult = result
        scheduleResultClear(for: result)
    }

    private func refreshActions() {
        actions = automation.actions(
            for: selectedContact,
            hint: currentHint,
            messageLocations: messageLocations,
            mailContext: currentHint?.mailContext
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
        resetMailDecision()
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

    private func refreshSafariContext(for hint: AppHint) {
        safariResolutionTask?.cancel()
        guard hint.bundleIdentifier == "com.apple.Safari",
              let url = hint.url else {
            resetSafariContext()
            return
        }

        let signature = hint.signature
        safariContext = SafariContextSnapshot()
        safariNeedsFullDiskAccess = false
        isResolvingSafariContext = true
        statusText = "Checking Safari context"

        safariResolutionTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await update in safariResolver.updates(
                for: url,
                title: hint.title,
                observedAt: hint.createdAt
            ) {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.currentHint?.signature == signature else {
                        return
                    }
                    self.safariContext = update.snapshot
                    self.safariNeedsFullDiskAccess = update.snapshot.requiresFullDiskAccess
                    self.isResolvingSafariContext = !update.isFinal
                    self.statusText = update.snapshot.diagnostic
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
        // Messages and destinations are one snapshot, including the initial cache result.
        similarMessages = suggestions.messages
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
            mailContext: mailContext
        )
        statusText = suggestionStatusText(for: suggestions, isFinal: update.isFinal)

        if update.isFinal {
            assessMailFolders(suggestions.decisionEvidence, context: mailContext)
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
              mailDecisionMode == .off,
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

    private func resetSafariContext() {
        safariResolutionTask?.cancel()
        safariContext = nil
        safariNeedsFullDiskAccess = false
        isResolvingSafariContext = false
    }

    func beginActionInteraction() { actionInteractionStarted = true }

    func exportMailDecisionDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "shelf-shadow-assessments.json"
        let records = mailDecisionRecords
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try DecisionJSON.encode(records).write(to: url, options: .atomic) }
            catch { self?.mailDecisionStatus = "Could not export assessments" }
        }
    }

    private var mailDecisionMode: MailDecisionMode {
        MailDecisionMode(rawValue: UserDefaults.standard.string(forKey: ShelfSettings.mailDecisionModeKey) ?? "off") ?? .off
    }

    private func resetMailDecision() {
        mailDecisionTask?.cancel()
        mailDecisionTask = nil
        mailDecisionGeneration = UUID()
        actionInteractionStarted = false
        mailDecisionStatus = mailDecisionMode == .off ? "Off" : "Waiting for Mail suggestions"
    }

    private func assessMailFolders(_ folders: [MailFolderEvidence], context: MailMessageContext) {
        let mode = mailDecisionMode
        guard mode != .off else { return }
        guard mode != .rerank || MailDecisionAdapter.rankingApproved else {
            mailDecisionStatus = "Reranking awaits evaluation"
            return
        }
        let generation = mailDecisionGeneration
        mailDecisionStatus = "Assessing in shadow mode"
        mailDecisionTask = Task { [weak self] in
            guard let self else { return }
            let start = ContinuousClock.now
            var captured: MailDecisionSnapshot?
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try MailDecisionAdapter.snapshot(context: context, folders: folders, generation: generation)
                }.value
                captured = snapshot
                try Task.checkCancellation()
                let response = try await decisionEngine.decide(snapshot.request, timeout: .seconds(8))
                guard !Task.isCancelled, generation == mailDecisionGeneration,
                      currentHint?.mailContext?.selectionSignature == snapshot.selectionSignature,
                      mode == mailDecisionMode else {
                    recordDecision(evaluation: .init(outcome: "stale_result", response: nil, fullRanking: nil,
                                                     protectedRanking: nil, displayed: []),
                                   snapshot: snapshot, generation: generation, start: start)
                    return
                }
                let evaluation = MailDecisionAdapter.evaluate(response, snapshot: snapshot, mode: mode,
                                                              activeGeneration: mailDecisionGeneration,
                                                              selectionSignature: context.selectionSignature,
                                                              interactionStarted: actionInteractionStarted)
                recordDecision(evaluation: evaluation, snapshot: snapshot, generation: generation, start: start)
                if evaluation.outcome == "reranked" {
                    messageLocations = evaluation.displayed
                    refreshActions()
                }
                mailDecisionStatus = evaluation.outcome == "shadow_ok" ? "Shadow assessment complete" : "Baseline retained: \(evaluation.outcome)"
            } catch {
                let failure = error as? DecisionFailure ?? (error is CancellationError
                    ? DecisionFailure(.cancelled, "caller_cancelled") : DecisionFailure(.generationFailed, "adapter_error"))
                let stale = generation != mailDecisionGeneration
                let outcome = stale ? "stale_result" : "\(failure.code.rawValue):\(failure.reason)"
                recordDecision(evaluation: .init(outcome: outcome, response: nil, fullRanking: nil,
                                                protectedRanking: nil, displayed: messageLocations),
                               snapshot: captured, generation: generation, start: start)
                guard !Task.isCancelled, !stale else { return }
                mailDecisionStatus = "Baseline retained: \(failure.reason)"
            }
        }
    }

    private func recordDecision(evaluation: MailDecisionEvaluation, snapshot: MailDecisionSnapshot?,
                                generation: UUID, start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now).components
        mailDecisionRecords.append(MailDecisionRecord(
            requestID: generation.uuidString, outcome: evaluation.outcome,
            elapsedMilliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
            candidateCount: snapshot?.shortlist.count ?? 0, omittedCandidates: snapshot?.omittedCandidates ?? 0,
            response: evaluation.response, fullRanking: evaluation.fullRanking, protectedRanking: evaluation.protectedRanking
        ))
        mailDecisionRecords = Array(mailDecisionRecords.suffix(100))
    }
}

private struct HintSuggestionSnapshot {
    var locations: [RankedMessageLocation]
    var diagnostic: String
    var requiresFullDiskAccess: Bool
    var createdAt: Date
}

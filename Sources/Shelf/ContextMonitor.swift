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
    @Published var mailSuggestionStatus = ""
    @Published var actions: [AppAutomationAction] = []
    @Published var lastResult: AutomationResult?
    @Published var isSearchingMessages = false
    @Published var mailNeedsFullDiskAccess = false
    @Published var contactsPermission: PermissionState = .unknown
    @Published var accessibilityPermission: PermissionState = .unknown
    @Published var statusText = "Starting"

    private let resolver = ContactResolver()
    private let extractors = ContextExtractorRegistry()
    private let messageRanker = SpotlightMessageRanker()
    let automation = AutomationRunner()
    private var timer: Timer?
    private var locationSearchTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()

    func start() async {
        contactsPermission = resolver.permissionState
        accessibilityPermission = automation.accessibilityPermissionState

        if contactsPermission == .notDetermined {
            contactsPermission = await resolver.requestAccessIfNeeded()
        }

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
            messageLocations = []
            similarMessages = []
            mailSuggestionStatus = ""
            mailNeedsFullDiskAccess = false
            isSearchingMessages = false
            statusText = contacts.isEmpty
                ? "No matching contact"
                : "Found \(contacts.count) matching contact\(contacts.count == 1 ? "" : "s")"
            refreshActions()
            refreshMessageLocations(for: hint)
        }
    }

    func select(_ contact: ContactClue) {
        selectedContact = contact
        refreshActions()
    }

    func run(_ action: AppAutomationAction) async {
        lastResult = await action.run()
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

    private func refreshMessageLocations(for hint: AppHint) {
        locationSearchTask?.cancel()
        guard hint.bundleIdentifier == "com.apple.mail",
              let mailContext = hint.mailContext else {
            isSearchingMessages = false
            mailNeedsFullDiskAccess = false
            return
        }

        let signature = hint.signature
        isSearchingMessages = true
        statusText = "Searching similar messages"
        locationSearchTask = Task { [weak self] in
            guard let self else {
                return
            }
            let suggestions = await messageRanker.suggestions(for: mailContext)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self.currentHint?.signature == signature else {
                    return
                }
                self.messageLocations = suggestions.locations
                self.similarMessages = suggestions.messages
                self.mailSuggestionStatus = suggestions.diagnostic
                self.mailNeedsFullDiskAccess = suggestions.requiresFullDiskAccess
                self.isSearchingMessages = false
                if suggestions.messages.isEmpty && suggestions.locations.isEmpty {
                    self.statusText = "No similar messages"
                } else {
                    self.statusText = "\(suggestions.messages.count) similar message\(suggestions.messages.count == 1 ? "" : "s")"
                }
                self.refreshActions()
            }
        }
    }
}

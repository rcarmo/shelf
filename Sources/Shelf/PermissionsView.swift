import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var monitor: ContextMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title3.weight(.semibold))

            PermissionControl(
                title: "Contacts",
                state: monitor.contactsPermission,
                explanation: "Needed to match app hints to people and organizations in Contacts.",
                buttonTitle: "Allow Contacts",
                systemImage: "person.crop.circle"
            ) {
                Task {
                    await monitor.requestContactsAccess()
                }
            }

            PermissionControl(
                title: "Accessibility",
                state: monitor.accessibilityPermission,
                explanation: "Used only as a fallback to read focused window titles when an app has no dedicated extractor.",
                buttonTitle: "Open Prompt",
                systemImage: "figure.stand"
            ) {
                monitor.requestAccessibilityAccess()
            }
        }
    }
}

private struct PermissionControl: View {
    var title: String
    var state: PermissionState
    var explanation: String
    var buttonTitle: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Text(state.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state == .allowed ? .green : .orange)
            }
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: action) {
                Label(buttonTitle, systemImage: "lock.open")
            }
            .disabled(state == .allowed)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

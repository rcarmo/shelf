import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var monitor: ContextMonitor
    @AppStorage(ShelfSettings.contentBaseFontSizeKey) private var contentBaseFontSize = ShelfSettings.defaultContentBaseFontSize
    @AppStorage(ShelfSettings.useAppleIntelligenceKey) private var useAppleIntelligence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.title3.weight(.semibold))

            FontSizeControl(fontSize: $contentBaseFontSize)

            Text("Intelligence")
                .font(.title3.weight(.semibold))

            AppleIntelligenceControl(useAppleIntelligence: $useAppleIntelligence)

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
        .onChange(of: contentBaseFontSize) { newValue in
            contentBaseFontSize = ShelfSettings.clampedContentBaseFontSize(newValue)
        }
    }
}

private struct AppleIntelligenceControl: View {
    @Binding var useAppleIntelligence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $useAppleIntelligence) {
                Label("Use Apple Intelligence", systemImage: "sparkles")
                    .font(.headline)
            }
            Text("Generate a short summary of similar Mail search hits when they are found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FontSizeControl: View {
    @Binding var fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Content Font Size", systemImage: "textformat.size")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    TextField("Size", value: $fontSize, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 54)
                    Text("pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(
                        "",
                        value: $fontSize,
                        in: ShelfSettings.minimumContentBaseFontSize...ShelfSettings.maximumContentBaseFontSize,
                        step: 1
                    )
                    .labelsHidden()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

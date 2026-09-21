import SwiftUI

/// Accessible host health and recovery surface. Status is an inspection query;
/// restart goes through the explicit host recovery RemoteIntent target.
struct RecoveryFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemoteIntentRouter.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let profile: HostProfile
    @State private var session = HostRecoverySession()
    @State private var status: NvdaRecoveryStatus?
    @State private var statusMessage = "Not checked"
    @State private var isWorking = false

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Host", value: status == nil ? statusMessage : "Reachable")
                LabeledContent("Accessibility", value: accessibilityLabel)
                LabeledContent("Recovery", value: recoveryLabel)
            }
            Section("Actions") {
                Button("Refresh Status", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isWorking)
                    .accessibilityHint("Checks host health without restarting accessibility.")
                Button("Restart Accessibility", systemImage: "arrow.counterclockwise") { restart() }
                    .disabled(!RecoveryActionPolicy.canRestart(
                        platform: profile.platform,
                        status: status,
                        isWorking: isWorking
                    ))
                    .accessibilityHint("Requests a restart. Refresh status afterward to confirm whether accessibility is running.")
            }
        }
        .navigationTitle("Recovery — \(profile.displayName)")
        .onAppear { configure() }
    }

    private var accessibilityLabel: String {
        guard let status else { return profile.platform == .windows ? "NVDA unknown" : "Unknown" }
        return status.nvdaRunning ? "NVDA, Running" : "NVDA, Not Running"
    }

    private var recoveryLabel: String {
        guard profile.platform == .windows else { return "Unavailable" }
        guard let status else { return "Unknown" }
        return status.recoveryTaskReady ? "Ready" : "Setup Required"
    }

    private func configure() {
        session.configure(profile: profile, credentials: settings.credentials(for: profile))
        router.register(HostRecoveryIntentTarget(controller: session, id: HostRecoveryIntentTarget.id(for: profile)))
        refresh()
    }

    private func refresh() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                status = try await session.status()
                statusMessage = "Reachable"
            } catch {
                status = nil
                statusMessage = "Unreachable"
            }
        }
    }

    private func restart() {
        isWorking = true
        Task {
            defer { isWorking = false }
            let result = await router.route(.recovery(.restartAccessibility), to: HostRecoveryIntentTarget.id(for: profile))
            switch result {
            case .performed:
                announce("Accessibility restart requested. Refresh status to confirm recovery.")
            case .unsupported:
                announce("Accessibility recovery is unavailable.")
            case .unavailable(let message), .failed(let message):
                announce("Accessibility restart could not be requested. \(message)")
            }
        }
    }

    private func announce(_ message: String) {
        if voiceOverEnabled { AccessibilityNotification.Announcement(message).post() }
        statusMessage = message
    }
}


enum RecoveryActionPolicy {
    static func canRestart(
        platform: HostPlatform,
        status: NvdaRecoveryStatus?,
        isWorking: Bool
    ) -> Bool {
        platform == .windows && status?.recoveryTaskReady == true && !isWorking
    }
}

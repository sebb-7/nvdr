import SwiftUI

/// App-level entry point that owns the terminal feature while it is visible.
struct SSHTerminalFeatureView: View {
    @Environment(AppSettings.self) private var settings
    let host: SSHTerminalHost
    let profile: HostProfile
    let ownsLifecycle: Bool
    @State private var snapshot: AccessibleConversationSnapshot?
    @State private var hasStarted = false

    init(host: SSHTerminalHost, profile: HostProfile, ownsLifecycle: Bool = true) {
        self.host = host
        self.profile = profile
        self.ownsLifecycle = ownsLifecycle
    }

    var body: some View {
        TerminalPresentationView(presentation: host.presentation) { snapshot in
            self.snapshot = snapshot
        }
        .navigationDestination(item: $snapshot) { snapshot in
            OutputSnapshotView(snapshot: snapshot)
        }
        .onAppear {
            host.presentation.setLiveOutputSnapshotInspecting(snapshot != nil)
        }
        .onChange(of: snapshot?.id) { _, snapshotID in
            host.presentation.setLiveOutputSnapshotInspecting(snapshotID != nil)
        }
        .task {
            guard ownsLifecycle, !hasStarted else { return }
            hasStarted = true
            await host.start(settings: settings, profile: profile)
        }
        .onDisappear {
            // Pushing a Snapshot hides this view while the terminal must stay
            // alive. A real Back navigation has no active Snapshot.
            guard ownsLifecycle, snapshot == nil else { return }
            Task {
                await host.close()
            }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close terminal", systemImage: "xmark") {
                        Task {
                            await host.close()
                        }
                    }
                    .accessibilityIdentifier("close-ssh-terminal")
                }
            }
    }
}

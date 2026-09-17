import SwiftUI
import UIKit

/// Presents a manager-owned terminal. The manager owns lifetime; Back, tab
/// changes, and Snapshots must not close the session.
struct SSHTerminalFeatureView: View {
    @Environment(TerminalSessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession
    @State private var snapshot: AccessibleConversationSnapshot?

    var body: some View {
        TerminalPresentationView(presentation: session.host.presentation) { snapshot in
            self.snapshot = snapshot
        }
        .navigationTitle(session.title)
        .navigationDestination(item: $snapshot) { snapshot in
            OutputSnapshotView(snapshot: snapshot)
        }
        // A terminal is a full destination inside a root tab. Hiding the
        // platform tab bar here keeps it out of the accessibility hierarchy;
        // SwiftUI restores it automatically when this destination is popped.
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            session.host.presentation.setLiveOutputSnapshotInspecting(snapshot != nil)
            manager.present(session.id)
            manager.setTerminalInteractionActive(true)
        }
        .onChange(of: snapshot?.id) { _, snapshotID in
            session.host.presentation.setLiveOutputSnapshotInspecting(snapshotID != nil)
        }
        .onDisappear {
            if snapshot == nil {
                session.host.presentation.endEditingSession()
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
                manager.clearPresentedSession(if: session.id)
                manager.setTerminalInteractionActive(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close terminal", systemImage: "xmark") {
                    Task {
                        await manager.close(session.id)
                        dismiss()
                    }
                }
                .accessibilityIdentifier("close-ssh-terminal")
            }
        }
    }
}

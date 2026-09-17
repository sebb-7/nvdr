import SwiftUI

/// A frozen, document-like view of accessible conversation content.
struct OutputSnapshotView: View {
    @Environment(InteractionFeedback.self) private var interactionFeedback
    let snapshot: AccessibleConversationSnapshot

    var body: some View {
        ScrollView {
            Text(snapshot.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Output Snapshot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Copy All", systemImage: "doc.on.doc") {
                    copyAll()
                }
            }
        }
        .accessibilityAction(named: ConversationAccessibilityAction.copyAll.name) {
            copyAll()
        }
        .accessibilityIdentifier("output-snapshot-\(snapshot.id)")
    }

    private func copyAll() {
        AppClipboard.copy(ConversationAccessibilityActionPolicy.copyAllText(for: snapshot))
        interactionFeedback.play(.copied)
        AccessibilityNotification.Announcement("Copied").post()
    }
}

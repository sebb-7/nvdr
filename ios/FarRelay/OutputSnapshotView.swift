import SwiftUI

/// A frozen, document-like view of accessible conversation content.
struct OutputSnapshotView: View {
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
        .accessibilityIdentifier("output-snapshot-\(snapshot.id)")
    }
}

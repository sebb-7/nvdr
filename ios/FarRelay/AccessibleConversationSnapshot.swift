import Foundation

/// An immutable, provider-neutral inspection value captured from one
/// accessible conversation entry.
///
/// The source identifier preserves provenance without coupling the Snapshot
/// to SSH, terminal parsing, or a particular conversation provider.
struct AccessibleConversationSnapshot: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let sourceEntryID: UUID
    let text: String

    init(
        id: UUID = UUID(),
        sourceEntryID: UUID,
        text: String
    ) {
        self.id = id
        self.sourceEntryID = sourceEntryID
        self.text = text
    }
}

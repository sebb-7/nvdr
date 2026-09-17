import SwiftUI
import UIKit

/// A UIKit accessibility boundary for one terminal conversation entry. The
/// visual label may retain terminal newlines; VoiceOver receives only the
/// flattened label assigned to this single native element.
struct NativeTerminalConversationRow: UIViewRepresentable {
    let entry: AccessibleConversationEntry
    let accessibilityText: String
    let actions: [ConversationAccessibilityAction]
    let onAction: (ConversationAccessibilityAction) -> Void
    let onAccessibilityFocusChanged: (Bool) -> Void
    let onViewConfigured: (TerminalConversationRowView) -> Void

    init(
        entry: AccessibleConversationEntry,
        accessibilityText: String,
        actions: [ConversationAccessibilityAction],
        onAction: @escaping (ConversationAccessibilityAction) -> Void,
        onAccessibilityFocusChanged: @escaping (Bool) -> Void,
        onViewConfigured: @escaping (TerminalConversationRowView) -> Void = { _ in }
    ) {
        self.entry = entry
        self.accessibilityText = accessibilityText
        self.actions = actions
        self.onAction = onAction
        self.onAccessibilityFocusChanged = onAccessibilityFocusChanged
        self.onViewConfigured = onViewConfigured
    }

    func makeUIView(context: Context) -> TerminalConversationRowView {
        let view = TerminalConversationRowView()
        view.configure(
            entry: entry,
            accessibilityText: accessibilityText,
            actions: actions,
            onAction: onAction,
            onAccessibilityFocusChanged: onAccessibilityFocusChanged,
            onViewConfigured: onViewConfigured
        )
        return view
    }

    func updateUIView(_ view: TerminalConversationRowView, context: Context) {
        view.configure(
            entry: entry,
            accessibilityText: accessibilityText,
            actions: actions,
            onAction: onAction,
            onAccessibilityFocusChanged: onAccessibilityFocusChanged,
            onViewConfigured: onViewConfigured
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TerminalConversationRowView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: .greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}

final class TerminalConversationRowView: UIView {
    private let visualLabel = UILabel()
    private var onAction: ((ConversationAccessibilityAction) -> Void)?
    private var onAccessibilityFocusChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true

        visualLabel.numberOfLines = 0
        visualLabel.lineBreakMode = .byWordWrapping
        visualLabel.translatesAutoresizingMaskIntoConstraints = false
        visualLabel.isAccessibilityElement = false
        addSubview(visualLabel)
        NSLayoutConstraint.activate([
            visualLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            visualLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            visualLabel.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            visualLabel.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        entry: AccessibleConversationEntry,
        accessibilityText: String,
        actions: [ConversationAccessibilityAction],
        onAction: @escaping (ConversationAccessibilityAction) -> Void,
        onAccessibilityFocusChanged: @escaping (Bool) -> Void,
        onViewConfigured: @escaping (TerminalConversationRowView) -> Void = { _ in }
    ) {
        visualLabel.text = entry.presentationText
        accessibilityLabel = accessibilityText
        accessibilityIdentifier = entry.isCommand
            ? "terminal-command-\(entry.id)"
            : "terminal-content-\(entry.id)"
        accessibilityTraits = entry.isCommand ? [.staticText, .header] : .staticText
        accessibilityCustomActions = actions.map { action in
            UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                self?.onAction?(action)
                return true
            }
        }
        self.onAction = onAction
        self.onAccessibilityFocusChanged = onAccessibilityFocusChanged
        onViewConfigured(self)
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onAccessibilityFocusChanged?(true)
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        onAccessibilityFocusChanged?(false)
    }
}

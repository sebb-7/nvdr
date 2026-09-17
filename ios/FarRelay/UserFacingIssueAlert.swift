import SwiftUI

struct UserFacingIssueAlertModifier: ViewModifier {
    @Binding var issue: UserFacingIssue?
    var onRetry: ((UserFacingIssue) -> Void)?

    func body(content: Content) -> some View {
        content.alert(
            issue?.title ?? "",
            isPresented: Binding(
                get: { issue != nil },
                set: { if !$0 { issue = nil } }
            ),
            presenting: issue
        ) { presented in
            if presented.retry != nil, let onRetry {
                Button("Retry") { onRetry(presented) }
            }
            Button("Copy Details") {
                AppClipboard.copy(presented.diagnosticText)
            }
            Button("Dismiss", role: .cancel) {
                issue = nil
            }
        } message: { presented in
            Text(presented.message)
        }
    }
}

extension View {
    func userFacingIssueAlert(
        _ issue: Binding<UserFacingIssue?>,
        onRetry: ((UserFacingIssue) -> Void)? = nil
    ) -> some View {
        modifier(UserFacingIssueAlertModifier(issue: issue, onRetry: onRetry))
    }
}

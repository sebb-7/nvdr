import SwiftUI

extension View {
    func namedAccessibilityActions<Action>(
        _ actions: [Action],
        name: KeyPath<Action, String>,
        perform: @escaping (Action) -> Void
    ) -> some View {
        namedAccessibilityActions(actions, name: { $0[keyPath: name] }, perform: perform)
    }

    func namedAccessibilityActions<Action>(
        _ actions: [Action],
        name: @escaping (Action) -> String,
        perform: @escaping (Action) -> Void
    ) -> some View {
        modifier(NamedAccessibilityActionsModifier(actions: actions, name: name, perform: perform))
    }
}

private struct NamedAccessibilityActionsModifier<Action>: ViewModifier {
    let actions: [Action]
    let name: (Action) -> String
    let perform: (Action) -> Void

    func body(content: Content) -> some View {
        switch actions.count {
        case 0:
            content
        case 1:
            content.accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
        case 2:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
        case 3:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
        case 4:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
                .accessibilityAction(named: name(actions[3])) { perform(actions[3]) }
        case 5:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
                .accessibilityAction(named: name(actions[3])) { perform(actions[3]) }
                .accessibilityAction(named: name(actions[4])) { perform(actions[4]) }
        case 6:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
                .accessibilityAction(named: name(actions[3])) { perform(actions[3]) }
                .accessibilityAction(named: name(actions[4])) { perform(actions[4]) }
                .accessibilityAction(named: name(actions[5])) { perform(actions[5]) }
        case 7:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
                .accessibilityAction(named: name(actions[3])) { perform(actions[3]) }
                .accessibilityAction(named: name(actions[4])) { perform(actions[4]) }
                .accessibilityAction(named: name(actions[5])) { perform(actions[5]) }
                .accessibilityAction(named: name(actions[6])) { perform(actions[6]) }
        case 8:
            content
                .accessibilityAction(named: name(actions[0])) { perform(actions[0]) }
                .accessibilityAction(named: name(actions[1])) { perform(actions[1]) }
                .accessibilityAction(named: name(actions[2])) { perform(actions[2]) }
                .accessibilityAction(named: name(actions[3])) { perform(actions[3]) }
                .accessibilityAction(named: name(actions[4])) { perform(actions[4]) }
                .accessibilityAction(named: name(actions[5])) { perform(actions[5]) }
                .accessibilityAction(named: name(actions[6])) { perform(actions[6]) }
                .accessibilityAction(named: name(actions[7])) { perform(actions[7]) }
        default:
            preconditionFailure("A focused object cannot expose more than eight named accessibility actions.")
        }
    }
}

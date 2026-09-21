import SwiftUI

/// VoiceOver-first controller mapping and profile editor.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Profiles") {
                NavigationLink("Profiles") {
                    ControllerProfilesView()
                }
                Text("Active profile: \(mappings.activeProfile.name)")
                    .foregroundStyle(.secondary)
            }

            Section("Quick Bar") {
                NavigationLink("Edit Quick Bar") {
                    ControllerQuickBarView()
                }
                Text("\(mappings.draftProfile.quickBar.count) actions in \(mappings.draftProfile.name).")
                    .foregroundStyle(.secondary)
            }

            Section("Quick Navigation") {
                NavigationLink("Edit Rotor Order") {
                    ControllerRotorOrderView()
                }
                Text("\(mappings.draftProfile.quickNavigationOrder.count) rotor sections.")
                    .foregroundStyle(.secondary)
            }

            Section("How it works") {
                Text("Base mappings are always active. Extended mappings are used through any button assigned to Layer: hold it for momentary Extended, tap it for one Extended action, or double-tap it to lock Extended until you press the Layer button again.")
                Text("Quick Navigation uses a horizontal swipe on the DualSense touchpad as the rotor. Quick Bar, Profiles, and Editing are local sections. Editing provides Select All, Copy, Cut, Paste, Undo, and Redo. Headings, Links, Form controls, Edit fields, Buttons, Landmarks, Tables, and Lists use NVDA Browse Mode shortcuts. Right-stick up or down moves within the selected section.")
            }

            recommendedLayoutSection()
            mappingSection(title: "Base", layerID: nil)
            ForEach(mappings.draftProfile.layers) { layer in
                mappingSection(title: layer.name, layerID: layer.id)
            }

            if mappings.hasUnsavedChanges {
                Section("Unsaved changes") {
                    Button("Discard Unsaved Changes", role: .destructive) {
                        mappings.discardDraft()
                    }
                }
            }

            if controllerAdapter.controllerHasRemappedElements {
                Section("Controller") {
                    Text("This controller follows its current iOS button remapping.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Controller Mapping")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save Mappings") {
                    mappings.saveDraft()
                    dismiss()
                    DispatchQueue.main.async {
                        AccessibilityNotification.Announcement(
                            "Controller mappings saved. Settings."
                        ).post()
                    }
                }
                .accessibilityHint("Saves the edited profile, Quick Bar, and controller bindings.")
            }
        }
        .onAppear {
            _ = mappings.beginEditing(profileID: mappings.activeProfileID)
        }
        .onChange(of: mappings.activeProfileID) { _, newID in
            if !mappings.hasUnsavedChanges {
                _ = mappings.beginEditing(profileID: newID)
            }
        }
    }

    @ViewBuilder
    private func recommendedLayoutSection() -> some View {
        Section("Recommended layout") {
            Button("Fill Unassigned with Recommended Layout") {
                let count = mappings.fillUnassignedWithRecommendedLayout()
                let message = count == 0
                    ? "Recommended layout is already filled."
                    : "\(count) unassigned controller mappings filled. Review them, then choose Save Mappings."
                AccessibilityNotification.Announcement(message).post()
            }
            .accessibilityHint("Adds recommended Base and Extended mappings without replacing an existing mapping.")
            Text("This never overwrites an existing mapping. New defaults include Home for Next Profile, Extended plus Home for Previous Profile, and Extended plus Cross for Repeat Last Quick Bar Action.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func mappingSection(title: String, layerID: String?) -> some View {
        Section(title) {
            ForEach(ControllerInput.allCases) { input in
                NavigationLink {
                    ControllerBindingEditor(input: input, layerID: layerID)
                } label: {
                    VStack(alignment: .leading) {
                        Text(input.label)
                        Text(mappings.draftProfile.action(for: input, layerID: layerID)?.displayLabel ?? "Unassigned")
                            .foregroundStyle(.secondary)
                        if layerID == nil {
                            Text(availability(for: input))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func availability(for input: ControllerInput) -> String {
        guard controllerAdapter.connectedControllerName != nil else {
            return "No controller connected — mapping can still be edited"
        }
        return controllerAdapter.availableInputs.contains(input)
            ? "Available on this controller"
            : "Unavailable on this controller"
    }
}

struct ControllerProfilesView: View {
    @Environment(ControllerMappingSettings.self) private var mappings

    var body: some View {
        List {
            Section("Profiles") {
                ForEach(mappings.profiles) { profile in
                    NavigationLink {
                        ControllerProfileEditorView(profileID: profile.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            if profile.id == mappings.activeProfileID {
                                Text("Active profile")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .disabled(mappings.hasUnsavedChanges && mappings.editingProfileID != profile.id)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        _ = mappings.deleteProfile(id: mappings.profiles[index].id)
                    }
                }
                .onMove(perform: mappings.moveProfiles)
            }

            Section {
                Button("Add Profile") {
                    let savedExistingDraft = mappings.hasUnsavedChanges
                    let id = mappings.createProfileForEditing()
                    let profile = mappings.profiles.first(where: { $0.id == id })
                    let prefix = savedExistingDraft ? "Saved current profile. " : ""
                    AccessibilityNotification.Announcement(
                        "\(prefix)Added \(profile?.name ?? "profile"). Ready to edit."
                    ).post()
                }
                Text("Profile order is also the order used by Next Profile and Previous Profile.")
                    .foregroundStyle(.secondary)
                if mappings.profiles.count == 1 {
                    Text("At least one profile is always kept.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Profiles")
        .toolbar { EditButton() }
    }
}

struct ControllerProfileEditorView: View {
    let profileID: UUID

    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Profile") {
                TextField(
                    "Profile name",
                    text: Binding(
                        get: { mappings.draftProfile.name },
                        set: { mappings.renameDraftProfile($0) }
                    )
                )
                if profileID == mappings.activeProfileID {
                    Text("Active profile")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Make Active Profile") {
                        mappings.saveDraft()
                        if let name = mappings.activateProfile(id: profileID) {
                            AccessibilityNotification.Announcement("Profile: \(name)").post()
                        }
                    }
                }
            }

            Section("Quick Bar") {
                NavigationLink("Edit Quick Bar") { ControllerQuickBarView() }
                Text("\(mappings.draftProfile.quickBar.count) actions")
                    .foregroundStyle(.secondary)
            }

            Section("Quick Navigation") {
                NavigationLink("Edit Rotor Order") { ControllerRotorOrderView() }
                Text("\(mappings.draftProfile.quickNavigationOrder.count) rotor sections")
                    .foregroundStyle(.secondary)
            }

            Section("Recommended layout") {
                Button("Fill Unassigned with Recommended Layout") {
                    let count = mappings.fillUnassignedWithRecommendedLayout()
                    AccessibilityNotification.Announcement(
                        count == 0 ? "Recommended layout is already filled." : "\(count) mappings filled."
                    ).post()
                }
            }

            profileMappingSection(title: "Base", layerID: nil)
            ForEach(mappings.draftProfile.layers) { layer in
                profileMappingSection(title: layer.name, layerID: layer.id)
            }

            if mappings.hasUnsavedChanges {
                Section("Unsaved changes") {
                    Button("Discard Unsaved Changes", role: .destructive) {
                        mappings.discardDraft()
                    }
                }
            }
        }
        .navigationTitle(mappings.draftProfile.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save Profile") {
                    mappings.saveDraft()
                    dismiss()
                }
            }
        }
        .onAppear {
            _ = mappings.beginEditing(profileID: profileID)
        }
    }

    @ViewBuilder
    private func profileMappingSection(title: String, layerID: String?) -> some View {
        Section(title) {
            ForEach(ControllerInput.allCases) { input in
                NavigationLink {
                    ControllerBindingEditor(input: input, layerID: layerID)
                } label: {
                    VStack(alignment: .leading) {
                        Text(input.label)
                        Text(mappings.draftProfile.action(for: input, layerID: layerID)?.displayLabel ?? "Unassigned")
                            .foregroundStyle(.secondary)
                        if layerID == nil {
                            Text(controllerAdapter.connectedControllerName == nil
                                 ? "No controller connected — mapping can still be edited"
                                 : (controllerAdapter.availableInputs.contains(input)
                                    ? "Available on this controller"
                                    : "Unavailable on this controller"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct ControllerQuickBarView: View {
    @Environment(ControllerMappingSettings.self) private var mappings

    var body: some View {
        List {
            Section("Actions") {
                ForEach(mappings.draftProfile.quickBar) { entry in
                    NavigationLink {
                        QuickBarEntryEditor(entryID: entry.id)
                    } label: {
                        Text(entry.label)
                    }
                    .accessibilityAction(named: Text("Move Up")) {
                        announceQuickBarMove(
                            entry,
                            index: mappings.moveQuickBarEntry(id: entry.id, direction: -1),
                            boundary: "is already first"
                        )
                    }
                    .accessibilityAction(named: Text("Move Down")) {
                        announceQuickBarMove(
                            entry,
                            index: mappings.moveQuickBarEntry(id: entry.id, direction: 1),
                            boundary: "is already last"
                        )
                    }
                    .accessibilityAction(named: Text("Move to Top")) {
                        announceQuickBarMove(
                            entry,
                            index: mappings.moveQuickBarEntryToStart(id: entry.id),
                            boundary: "is already first"
                        )
                    }
                    .accessibilityAction(named: Text("Move to Bottom")) {
                        announceQuickBarMove(
                            entry,
                            index: mappings.moveQuickBarEntryToEnd(id: entry.id),
                            boundary: "is already last"
                        )
                    }
                }
                .onDelete(perform: mappings.deleteQuickBarEntries)
                .onMove(perform: mappings.moveQuickBarEntries)
            }

            Section {
                Button("Add Action") {
                    _ = mappings.addQuickBarEntry()
                }
                Button("Restore Recommended Quick Bar") {
                    mappings.restoreRecommendedQuickBar()
                }
                Text("Each action supports Move Up, Move Down, Move to Top, and Move to Bottom VoiceOver actions. Quick Bar uses the same action model as controller mapping. Layer and Quick Navigation control actions are intentionally excluded because they would create ambiguous local state.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Quick Bar")
        .toolbar { EditButton() }
    }

    private func announceQuickBarMove(_ entry: QuickBarEntry, index: Int?, boundary: String) {
        let message: String
        if let index {
            message = "\(entry.label) moved to position \(index + 1) of \(mappings.draftProfile.quickBar.count)."
        } else {
            message = "\(entry.label) \(boundary)."
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

struct ControllerRotorOrderView: View {
    @Environment(ControllerMappingSettings.self) private var mappings

    var body: some View {
        List {
            Section("Rotor Sections") {
                ForEach(mappings.draftProfile.quickNavigationOrder) { category in
                    Text(category.rawValue)
                        .accessibilityAction(named: Text("Move Up")) {
                            announceRotorMove(
                                category,
                                index: mappings.moveQuickNavigationCategory(category, direction: -1),
                                boundary: "is already first"
                            )
                        }
                        .accessibilityAction(named: Text("Move Down")) {
                            announceRotorMove(
                                category,
                                index: mappings.moveQuickNavigationCategory(category, direction: 1),
                                boundary: "is already last"
                            )
                        }
                        .accessibilityAction(named: Text("Move to Top")) {
                            announceRotorMove(
                                category,
                                index: mappings.moveQuickNavigationCategoryToStart(category),
                                boundary: "is already first"
                            )
                        }
                        .accessibilityAction(named: Text("Move to Bottom")) {
                            announceRotorMove(
                                category,
                                index: mappings.moveQuickNavigationCategoryToEnd(category),
                                boundary: "is already last"
                            )
                        }
                }
                .onMove(perform: mappings.moveQuickNavigationCategories)
            }

            Section {
                Button("Restore Recommended Rotor Order") {
                    mappings.restoreRecommendedQuickNavigationOrder()
                }
                Text("Rotor order is stored with this controller profile. Every section also supports Move Up, Move Down, Move to Top, and Move to Bottom VoiceOver actions.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Rotor Order")
        .toolbar { EditButton() }
    }

    private func announceRotorMove(_ category: QuickNavigationCategory, index: Int?, boundary: String) {
        let message: String
        if let index {
            message = "\(category.rawValue) moved to position \(index + 1) of \(mappings.draftProfile.quickNavigationOrder.count)."
        } else {
            message = "\(category.rawValue) \(boundary)."
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

enum ControllerMappingActionType: String, CaseIterable, Identifiable {
    case unassigned = "Unassigned"
    case keyboard = "Keyboard"
    case stickyModifier = "Hold Modifier"
    case layer = "Layer"
    case quickNavigation = "NVDA Quick Navigation"
    case textMode = "Text Mode"
    case quickCommandMode = "Quick Command Mode"
    case repeatLastQuickBar = "Repeat Last Quick Bar Action"
    case nextProfile = "Next Profile"
    case previousProfile = "Previous Profile"

    var id: String { rawValue }

    static let quickBarCases: [ControllerMappingActionType] = [
        .unassigned, .keyboard, .textMode, .quickCommandMode,
        .repeatLastQuickBar, .nextProfile, .previousProfile
    ]
}

struct ControllerBindingEditorState: Equatable {
    var type: ControllerMappingActionType {
        didSet {
            guard type != .keyboard else { return }
            key = nil
            modifiers = []
        }
    }

    var key: WindowsKeyboardKey? {
        didSet {
            if key != nil, type == .unassigned { type = .keyboard }
        }
    }

    var modifiers: Set<ControllerKeyboardModifier>
    var stickyModifier: ControllerKeyboardModifier = .alt

    init(action: ControllerAction?) {
        switch action {
        case .keyboard(let keyboard):
            type = .keyboard
            key = keyboard.key
            modifiers = keyboard.modifiers
        case .stickyModifier(let sticky):
            type = .stickyModifier
            key = nil
            modifiers = []
            stickyModifier = sticky.modifier
        case .layer:
            type = .layer
            key = nil
            modifiers = []
        case .quickNavigation:
            type = .quickNavigation
            key = nil
            modifiers = []
        case .farRelay(.textMode):
            type = .textMode
            key = nil
            modifiers = []
        case .farRelay(.quickCommandMode):
            type = .quickCommandMode
            key = nil
            modifiers = []
        case .farRelay(.repeatLastQuickBar):
            type = .repeatLastQuickBar
            key = nil
            modifiers = []
        case .farRelay(.nextProfile):
            type = .nextProfile
            key = nil
            modifiers = []
        case .farRelay(.previousProfile):
            type = .previousProfile
            key = nil
            modifiers = []
        case nil:
            type = .unassigned
            key = nil
            modifiers = []
        }
    }

    var action: ControllerAction? {
        switch type {
        case .unassigned:
            return nil
        case .keyboard:
            guard let key else { return nil }
            return .keyboard(.init(key: key, modifiers: modifiers))
        case .stickyModifier:
            return .stickyModifier(.init(modifier: stickyModifier))
        case .layer:
            return .layer(.init())
        case .quickNavigation:
            return .quickNavigation(.toggle)
        case .textMode:
            return .farRelay(.textMode)
        case .quickCommandMode:
            return .farRelay(.quickCommandMode)
        case .repeatLastQuickBar:
            return .farRelay(.repeatLastQuickBar)
        case .nextProfile:
            return .farRelay(.nextProfile)
        case .previousProfile:
            return .farRelay(.previousProfile)
        }
    }
}

struct ControllerBindingEditor: View {
    let input: ControllerInput
    let layerID: String?

    @Environment(ControllerMappingSettings.self) private var mappings
    @State private var editorState = ControllerBindingEditorState(action: nil)

    var body: some View {
        Form {
            Section("Controller input") { Text(input.label) }
            ControllerActionEditorSections(
                editorState: $editorState,
                allowedTypes: ControllerMappingActionType.allCases
            )
            Section {
                Button("Clear Mapping", role: .destructive) {
                    editorState = ControllerBindingEditorState(action: nil)
                }
            }
        }
        .navigationTitle(input.label)
        .onAppear {
            editorState = ControllerBindingEditorState(
                action: mappings.draftProfile.action(for: input, layerID: layerID)
            )
        }
        .onChange(of: editorState) { _, newValue in
            mappings.setAction(newValue.action, for: input, layerID: layerID)
        }
    }
}

struct QuickBarEntryEditor: View {
    let entryID: UUID

    @Environment(ControllerMappingSettings.self) private var mappings
    @State private var editorState = ControllerBindingEditorState(action: nil)

    var body: some View {
        Form {
            ControllerActionEditorSections(
                editorState: $editorState,
                allowedTypes: ControllerMappingActionType.quickBarCases
            )
            Section {
                Button("Clear Action", role: .destructive) {
                    editorState = ControllerBindingEditorState(action: nil)
                }
            }
        }
        .navigationTitle("Quick Bar Action")
        .onAppear {
            let action = mappings.draftProfile.quickBar.first(where: { $0.id == entryID })?.action
            editorState = ControllerBindingEditorState(action: action)
        }
        .onChange(of: editorState) { _, newValue in
            mappings.setQuickBarAction(newValue.action, entryID: entryID)
        }
    }
}

private struct ControllerActionEditorSections: View {
    @Binding var editorState: ControllerBindingEditorState
    let allowedTypes: [ControllerMappingActionType]

    var body: some View {
        Section("Action") {
            Picker("Action Type", selection: $editorState.type) {
                ForEach(allowedTypes) { type in
                    Text(type.rawValue).tag(type)
                }
            }
        }

        if editorState.type == .keyboard {
            Section("Keyboard") {
                Picker("Primary key", selection: $editorState.key) {
                    Text("Unassigned").tag(WindowsKeyboardKey?.none)
                    ForEach(WindowsKeyboardKey.allCases) { key in
                        Text(key.label).tag(Optional(key))
                    }
                }
                ForEach(ControllerKeyboardModifier.allCases) { modifier in
                    Toggle(modifier.label, isOn: modifierBinding(modifier))
                        .disabled(editorState.key == nil)
                }
            }
        }

        if editorState.type == .stickyModifier {
            Section("Hold / Sticky Modifier") {
                Picker("Modifier", selection: $editorState.stickyModifier) {
                    ForEach(ControllerKeyboardModifier.allCases) { modifier in
                        Text(modifier.label).tag(modifier)
                    }
                }
                Text("In Base, this action toggles the modifier on or off. In a physically held Action Layer, it holds the modifier only until you release the layer button. While that layer-scoped modifier is held, ordinary controller inputs use their Base mappings, so Shift plus D-pad uses arrow keys instead of the layer's alternate D-pad commands. Other Hold Modifier actions in the layer remain available for combinations such as Ctrl+Shift. FarRelay also releases held modifiers on profile changes, remapping, disconnect, backgrounding, or controller loss.")
                    .foregroundStyle(.secondary)
            }
        }

        switch editorState.type {
        case .layer:
            Section("Layer") {
                Text("Extended")
                Text("Hold this button for momentary Extended, tap it for one Extended action, or double-tap it to lock Extended.")
                    .foregroundStyle(.secondary)
            }
        case .quickNavigation:
            Section("NVDA Quick Navigation") {
                Text("Horizontal DualSense touchpad swipes change rotor sections. Right-stick up or down moves within a section. Quick Bar and Profiles are local sections.")
                    .foregroundStyle(.secondary)
            }
        case .textMode:
            Section("Text Mode") {
                Text("Opens the local iPhone editor for VoiceOver Braille Screen Input and mirrors supported text to the remote field.")
                    .foregroundStyle(.secondary)
            }
        case .quickCommandMode:
            Section("Quick Command Mode") {
                Text("Opens a local Braille Screen Input editor for a one-shot keyboard lifeboat. Plus means keys together and comma means then. Nothing is sent until Send Command is activated.")
                    .foregroundStyle(.secondary)
            }
        case .repeatLastQuickBar:
            Section("Repeat Last Quick Bar Action") {
                Text("Repeats the most recent repeatable Quick Bar action from this FarRelay session. Only safe repeatable actions, currently keyboard actions, are remembered.")
                    .foregroundStyle(.secondary)
            }
        case .nextProfile, .previousProfile:
            Section("Profiles") {
                Text("Changes the active saved controller profile using the order shown in Profiles. Switching profiles releases held remote input before the new mappings become active.")
                    .foregroundStyle(.secondary)
            }
        case .unassigned, .keyboard, .stickyModifier:
            EmptyView()
        }
    }

    private func modifierBinding(_ modifier: ControllerKeyboardModifier) -> Binding<Bool> {
        Binding(
            get: { editorState.modifiers.contains(modifier) },
            set: { selected in
                if selected {
                    editorState.modifiers.insert(modifier)
                } else {
                    editorState.modifiers.remove(modifier)
                }
            }
        )
    }
}

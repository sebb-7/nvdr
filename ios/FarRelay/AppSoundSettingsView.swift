import SwiftUI

struct AppSoundSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InteractionSoundSettings.self) private var soundSettings

    var body: some View {
        List {
            Section("Master control") {
                Text(settings.soundCuesEnabled ? "Sound cues are enabled." : "Sound cues are disabled by the master Sound cues switch.")
                    .foregroundStyle(.secondary)
                Text("Each FarRelay app event can be enabled or disabled independently and can use any bundled sound. Remote NVDA sounds and RemSound audio are not changed here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(InteractionSoundIntent.allCases) { intent in
                Section(intent.displayName) {
                    Toggle(
                        "Enable \(intent.displayName) sound",
                        isOn: enabledBinding(for: intent)
                    )

                    Picker("Sound", selection: filenameBinding(for: intent)) {
                        ForEach(AppSoundCatalog.all) { option in
                            Text(option.label).tag(option.filename)
                        }
                    }
                    .disabled(!soundSettings.preference(for: intent).isEnabled)
                    .accessibilityLabel("Sound for \(intent.displayName)")

                    Button("Preview sound", systemImage: "speaker.wave.2") {
                        InteractionSoundCue.playBundled(
                            filename: soundSettings.preference(for: intent).filename
                        )
                    }
                    .accessibilityLabel("Preview \(intent.displayName) sound")
                }
            }
        }
        .navigationTitle("App Sounds")
    }

    private func enabledBinding(for intent: InteractionSoundIntent) -> Binding<Bool> {
        Binding(
            get: { soundSettings.preference(for: intent).isEnabled },
            set: { soundSettings.setEnabled($0, for: intent) }
        )
    }

    private func filenameBinding(for intent: InteractionSoundIntent) -> Binding<String> {
        Binding(
            get: { soundSettings.preference(for: intent).filename },
            set: { soundSettings.setFilename($0, for: intent) }
        )
    }
}
